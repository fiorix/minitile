import AppKit
import CoreVideo
import MinitileCore
import QuartzCore
import ScreenCaptureKit

struct Unchecked<Value>: @unchecked Sendable { let value: Value }

extension NSScreen {
    var displayNumber: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    @MainActor static func screen(for id: DisplayID) -> NSScreen? { screens.first { DisplayCatalog.id(for: $0) == id } }
}

@MainActor
protocol TransitionCapturing: AnyObject {
    /// Nil when captures can run.
    var problem: String? { get }
    func canCapture(_ id: DisplayID) -> Bool
    func refresh()
    func clear()
    func image(of id: DisplayID, done: @escaping @MainActor @Sendable (CGImage?) -> Void)
}

/// Screenshots of a display's usable area that leave out minitile's own windows (overlays, indicator).
@MainActor
final class ScreenCapture: TransitionCapturing {
    /// ScreenCaptureKit omits an accessory app from `SCShareableContent.applications` until it owns a window in
    /// WindowServer; keeping an ordered-out panel registered lets `excludingApplications` omit every panel minitile
    /// creates later.
    private var anchor: NSPanel?
    private var filters: [CGDirectDisplayID: SCContentFilter] = [:]
    private var loads = 0
    private(set) var problem: String? = "Screen capture content is not loaded"

    nonisolated static func loadProblem(contentPresent: Bool, applicationFound: Bool, error: (any Error)?) -> String? {
        guard contentPresent else {
            return "Screen capture content failed: \(error.map { String(describing: $0) } ?? "unknown error")"
        }
        return applicationFound ? nil : "Screen capture content omitted minitile"
    }

    func canCapture(_ id: DisplayID) -> Bool { NSScreen.screen(for: id)?.displayNumber.flatMap { filters[$0] } != nil }

    private func ensureAnchor() {
        guard anchor == nil else { return }
        let panel = TransitionPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.animationBehavior = .none
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        panel.orderFrontRegardless()
        panel.orderOut(nil)
        anchor = panel
    }

    /// Fetching shareable content takes about 90 ms, so the filters are kept until displays change.
    func refresh() {
        ensureAnchor()
        loads += 1
        let load = loads
        filters = [:]
        problem = "Screen capture content is loading"
        let pid = ProcessInfo.processInfo.processIdentifier
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            var filters: [CGDirectDisplayID: SCContentFilter] = [:]
            let app = content?.applications.first { $0.processID == pid }
            if let content, let app {
                for display in content.displays {
                    filters[display.displayID] = SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: [])
                }
            }
            let problem = Self.loadProblem(contentPresent: content != nil, applicationFound: app != nil, error: error)
            let result = Unchecked(value: filters)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loads == load else { return }
                self.filters = result.value
                self.problem = problem
                if problem == nil, let screen = NSScreen.screens.first, let id = DisplayCatalog.id(for: screen) {
                    // The first capture in a process costs about 100 ms; pay it now rather than on a keypress.
                    self.image(of: id) { _ in }
                }
            }
        }
    }

    func clear() {
        loads += 1
        filters = [:]
        problem = "Screen capture content is not loaded"
    }

    func image(of id: DisplayID, done: @escaping @MainActor @Sendable (CGImage?) -> Void) {
        guard let screen = NSScreen.screen(for: id), let number = screen.displayNumber, let filter = filters[number] else {
            DispatchQueue.main.async { done(nil) }; return
        }
        let visible = screen.visibleFrame, scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = TransitionGeometry.sourceRect(frame: screen.frame, visible: visible)
        configuration.width = Int(visible.width * scale)
        configuration.height = Int(visible.height * scale)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            if let error { logger.info("Transition capture failed: \(String(describing: error), privacy: .public)") }
            let result = Unchecked(value: image)
            DispatchQueue.main.async { done(result.value) }
        }
    }
}

