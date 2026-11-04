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
    private var filters: [CGDirectDisplayID: SCContentFilter] = [:]
    private var loads = 0
    private(set) var problem: String? = "Screen capture content is not loaded"

    func canCapture(_ id: DisplayID) -> Bool { NSScreen.screen(for: id)?.displayNumber.flatMap { filters[$0] } != nil }

    /// Fetching shareable content takes about 90 ms, so the filters are kept until displays change.
    func refresh() {
        loads += 1
        let load = loads
        filters = [:]
        problem = "Screen capture content is loading"
        let pid = ProcessInfo.processInfo.processIdentifier
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            var filters: [CGDirectDisplayID: SCContentFilter] = [:]
            if let content {
                let app = content.applications.first { $0.processID == pid }
                let own = content.windows.filter { $0.owningApplication?.processID == pid }
                for display in content.displays {
                    filters[display.displayID] = app.map { SCContentFilter(display: display, excludingApplications: [$0], exceptingWindows: []) }
                        ?? SCContentFilter(display: display, excludingWindows: own)
                }
            }
            let problem = content == nil ? "Screen capture content failed: \(error.map { String(describing: $0) } ?? "unknown error")" : nil
            let result = Unchecked(value: filters)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loads == load else { return }
                self.filters = result.value
                self.problem = problem
                if let screen = NSScreen.screens.first, let id = DisplayCatalog.id(for: screen) {
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
private final class TransitionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click-through snapshot over one display's usable area that slides or bounces, then goes away.
@MainActor
final class TransitionOverlay {
    /// The position indicator uses `.floating` and must stay above the slide.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    static let curve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    private static let background = NSColor(white: 0.08, alpha: 1)
    private let panel: NSPanel
    private let outgoing = CALayer(), incoming = CALayer()
    /// Changes whenever the overlay is covered again or ends, so stale completions and captures are ignored.
    private(set) var generation = 0
    private(set) var awaitingIncoming = false

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
        for layer in [outgoing, incoming] {
            layer.contentsGravity = .resize
            view.layer?.addSublayer(layer)
        }
    }

    private var size: CGSize { panel.contentView?.bounds.size ?? .zero }
    private var rest: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    func place(on screen: NSScreen) {
        if panel.frame != screen.visibleFrame { panel.setFrame(screen.visibleFrame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [outgoing, incoming] {
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

    /// Slide `image` out with a dark incoming half; `arrive` fills it once the new page is captured.
    func slide(from image: CGImage, direction: TransitionDirection, duration: TimeInterval) -> Int {
        let generation = cover(image)
        let shift = TransitionGeometry.shift(direction, size: size)
        let rest = rest
        let out = CGPoint(x: rest.x + shift.width, y: rest.y + shift.height)
        let start = CGPoint(x: rest.x - shift.width, y: rest.y - shift.height)
        awaitingIncoming = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.end(generation) } }
        move(outgoing, from: rest, to: out, duration: duration)
        move(incoming, from: start, to: rest, duration: duration)
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

    /// Shift 5% the way a slide would start, then spring back.
    func bounce(_ image: CGImage, direction: TransitionDirection, duration: TimeInterval) {
        let generation = cover(image)
        let shift = TransitionGeometry.shift(direction, size: size)
        let rest = rest
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = [rest, CGPoint(x: rest.x + shift.width * 0.05, y: rest.y + shift.height * 0.05), rest].map { NSValue(point: $0) }
        animation.keyTimes = [0, 0.35, 1]
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        animation.duration = duration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.end(generation) } }
        outgoing.add(animation, forKey: "bounce")
        CATransaction.commit()
    }

    private func move(_ layer: CALayer, from: CGPoint, to: CGPoint, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: to)
        animation.duration = duration
        animation.timingFunction = Self.curve
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = to
        layer.isHidden = false
        CATransaction.commit()
        layer.add(animation, forKey: "slide")
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
        outgoing.contents = nil
        incoming.contents = nil
        CATransaction.commit()
    }

    func close() {
        end(generation)
        panel.close()
    }
}
