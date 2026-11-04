import AppKit
import MinitileCore

/// When each display's second-desktop notice shows: for `duration` from when the display starts needing a second
/// desktop, at launch, when it is connected or when its second desktop is removed, and not again until it has had one
/// or has been disconnected. The status menu keeps the explanation meanwhile.
struct DesktopNoticeTiming {
    static let duration: TimeInterval = 12
    /// The displays that need a second desktop, by when their notice hides.
    private(set) var until: [DisplayID: TimeInterval] = [:]

    /// The displays that lack a second desktop. Separate Spaces is one setting for every display, which only the status
    /// menu explains.
    static func needing(_ displays: [DisplayInfo]) -> Set<DisplayID> {
        Set(displays.filter { DisplayNeed(reason: $0.unmanagedReason) == .secondDesktop }.map(\.id))
    }

    mutating func update(needing: Set<DisplayID>, now: TimeInterval) {
        until = until.filter { needing.contains($0.key) }
        for id in needing where until[id] == nil { until[id] = now + Self.duration }
    }

    func visible(now: TimeInterval) -> Set<DisplayID> { Set(until.filter { now < $0.value }.keys) }

    /// When the next shown notice hides.
    func expiry(now: TimeInterval) -> TimeInterval? { until.values.filter { now < $0 }.min() }
}

/// The notice at a fixed size, like the help screen: two desktops as Mission Control shows them, the second one lit as
/// the one to add, over the advice the status menu gives.
struct DesktopNoticeLayout: Equatable {
    static let width: CGFloat = 440
    static let margin: CGFloat = 20
    static let desktop = CGSize(width: 64, height: 40)
    static let desktopGap: CGFloat = 10
    static let bodySize: CGFloat = 12
    /// Only the notice, shown on the display itself, says what happens until the desktop is added.
    static let meanwhile = "Until then, minitile leaves this display's windows alone."

    var advice: SetupAdvice
    var body: String
    var bodyHeight: CGFloat

    init(name: String) {
        advice = .secondDesktop(name: name)
        body = "\(advice.detail) \(Self.meanwhile)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: body, attributes: [.font: PanelStyle.font(size: Self.bodySize), .paragraphStyle: paragraph])
        bodyHeight = text.boundingRect(with: NSSize(width: Self.width - 2 * Self.margin, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height.rounded(.up)
    }

    var desktops: [CGRect] {
        (0..<2).map { CGRect(origin: CGPoint(x: Self.margin + CGFloat($0) * (Self.desktop.width + Self.desktopGap), y: Self.margin),
                             size: Self.desktop) }
    }
    func labelRect(_ desktop: CGRect) -> CGRect { CGRect(x: desktop.minX - 8, y: desktop.maxY + 4, width: desktop.width + 16, height: 13) }
    var headerRect: CGRect { CGRect(x: Self.margin, y: Self.margin + Self.desktop.height + 29, width: Self.width - 2 * Self.margin, height: 18) }
    var bodyRect: CGRect { CGRect(x: Self.margin, y: headerRect.maxY + 4, width: Self.width - 2 * Self.margin, height: bodyHeight) }
    var size: CGSize { CGSize(width: Self.width, height: bodyRect.maxY + Self.margin) }
}

/// A click-through notice in the middle of each display that needs a second desktop, while its timing shows it.
@MainActor
final class DesktopNotice {
    /// The position indicator's level, above normal windows and the page-transition overlays.
    static let level = NSWindow.Level.floating
    private var timing = DesktopNoticeTiming()
    private var panels: [DisplayID: NSPanel] = [:]
    private var needing: Set<DisplayID> = []
    private var expiry: DispatchWorkItem?
    var visibleCount: Int { panels.values.filter(\.isVisible).count }

    /// `needing` holds the displays that lack a second desktop; a notice hides on its own when its time is up.
    func update(needing: Set<DisplayID>) {
        self.needing = needing
        let now = ProcessInfo.processInfo.systemUptime
        timing.update(needing: needing, now: now)
        let shown = timing.visible(now: now)
        for id in Array(panels.keys) where !needing.contains(id) { panels.removeValue(forKey: id)?.close() }
        for screen in NSScreen.screens {
            guard let id = DisplayCatalog.id(for: screen) else { continue }
            if shown.contains(id) { show(on: screen, id: id) } else { panels[id]?.orderOut(nil) }
        }
        expiry?.cancel()
        expiry = nil
        guard let next = timing.expiry(now: now) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.update(needing: self.needing)
            }
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (next - now), execute: work)
    }

    func stop() {
        expiry?.cancel()
        expiry = nil
        timing = DesktopNoticeTiming()
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    /// The shell updates the notice on every model change and every second, so the text is measured again only when
    /// the display's name changes.
    private func show(on screen: NSScreen, id: DisplayID) {
        let name = screen.localizedName
        let panel = panels[id] ?? makePanel(DesktopNoticeLayout(name: name))
        panels[id] = panel
        guard let view = panel.styledContent as? DesktopNoticeView else { return }
        if view.layout.advice != .secondDesktop(name: name) { view.layout = DesktopNoticeLayout(name: name) }
        let layout = view.layout, area = screen.visibleFrame
        let size = CGSize(width: min(layout.size.width, area.width), height: min(layout.size.height, area.height))
        let frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel(_ layout: DesktopNoticeLayout) -> NSPanel {
        let panel = GridPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.setStyledContent(DesktopNoticeView(layout: layout))
        return panel
    }
}

@MainActor
final class DesktopNoticeView: NSView {
    var layout: DesktopNoticeLayout {
        didSet {
            guard layout != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel("\(layout.advice.title). \(layout.body)")
        }
    }

    init(layout: DesktopNoticeLayout) {
        self.layout = layout
        super.init(frame: NSRect(origin: .zero, size: layout.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(layout.advice.title). \(layout.body)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        GridPainter.background(bounds)
        let desktops = layout.desktops, radius = PanelStyle.pageRadius
        GridPainter.plate(desktops[0], radius: radius, fill: PanelStyle.tileFill, stroke: PanelStyle.page)
        GridPainter.plate(desktops[0].insetBy(dx: 10, dy: 8), radius: PanelStyle.tileRadius, fill: PanelStyle.tileFill, stroke: PanelStyle.tile)
        GridPainter.plate(desktops[1], radius: radius, fill: PanelStyle.highlightFill, stroke: PanelStyle.highlight)
        let plus = NSBezierPath(), center = CGPoint(x: desktops[1].midX, y: desktops[1].midY), arm: CGFloat = 6
        plus.move(to: CGPoint(x: center.x - arm, y: center.y))
        plus.line(to: CGPoint(x: center.x + arm, y: center.y))
        plus.move(to: CGPoint(x: center.x, y: center.y - arm))
        plus.line(to: CGPoint(x: center.x, y: center.y + arm))
        plus.lineWidth = PanelStyle.highlight.width
        PanelStyle.glow.light(plus, core: PanelStyle.neonCore)
        for (index, desktop) in desktops.enumerated() {
            GridPainter.text("Desktop \(index + 1)", rect: layout.labelRect(desktop), size: 9, color: index == 0 ? PanelStyle.dim : PanelStyle.neon,
                             alignment: .center, monospaced: true)
        }
        GridPainter.text(layout.advice.title, rect: layout.headerRect, size: 13, weight: .semibold)
        GridPainter.text(layout.body, rect: layout.bodyRect, size: DesktopNoticeLayout.bodySize, color: PanelStyle.dim, wrap: true)
    }
}
