import AppKit
import MinitileCore

@MainActor
protocol SwitcherPresenting: AnyObject {
    func show(_ content: SwitcherContent, display: DisplayID)
    func hide()
}

/// The switcher's main-thread side: its selection, its session with the key router, and when the panel shows. Opened
/// by a held binding, the panel waits `showDelay`, so a quick Cmd+Tab switches without it ever appearing.
@MainActor
final class WindowSwitcher {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    static let showDelay: TimeInterval = 0.15

    private(set) var selection: SwitcherSelection?
    private(set) var session: Int?
    /// Opened by a binding, so it commits when the binding's modifiers are released.
    private(set) var held = false
    private(set) var visible = false
    /// Runs before the delayed panel appears and may close the switcher, as a modifier release the tap missed does.
    var willShow: (() -> Void)?
    /// The newest session seen, so an open the tap thread sent before a newer session cannot reopen a closed switcher.
    private var latest = 0
    private var state: SavedState?
    private var shown: SwitcherContent?
    private let presenter: any SwitcherPresenting
    private let schedule: Schedule

    init(presenter: any SwitcherPresenting, schedule: @escaping Schedule = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }) {
        self.presenter = presenter
        self.schedule = schedule
    }

    var isOpen: Bool { selection != nil }

    func isStale(_ session: Int) -> Bool { session <= latest }

    /// Opens on the display, replacing an open switcher. Returns false, leaving it closed, when the display has no
    /// window to offer.
    func open(session: Int, forward: Bool, held: Bool, state: SavedState, display: DisplayID?, config: Config) -> Bool {
        latest = max(latest, session)
        close()
        guard let display, let selection = SwitcherSelection(state: state, display: display, config: config, forward: forward) else { return false }
        self.selection = selection
        self.session = session
        self.held = held
        self.state = state
        if held { schedule(Self.showDelay) { [weak self] in self?.reveal(session) } }
        else { reveal(session) }
        return true
    }

    func step(forward: Bool) {
        selection?.step(forward: forward)
        redraw()
    }

    func move(_ direction: SwitcherDirection) {
        selection?.move(direction)
        redraw()
    }

    /// Follows model changes. Returns the session it closed because no window is left to offer.
    func update(state: SavedState, config: Config) -> Int? {
        guard var selection, let session else { return nil }
        guard selection.update(state: state, config: config) else { close(); return session }
        self.selection = selection
        self.state = state
        redraw()
        return nil
    }

    /// Hides the panel before returning the window to focus, so the panel never shows in a transition capture.
    func commit() -> WindowID? {
        let selected = selection?.selected
        close()
        return selected
    }

    func cancel() { close() }

    private func reveal(_ session: Int) {
        guard self.session == session, !visible else { return }
        willShow?()
        guard self.session == session else { return }
        visible = true
        redraw()
    }

    private func redraw() {
        guard visible, let selection, let state else { return }
        let content = SwitcherContent(selection: selection, state: state)
        guard content != shown else { return }
        shown = content
        presenter.show(content, display: selection.display)
    }

    private func close() {
        if visible { presenter.hide() }
        selection = nil
        session = nil
        held = false
        visible = false
        state = nil
        shown = nil
    }
}

/// A click-through panel in the middle of the display's usable area.
@MainActor
final class SwitcherPanel: SwitcherPresenting {
    /// Above the position indicator (`.floating`), the page-transition overlays (one below it) and other apps' floating
    /// windows, as the native app switcher is.
    static let level = NSWindow.Level.popUpMenu
    private var panel: NSPanel?
    private var icons = AppIconCache<NSImage>()