@MainActor
protocol TransitionAnimating: AnyObject {
    var generation: Int { get }
    var awaitingIncoming: Bool { get }
    var covering: Bool { get }
    var ended: (() -> Void)? { get set }
    func place(on screen: NSScreen)
    func slide(from image: CGImage, direction: TransitionDirection, duration: TimeInterval) -> Int
    func arrive(_ image: CGImage, generation: Int)
    func bounce(_ image: CGImage, direction: TransitionDirection, duration: TimeInterval)
    func end(_ generation: Int)
    func close()
}

@MainActor
private final class TransitionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click-through snapshot over one display's usable area that slides or bounces, then goes away.
@MainActor
final class TransitionOverlay: TransitionAnimating {
    /// The position indicator uses `.floating` and must stay above the slide.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    static let curve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    static let pageCornerRadius: CGFloat = 12
    private static let background = PanelStyle.void.color
    private let panel: NSPanel
    private let outgoing = CALayer(), incoming = CALayer()
    /// Changes whenever the overlay is covered again or ends, so stale completions and captures are ignored.
    private(set) var generation = 0
    private(set) var awaitingIncoming = false
    var ended: (() -> Void)?

    init() {
        panel = TransitionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = true
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.backgroundColor = Self.background
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = Self.background.cgColor
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 1400.0
        view.layer?.sublayerTransform = perspective
        for layer in [outgoing, incoming] {
            layer.contentsGravity = .resize
            layer.cornerRadius = Self.pageCornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            view.layer?.addSublayer(layer)
        }
    }

    var covering: Bool { panel.isVisible }
    private var size: CGSize { panel.contentView?.bounds.size ?? .zero }
    private var rest: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    func place(on screen: NSScreen) {
        if panel.frame != screen.visibleFrame { panel.setFrame(screen.visibleFrame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [outgoing, incoming] {
            layer.transform = CATransform3DIdentity
            layer.frame = CGRect(origin: .zero, size: screen.visibleFrame.size)
            layer.contentsScale = screen.backingScaleFactor
        }
        CATransaction.commit()
    }

    /// Show `image` at rest over the screen, cutting short whatever was running.
    private func cover(_ image: CGImage) -> Int {
        generation += 1
        awaitingIncoming = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing.removeAllAnimations()
        incoming.removeAllAnimations()
        outgoing.transform = CATransform3DIdentity
        incoming.transform = CATransform3DIdentity
        outgoing.cornerRadius = 0
        incoming.cornerRadius = Self.pageCornerRadius
        outgoing.contents = image
        outgoing.position = rest
        outgoing.isHidden = false
        incoming.contents = nil
        incoming.isHidden = true
        CATransaction.commit()
        panel.orderFrontRegardless()
        CATransaction.flush()
        return generation
    }

    /// 3D depth-valley transform for a sliding or bouncing page (`recess` < 1 pulls back slightly in Z).
    static func depthTransform(direction: TransitionDirection, angleDegrees: CGFloat, scale: CGFloat = 0.968) -> CATransform3D {
        let radians = angleDegrees * .pi / 180
        var t = CATransform3DMakeScale(scale, scale, 1)
        if direction.dx != 0 {
            t = CATransform3DRotate(t, CGFloat(direction.dx) * radians, 0, 1, 0)
        } else if direction.dy != 0 {
            t = CATransform3DRotate(t, CGFloat(-direction.dy) * radians, 1, 0, 0)
        }
        return t
    }

    /// Slide `image` out through a subtle 3D depth valley with a void seam; `arrive` fills the incoming layer.
    func slide(from image: CGImage, direction: TransitionDirection, duration: TimeInterval) -> Int {
        let generation = cover(image)
        let shift = TransitionGeometry.shift(direction, size: size)
        let rest = rest
        let out = CGPoint(x: rest.x + shift.width, y: rest.y + shift.height)
        let start = CGPoint(x: rest.x - shift.width, y: rest.y - shift.height)
        awaitingIncoming = true
        let outMid = Self.depthTransform(direction: direction, angleDegrees: -3.8)
        let inMid = Self.depthTransform(direction: direction, angleDegrees: 3.8)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.end(generation) } }
        move(outgoing, from: rest, to: out, transforms: [CATransform3DIdentity, outMid, outMid],
             radii: [0, Self.pageCornerRadius, Self.pageCornerRadius], duration: duration)
        move(incoming, from: start, to: rest, transforms: [inMid, inMid, CATransform3DIdentity],
             radii: [Self.pageCornerRadius, Self.pageCornerRadius, 0], duration: duration)
        CATransaction.commit()
        return generation
    }

