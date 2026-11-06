import AppKit
import MinitileCore

@MainActor
protocol HelpPresenting: AnyObject {
    /// `display` is the active display; without one, the panel goes on the main screen.
    func show(_ content: HelpContent, display: DisplayID?)
    func hide()
}

/// The help screen's main-thread session with the key router.
@MainActor
final class HelpScreen {
    private(set) var session: Int?
    /// The newest session seen, so an open the tap thread sent before a newer session cannot reopen a closed screen.
    private var latest = 0
    private let presenter: any HelpPresenting

    init(presenter: any HelpPresenting) {
        self.presenter = presenter
    }

    var isOpen: Bool { session != nil }

    func isStale(_ session: Int) -> Bool { session <= latest }

    /// Shows the screen under `session`; an already visible screen keeps its content and display.
    func open(session: Int, content: HelpContent, display: DisplayID?) {
        latest = max(latest, session)
        let showing = isOpen
        self.session = session
        if !showing { presenter.show(content, display: display) }
    }

    /// Closes `session`; a newer one stays open.
    func close(_ session: Int) {
        if self.session == session { close() }
    }

    func close() {
        if session != nil { presenter.hide() }
        session = nil
    }

    /// The switcher took the keyboard under `session`, so the screen closes and ignores opens sent before it.
    func supersede(_ session: Int) {
        latest = max(latest, session)
        close()
    }
}

/// A non-activating panel in the middle of the active display's usable area, styled as the window switcher.
@MainActor
final class HelpPanel: HelpPresenting {
    /// The window switcher's level, above the position indicator, the page-transition overlays and other apps'
    /// floating windows.
    static let level = SwitcherPanel.level
    private var panel: NSPanel?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    /// A click outside the panel or on its link, either of which closes the screen.
    var dismissed: (() -> Void)?

    func show(_ content: HelpContent, display: DisplayID?) {
        guard let screen = NSScreen.screens.first(where: { DisplayCatalog.id(for: $0) == display }) ?? NSScreen.main ?? NSScreen.screens.first
        else { hide(); return }
        let area = screen.visibleFrame, inset = PanelStyle.inset
        let layout = HelpLayout(content: content, bounds: CGSize(width: area.width - 2 * inset, height: area.height - 2 * inset))
        let panel = self.panel ?? makePanel(layout)
        self.panel = panel
        (panel.styledContent as? HelpView)?.layout = layout
        let size = CGSize(width: min(layout.size.width, area.width - 2 * inset), height: min(layout.size.height, area.height - 2 * inset))
        let frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if mouseMonitor == nil {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissed?() }
            }
            // Global monitors exclude this app, including its menu bar and other panels.
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window !== self.panel { self.dismissed?() }
                }
                return event
            }
        }
    }

    func hide() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
        panel?.orderOut(nil)
    }

    func stop() {
        hide()
        panel?.close()
        panel = nil
    }

    private func makePanel(_ layout: HelpLayout) -> NSPanel {
        let panel = GridPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = HelpView(layout: layout)
        view.openLink = { [weak self] in
            NSWorkspace.shared.open(HelpHeader.website)
            self?.dismissed?()
        }
        panel.setStyledContent(view)
        return panel
    }
}

/// The panel's top row in flipped view coordinates: the mark, the title and the website link on the left, and the
/// subtitle at the right end.
struct HelpHeader: Equatable {
    static let title = "minitile"
    static let subtitle = "Keys and gestures"
    static let link = "minitile.app"
    static let website = URL(string: "https://minitile.app")!
    static let titleSize: CGFloat = 12
    static let textSize: CGFloat = 10

    var mark: CGRect
    var title: CGRect
    var subtitle: CGRect
    var link: CGRect

    init(width: CGFloat) {
        let margin = HelpLayout.margin
        mark = CGRect(x: margin, y: margin - 6, width: 18, height: 18)
        title = CGRect(x: mark.maxX + 7, y: margin - 4, width: Self.width(Self.title, PanelStyle.font(size: Self.titleSize, weight: .semibold)),
                       height: 17)
        link = CGRect(x: title.maxX + 8, y: margin - 3, width: Self.width(Self.link, PanelStyle.font(size: Self.textSize, monospaced: true)),
                      height: 16)
        let subtitleWidth = Self.width(Self.subtitle, PanelStyle.font(size: Self.textSize))
        subtitle = CGRect(x: width - margin - subtitleWidth, y: margin - 3, width: subtitleWidth, height: 16)
    }

    private static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}

