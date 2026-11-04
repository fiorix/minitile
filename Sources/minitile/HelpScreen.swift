import AppKit
import MinitileCore

@MainActor
protocol HelpPresenting: AnyObject {
    /// `display` is the active display; without one, the panel goes on the main screen.
    func show(_ content: HelpContent, display: DisplayID?)
    func hide()
}

/// The help screen's main-thread side: its session with the key router and, when no modifier holds it, its timer.
@MainActor
final class HelpScreen {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    /// How long a screen no modifier holds stays open, as one from `mntl help show`.
    static let timeout: TimeInterval = 5

    private(set) var session: Int?
    /// Opened by a binding with modifiers, so it closes when they are released.
    private(set) var held = false
    /// Runs with the session the timer closed, so the shell closes it in the key router too.
    var expired: ((Int) -> Void)?
    /// The newest session seen, so an open the tap thread sent before a newer session cannot reopen a closed screen.
    private var latest = 0
    private let presenter: any HelpPresenting
    private let schedule: Schedule

    init(presenter: any HelpPresenting, schedule: @escaping Schedule = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }) {
        self.presenter = presenter
        self.schedule = schedule
    }

    var isOpen: Bool { session != nil }

    func isStale(_ session: Int) -> Bool { session <= latest }

    /// Shows the screen under `session`. An open screen is updated in place rather than hidden first, so opening it
    /// again does not flicker.
    func open(session: Int, held: Bool, content: HelpContent, display: DisplayID?) {
        latest = max(latest, session)
        self.session = session
        self.held = held
        presenter.show(content, display: display)
        guard !held else { return }
        schedule(Self.timeout) { [weak self] in
            guard let self, self.session == session else { return }
            self.close()
            self.expired?(session)
        }
    }

    /// Closes `session`; a newer one stays open.
    func close(_ session: Int) {
        if self.session == session { close() }
    }

    func close() {
        if session != nil { presenter.hide() }
        session = nil
        held = false
    }

    /// The switcher took the keyboard under `session`, so the screen closes and ignores opens sent before it.
    func supersede(_ session: Int) {
        latest = max(latest, session)
        close()
    }
}

/// A click-through panel in the middle of the active display's usable area, styled as the window switcher.
@MainActor
final class HelpPanel: HelpPresenting {
    /// The window switcher's level, above the position indicator, the page-transition overlays and other apps'
    /// floating windows.
    static let level = SwitcherPanel.level
    private var panel: NSPanel?

    func show(_ content: HelpContent, display: DisplayID?) {
        guard let screen = NSScreen.screens.first(where: { DisplayCatalog.id(for: $0) == display }) ?? NSScreen.main ?? NSScreen.screens.first
        else { hide(); return }
        let area = screen.visibleFrame, inset = PanelStyle.inset
        let layout = HelpLayout(content: content, bounds: CGSize(width: area.width - 2 * inset, height: area.height - 2 * inset))
        let panel = self.panel ?? makePanel(layout)
        self.panel = panel
        (panel.styledContent as? HelpView)?.layout = layout
        let size = CGSize(width: min(layout.size.width, area.width), height: min(layout.size.height, area.height))
        let frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    func stop() {
        panel?.close()
        panel = nil
    }

    private func makePanel(_ layout: HelpLayout) -> NSPanel {
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
        panel.setStyledContent(HelpView(layout: layout))
        return panel
    }
}

@MainActor
final class HelpView: NSView {
    var layout: HelpLayout {
        didSet { if layout != oldValue { needsDisplay = true } }
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

    override func draw(_ dirtyRect: NSRect) {
        let margin = HelpLayout.margin
        GridPainter.background(bounds)
        GridPainter.text("minitile", rect: NSRect(x: margin, y: margin - 4, width: 120, height: 17), size: 12, weight: .semibold)
        GridPainter.text("Keys and gestures", rect: NSRect(x: bounds.width - margin - 160, y: margin - 3, width: 160, height: 16), size: 10,
                         color: PanelStyle.secondary, alignment: .right)
        for (index, column) in layout.columns.enumerated() {
            var origin = layout.origin(column: index)
            for line in column {
                switch line {
                case .header(let title):
                    GridPainter.text(title, rect: NSRect(x: origin.x, y: origin.y + line.height - 18, width: HelpLayout.columnWidth, height: 15),
                                     size: 11, weight: .semibold)
                case .entry(let entry):
                    GridPainter.text(entry.keys, rect: NSRect(x: origin.x, y: origin.y + 1, width: HelpLayout.keyWidth - 8, height: 16),
                                     size: 12, weight: .medium, monospaced: entry.chord,
                                     symbolTracking: entry.chord ? PanelStyle.chordTracking : 0)
                    GridPainter.text(entry.text, rect: NSRect(x: origin.x + HelpLayout.keyWidth, y: origin.y + 1, width: HelpLayout.textWidth,
                                                              height: 16), size: 12, color: PanelStyle.secondary)
                }
                origin.y += line.height
            }
        }
    }
}

extension AppDelegate {
    /// Started and not suspended: the switcher and the help screen take keys only then.
    var modalsAvailable: Bool { started && !quitting && suspendedReasons.isEmpty }

    /// `help show`, answered here since the help screen is shell UI. Without a held modifier it closes on its timer.
    func helpCommand() -> Reply {
        guard modalsAvailable else { return Reply(ok: false, text: "Help is unavailable while minitile is suspended") }
        openHelp(session: keyboard?.open(.help) ?? 0, held: false)
        return Reply(text: "OK")
    }

    /// Keys the router sent for a session; ones for a screen that has since closed are dropped.
    func helpKey(_ key: HelpKey, session: Int) {
        switch key {
        case .open(let held):
            guard !helpScreen.isStale(session) else { return }
            guard modalsAvailable else { keyboard?.close(session); return }
            openHelp(session: session, held: !held.isEmpty)
        case .close: helpScreen.close(session)
        }
    }

    /// Opens on the display a command without an address acts on, closing the switcher, which cannot be open with it.
    func openHelp(session: Int, held: Bool) {
        windowSwitcher.supersede(session)
        helpScreen.open(session: session, held: held, content: HelpContent(config: engine.config), display: engine.commandDisplay)
    }
}