    func arrive(_ image: CGImage, generation: Int) {
        guard generation == self.generation else { return }
        awaitingIncoming = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.contents = image
        CATransaction.commit()
    }

    /// Shift 5% the way a slide would start with a subtle 3D hinged rebound, then spring back.
    func bounce(_ image: CGImage, direction: TransitionDirection, duration: TimeInterval) {
        let generation = cover(image)
        let shift = TransitionGeometry.shift(direction, size: size)
        let rest = rest
        let timing = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]

        let posAnim = CAKeyframeAnimation(keyPath: "position")
        posAnim.values = [rest, CGPoint(x: rest.x + shift.width * 0.05, y: rest.y + shift.height * 0.05), rest].map { NSValue(point: $0) }
        posAnim.keyTimes = [0, 0.35, 1]
        posAnim.timingFunctions = timing
        posAnim.duration = duration

        let tilt = Self.depthTransform(direction: direction, angleDegrees: -4.2, scale: 0.985)
        let tiltAnim = CAKeyframeAnimation(keyPath: "transform")
        tiltAnim.values = [CATransform3DIdentity, tilt, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        tiltAnim.keyTimes = [0, 0.35, 1]
        tiltAnim.timingFunctions = timing
        tiltAnim.duration = duration

        let radiusAnim = CAKeyframeAnimation(keyPath: "cornerRadius")
        radiusAnim.values = [0, Self.pageCornerRadius, 0]
        radiusAnim.keyTimes = [0, 0.35, 1]
        radiusAnim.timingFunctions = timing
        radiusAnim.duration = duration

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.end(generation) } }
        outgoing.add(posAnim, forKey: "bounce")
        outgoing.add(tiltAnim, forKey: "bounceTransform")
        outgoing.add(radiusAnim, forKey: "bounceCornerRadius")
        CATransaction.commit()
    }

    private func move(_ layer: CALayer, from: CGPoint, to: CGPoint, transforms: [CATransform3D], radii: [CGFloat], duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: to)
        animation.duration = duration
        animation.timingFunction = Self.curve

        let timing = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        let depth = CAKeyframeAnimation(keyPath: "transform")
        depth.values = transforms.map { NSValue(caTransform3D: $0) }
        depth.keyTimes = [0, 0.45, 1]
        depth.timingFunctions = timing
        depth.duration = duration

        let corners = CAKeyframeAnimation(keyPath: "cornerRadius")
        corners.values = radii
        corners.keyTimes = [0, 0.45, 1]
        corners.timingFunctions = timing
        corners.duration = duration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = to
        layer.transform = transforms.last ?? CATransform3DIdentity
        layer.cornerRadius = radii.last ?? 0
        layer.isHidden = false
        CATransaction.commit()
        layer.add(animation, forKey: "slide")
        layer.add(depth, forKey: "slideDepth")
        layer.add(corners, forKey: "slideCorners")
    }

    func end(_ generation: Int) {
        guard generation == self.generation else { return }
        self.generation += 1
        awaitingIncoming = false
        panel.orderOut(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing.removeAllAnimations()
        incoming.removeAllAnimations()
        outgoing.transform = CATransform3DIdentity
        incoming.transform = CATransform3DIdentity
        outgoing.contents = nil
        incoming.contents = nil
        CATransaction.commit()
        ended?()
    }

    func close() {
        end(generation)
        panel.close()
    }
}