@MainActor
final class HelpView: NSView {
    var layout: HelpLayout {
        didSet { if layout != oldValue { needsDisplay = true } }
    }
    var openLink: (() -> Void)?
    private var linkHovered = false {
        didSet {
            guard linkHovered != oldValue else { return }
            (linkHovered ? NSCursor.pointingHand : NSCursor.arrow).set()
            needsDisplay = true
        }
    }

    init(layout: HelpLayout) {
        self.layout = layout
        super.init(frame: NSRect(origin: .zero, size: layout.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("minitile keys and gestures")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The panel never becomes key, so the area tracks the pointer whatever the active app.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
    }

    override func mouseMoved(with event: NSEvent) { linkHovered = overLink(event) }
    override func mouseEntered(with event: NSEvent) { linkHovered = overLink(event) }
    override func mouseExited(with event: NSEvent) { linkHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard overLink(event) else { return }
        linkHovered = false
        openLink?()
    }

    private func overLink(_ event: NSEvent) -> Bool {
        HelpHeader(width: bounds.width).link.contains(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        let header = HelpHeader(width: bounds.width)
        GridPainter.background(bounds)
        PanelStyle.mark(in: header.mark)
        GridPainter.text(HelpHeader.title, rect: header.title, size: HelpHeader.titleSize, weight: .semibold)
        GridPainter.text(HelpHeader.subtitle, rect: header.subtitle, size: HelpHeader.textSize, color: PanelStyle.dim)
        GridPainter.text(HelpHeader.link, rect: header.link, size: HelpHeader.textSize, color: linkHovered ? PanelStyle.ink : PanelStyle.dim,
                         monospaced: true)
        for (index, column) in layout.columns.enumerated() {
            var origin = layout.origin(column: index)
            for line in column {
                switch line {
                case .header(let title):
                    GridPainter.text(title, rect: NSRect(x: origin.x, y: origin.y + line.height - 18, width: HelpLayout.columnWidth, height: 15),
                                     size: 11, weight: .semibold)
                case .entry(let entry):
                    GridPainter.text(entry.text, rect: NSRect(x: origin.x, y: origin.y + 5, width: HelpLayout.textWidth - 12, height: 16),
                                     size: 12)
                    if let detail = entry.detail {
                        GridPainter.text(detail, rect: NSRect(x: origin.x, y: origin.y + 23, width: HelpLayout.textWidth - 12, height: 32),
                                         size: 10, color: PanelStyle.dim, wrap: true)
                    }
                    if entry.chord {
                        let gap: CGFloat = 4
                        let width = entry.keys.reduce(CGFloat(0)) { $0 + PanelStyle.keycapSize($1).width } + CGFloat(entry.keys.count - 1) * gap
                        let scale = min(1, HelpLayout.keyWidth / max(1, width))
                        var x = origin.x + HelpLayout.columnWidth - width * scale
                        for key in entry.keys {
                            PanelStyle.keycap(key, at: CGPoint(x: x, y: origin.y), scale: scale)
                            x += PanelStyle.keycapSize(key, scale: scale).width + gap * scale
                        }
                    } else {
                        GridPainter.text(entry.keys.joined(separator: " "),
                                         rect: NSRect(x: origin.x + HelpLayout.textWidth, y: origin.y + 5, width: HelpLayout.keyWidth, height: 16),
                                         size: 12, color: PanelStyle.dim, alignment: .right)
                    }
                }
                origin.y += line.height
            }
        }
    }
}

extension AppDelegate {
    /// Started and not suspended: the switcher and the help screen take keys only then.
    var modalsAvailable: Bool { started && !quitting && suspendedReasons.isEmpty }

    /// `help show`, answered here since the help screen is shell UI. Repeated requests leave it open.
    func helpCommand() -> Reply {
        guard modalsAvailable else { return Reply(ok: false, text: "Help is unavailable while minitile is suspended") }
        if !helpScreen.isOpen { openHelp(session: keyboard?.open(.help) ?? 0) }
        return Reply(text: "OK")
    }

    /// Keys the router sent for a session; ones for a screen that has since closed are dropped.
    func helpKey(_ key: HelpKey, session: Int) {
        switch key {
        case .open:
            guard !helpScreen.isStale(session) else { return }
            guard modalsAvailable else { keyboard?.close(session); return }
            openHelp(session: session)
        case .close: helpScreen.close(session)
        }
    }

    /// Opens on the display a command without an address acts on, closing the switcher, which cannot be open with it.
    func openHelp(session: Int) {
        windowSwitcher.supersede(session)
        helpScreen.open(session: session, content: HelpContent(config: engine.config), display: engine.commandDisplay)
    }
}