    func show(_ content: SwitcherContent, display: DisplayID) {
        guard let screen = NSScreen.screens.first(where: { DisplayCatalog.id(for: $0) == display }) else { hide(); return }
        let panel = self.panel ?? makePanel(content)
        self.panel = panel
        if let view = panel.contentView as? SwitcherView {
            icons.prune(keeping: Set(content.pages.flatMap { $0.flatMap { $0.slots.map(\.pid) + $0.floaters.map(\.pid) } }))
            var images: [Int32: NSImage] = [:]
            for pid in content.pids {
                images[pid] = icons.icon(pid) { NSRunningApplication(processIdentifier: $0)?.icon }
            }
            view.icons = images
            view.content = content
            view.setAccessibilityLabel("Window switcher, \(content.app), \(content.title), \(content.position)")
        }
        let size = content.geometry.size, area = screen.visibleFrame
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

    private func makePanel(_ content: SwitcherContent) -> NSPanel {
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
        panel.contentView = SwitcherView(content: content)
        return panel
    }
}

@MainActor
final class SwitcherView: NSView {
    var icons: [Int32: NSImage] = [:] {
        didSet { if icons != oldValue { needsDisplay = true } }
    }
    var content: SwitcherContent {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    init(content: SwitcherContent) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: content.geometry.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let margin = GridIndicatorGeometry.margin, width = bounds.width - 2 * margin
        GridPainter.background(bounds)
        GridPainter.text(content.app, rect: NSRect(x: margin, y: 10, width: width - 136, height: 17), size: 12, weight: .semibold)
        GridPainter.text(content.position, rect: NSRect(x: bounds.width - margin - 130, y: 11, width: 130, height: 16), size: 10,
                         color: .secondaryLabelColor, alignment: .right)
        GridPainter.text(content.title, rect: NSRect(x: margin, y: 28, width: width, height: 16), size: 11, color: .secondaryLabelColor)
        let geometry = content.geometry
        GridPainter(area: content.area, metrics: .switcher, icons: icons)
            .grid(content.pages, rows: content.rows, columns: content.columns, geometry: geometry, labeled: content.cell,
                  current: content.shown, selected: content.selected)
        if content.cropped {
            GridPainter.text("Grid cropped around the selection", rect: geometry.footerRect, size: 9, color: .secondaryLabelColor)
        }
    }
}

extension AppDelegate {
    /// `switcher next|prev|commit|cancel`, answered here since the switcher is shell UI.
    func switcherCommand(_ argv: [String]) -> Reply {
        let usage = Reply(ok: false, text: "Expected switcher next|prev|commit|cancel")
        guard argv.count == 2 else { return usage }
        switch argv[1] {
        case "next", "prev":
            let forward = argv[1] == "next"
            if windowSwitcher.isOpen { windowSwitcher.step(forward: forward); return Reply(text: "OK") }
            let opened = openSwitcher(session: keyboard?.openSwitcher() ?? 0, forward: forward, held: false)
            return opened ? Reply(text: "OK") : Reply(ok: false, text: "No window to switch to")
        case "commit":
            return windowSwitcher.isOpen ? commitSwitcher() : Reply(ok: false, text: "The switcher is not open")
        case "cancel":
            guard let session = windowSwitcher.session else { return Reply(ok: false, text: "The switcher is not open") }
            windowSwitcher.cancel()
            keyboard?.closeSwitcher(session)
            return Reply(text: "OK")
        default: return usage
        }
    }

    /// Keys the router sent for a session; ones for a switcher that has since closed are dropped.
    func switcherKey(_ key: SwitcherKey, session: Int) {
        if case .open(let forward, let held) = key {
            if !windowSwitcher.isStale(session) { _ = openSwitcher(session: session, forward: forward, held: !held.isEmpty) }
            return
        }
        guard windowSwitcher.session == session else { return }
        switch key {
        case .step(let forward): windowSwitcher.step(forward: forward)
        case .move(let direction): windowSwitcher.move(direction)
        case .commit: _ = commitSwitcher()
        case .cancel: windowSwitcher.cancel()
        case .open: break
        }
    }

    /// Opens on the display a command without an address acts on.
    func openSwitcher(session: Int, forward: Bool, held: Bool) -> Bool {
        let state = engine.savedState()
        let opened = windowSwitcher.open(session: session, forward: forward, held: held, state: state,
                                         display: engine.commandDisplay, config: engine.config)
        if !opened { keyboard?.closeSwitcher(session) }
        return opened
    }

    /// Focuses the selection through the command path, so its page shows with the usual slide and focus follows.
    func commitSwitcher() -> Reply {
        let session = windowSwitcher.session
        guard let id = windowSwitcher.commit() else { return Reply(ok: false, text: "The switcher is not open") }
        if let session { keyboard?.closeSwitcher(session) }
        let reply = command(["window", "focus", String(id)])
        if !reply.ok { logger.info("Switcher focus \(id): \(reply.text, privacy: .public)") }
        return reply
    }

    /// The switcher's bindings work while minitile is started and not suspended; otherwise Cmd+Tab passes to macOS.
    func updateSwitcherAvailability() {
        let available = started && !quitting && suspendedReasons.isEmpty
        keyboard?.switcher(available: available)
        if !available, let session = windowSwitcher.session {
            windowSwitcher.cancel()
            keyboard?.closeSwitcher(session)
        }
    }

    /// A release of the opening binding's modifiers that the tap missed commits like one it saw.
    func checkSwitcherModifiers() {
        guard windowSwitcher.held, let decision = keyboard?.checkSwitcherModifiers() else { return }
        handleKey(decision, trace: nil)
    }
}
