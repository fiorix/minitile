import AppKit
import MinitileCore

@MainActor
protocol SwitcherPresenting: AnyObject {
    /// Shows `content` in the middle of the display's usable area, sliding there from the middle of `from`'s when that
    /// is another display.
    func show(_ content: SwitcherContent, display: DisplayID, from: DisplayID?)
    func hide()
}

extension SwitcherApp {
    static let finder = "com.apple.finder"

    /// The apps the native app switcher lists, other than minitile, oldest first, so the apps row keeps its order as
    /// apps come and go.
    @MainActor static func running() -> [SwitcherApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own }
            .sorted { ($0.launchDate ?? .distantPast, $0.processIdentifier) < ($1.launchDate ?? .distantPast, $1.processIdentifier) }
            .map { SwitcherApp(pid: $0.processIdentifier, name: $0.localizedName ?? "") }
    }
}

/// The switcher's main-thread side: its selection, its session with the key router, and when the panel shows. Opened
/// by a held binding, the panel waits `showDelay`, so a quick Cmd+Tab switches without it ever appearing.
@MainActor
final class WindowSwitcher {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    typealias Names = @MainActor () -> [DisplayID: String]
    typealias Apps = @MainActor () -> [SwitcherApp]
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
    /// The display the panel is on, or before it shows, the active display it starts from.
    private var presented: DisplayID?
    private let presenter: any SwitcherPresenting
    private let schedule: Schedule
    private let names: Names
    /// The running apps the apps row draws from, read when the switcher opens and on each update while it is open.
    private let apps: Apps

    init(presenter: any SwitcherPresenting, schedule: @escaping Schedule = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }, names: @escaping Names = { DisplayCatalog.names() }, apps: @escaping Apps = { SwitcherApp.running() }) {
        self.presenter = presenter
        self.schedule = schedule
        self.names = names
        self.apps = apps
    }

    var isOpen: Bool { selection != nil }

    func isStale(_ session: Int) -> Bool { session <= latest }

    /// Opens over the windows of every managed display and the apps row, replacing an open switcher. The panel starts
    /// in the middle of `display`, the active one, and slides on to the selection's display when that is another.
    /// Returns false, leaving it closed, without a managed display or anything to offer.
    func open(session: Int, forward: Bool, held: Bool, state: SavedState, display: DisplayID?, config: Config) -> Bool {
        latest = max(latest, session)
        close()
        guard let selection = SwitcherSelection(state: state, config: config, apps: apps(), forward: forward, active: display) else {
            return false
        }
        self.selection = selection
        self.session = session
        self.held = held
        self.state = state
        presented = display
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

    /// Follows model changes and apps starting and quitting. Returns the session it closed because nothing is left to
    /// offer.
    func update(state: SavedState, config: Config) -> Int? {
        guard var selection, let session else { return nil }
        guard selection.update(state: state, config: config, apps: apps()) else { close(); return session }
        self.selection = selection
        self.state = state
        redraw()
        return nil
    }

    /// Hides the panel before returning what to switch to, so the panel never shows in a transition capture. An app
    /// opens only from a panel that showed, so a quick Cmd+Tab switches to a window or does nothing.
    func commit() -> SwitcherTarget? {
        let selected = visible || selection?.selected.app == nil ? selection?.selected : nil
        close()
        return selected
    }

    func cancel() { close() }

    /// The help screen took the keyboard under `session`, so the switcher closes without changing anything and
    /// ignores opens sent before it.
    func supersede(_ session: Int) {
        latest = max(latest, session)
        close()
    }

    private func reveal(_ session: Int) {
        guard self.session == session, !visible else { return }
        willShow?()
        guard self.session == session else { return }
        visible = true
        redraw()
    }

    private func redraw() {
        guard visible, let selection, let state else { return }
        let content = SwitcherContent(selection: selection, state: state, names: names())
        guard content != shown || selection.display != presented else { return }
        shown = content
        presenter.show(content, display: selection.display, from: presented)
        presented = selection.display
    }

    private func close() {
        if visible { presenter.hide() }
        selection = nil
        session = nil
        held = false
        visible = false
        state = nil
        shown = nil
        presented = nil
    }
}

/// The switcher panel's move between displays, from the middle of one usable area to the middle of another's.
enum PanelSlide {
    static let duration: TimeInterval = 0.25

    /// A frame of `size` centered on `point`, on whole points.
    static func frame(_ size: CGSize, centeredOn point: CGPoint) -> CGRect {
        CGRect(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    /// Where the panel's origin is `elapsed` seconds into a slide, eased in and out; at `to` once the slide is over.
    static func origin(from: CGPoint, to: CGPoint, elapsed: TimeInterval) -> CGPoint {
        guard elapsed < duration else { return to }
        let t = max(0, elapsed / duration)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(2 - 2 * t, 3) / 2
        return CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
    }
}

/// A click-through panel in the middle of the display's usable area. It moves to another display by sliding there.
@MainActor
final class SwitcherPanel: SwitcherPresenting {
    /// Above the position indicator (`.floating`), the page-transition overlays (one below it) and other apps' floating
    /// windows, as the native app switcher is.
    static let level = NSWindow.Level.popUpMenu
    /// Off with Reduce Motion or `transition_ms` at 0: the panel then moves between displays at once.
    var slides = true
    private var panel: NSPanel?
    private var icons = AppIconCache<NSImage>()
    private var slide: (timer: Timer, target: NSRect)?

    func show(_ content: SwitcherContent, display: DisplayID, from: DisplayID?) {
        guard let screen = NSScreen.screen(for: display) else { hide(); return }
        let panel = self.panel ?? makePanel(content)
        self.panel = panel
        if let view = panel.styledContent as? SwitcherView {
            icons.prune(keeping: Set(content.pages.flatMap { $0.flatMap { $0.slots.map(\.pid) + $0.floaters.map(\.pid) } }
                                         + content.apps.map(\.pid)))
            var images: [Int32: NSImage] = [:]
            for pid in content.pids {
                images[pid] = icons.icon(pid) { NSRunningApplication(processIdentifier: $0)?.icon }
            }
            view.icons = images
            view.content = content
            let parts = [content.app, content.title, content.position, content.displayName ?? ""].filter { !$0.isEmpty }
            view.setAccessibilityLabel((["Window switcher"] + parts).joined(separator: ", "))
        }
        let size = content.geometry.size, area = screen.visibleFrame
        let target = PanelSlide.frame(size, centeredOn: CGPoint(x: area.midX, y: area.midY))
        if let slide, slide.target == target { return }
        // A slide starts where the panel is, mid-slide or in the middle of the display left behind; a panel not yet
        // shown starts in the middle of `from`.
        var start: NSRect?
        if slides, slide != nil || (from != nil && from != display) {
            let old = panel.isVisible ? panel.frame : from.flatMap { NSScreen.screen(for: $0)?.visibleFrame }
            start = old.map { PanelSlide.frame(size, centeredOn: CGPoint(x: $0.midX, y: $0.midY)) }
        }
        endSlide()
        if let start, start != target {
            panel.setFrame(start, display: true)
            slide(panel, from: start.origin, to: target)
        } else if panel.frame != target { panel.setFrame(target, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        endSlide()
        panel?.orderOut(nil)
    }

    func stop() {
        endSlide()
        panel?.close()
        panel = nil
    }

    /// Moves the panel's origin on each tick, which the window server does without redrawing the panel.
    private func slide(_ panel: NSPanel, from start: CGPoint, to target: NSRect) {
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                panel?.setFrameOrigin(PanelSlide.origin(from: start, to: target.origin, elapsed: elapsed))
                if elapsed >= PanelSlide.duration || panel == nil { self?.endSlide() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slide = (timer, target)
    }

    private func endSlide() {
        slide?.timer.invalidate()
        slide = nil
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
        panel.setStyledContent(SwitcherView(content: content))
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
        let geometry = content.geometry
        GridPainter.background(bounds)
        for marker in content.markers { GridPainter.marker(marker, geometry: geometry) }
        GridPainter.inner(at: geometry.inset) { drawInner(geometry) }
    }

    private func drawInner(_ geometry: GridIndicatorGeometry) {
        let s = geometry.metrics.scale, margin = geometry.margin, bounds = NSRect(origin: .zero, size: geometry.inner)
        let width = bounds.width - 2 * margin
        GridPainter.text(content.app, rect: NSRect(x: margin, y: 10 * s, width: width - 156 * s, height: 17 * s), size: 12 * s,
                         weight: .semibold)
        GridPainter.text(content.position, rect: NSRect(x: bounds.width - margin - 150 * s, y: 11 * s, width: 150 * s, height: 16 * s),
                         size: 10 * s, color: PanelStyle.dim, alignment: .right, monospaced: true)
        // The display's name shares the title's row, right-aligned under the position, as the indicator's "Active" does.
        let named = content.displayName != nil
        GridPainter.text(content.title, rect: NSRect(x: margin, y: 28 * s, width: width - (named ? 156 * s : 0), height: 16 * s),
                         size: 11 * s, color: PanelStyle.dim)
        if let name = content.displayName {
            GridPainter.text(name, rect: NSRect(x: bounds.width - margin - 150 * s, y: 29 * s, width: 150 * s, height: 16 * s),
                             size: 10 * s, color: PanelStyle.dim, alignment: .right, monospaced: true)
        }
        let painter = GridPainter(area: content.area, metrics: geometry.metrics, icons: icons)
        painter.grid(content.pages, rows: content.rows, columns: content.columns, geometry: geometry, labeled: content.labeled,
                     current: content.shown, selected: content.selected.window)
        painter.shelf(content.apps.map(\.pid), geometry: geometry, selected: content.selected.app)
        if content.cropped {
            GridPainter.text("Grid cropped around the selection", rect: geometry.footerRect, size: 9 * s, color: PanelStyle.dim,
                             monospaced: true)
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
            let opened = openSwitcher(session: keyboard?.open(.switcher) ?? 0, forward: forward, held: false)
            return opened ? Reply(text: "OK") : Reply(ok: false, text: "No window or app to switch to")
        case "commit":
            return windowSwitcher.isOpen ? commitSwitcher() : Reply(ok: false, text: "The switcher is not open")
        case "cancel":
            guard let session = windowSwitcher.session else { return Reply(ok: false, text: "The switcher is not open") }
            windowSwitcher.cancel()
            keyboard?.close(session)
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
        case .quit: quitSwitcherSelection()
        case .commit: _ = commitSwitcher()
        case .cancel: windowSwitcher.cancel()
        case .open: break
        }
    }

    /// Opens over every managed display's windows and the apps row, starting on the display a command without an
    /// address acts on. The help screen closes even when there is nothing to offer, since the router has already given
    /// the keyboard to the switcher.
    func openSwitcher(session: Int, forward: Bool, held: Bool) -> Bool {
        helpScreen.supersede(session)
        let state = engine.savedState()
        let opened = windowSwitcher.open(session: session, forward: forward, held: held, state: state,
                                         display: engine.commandDisplay, config: engine.config)
        if !opened { keyboard?.close(session) }
        return opened
    }

    /// Focuses a selected window through the command path, so its page shows with the usual slide and focus follows,
    /// and opens a selected app.
    func commitSwitcher() -> Reply {
        guard windowSwitcher.isOpen else { return Reply(ok: false, text: "The switcher is not open") }
        let session = windowSwitcher.session
        let target = windowSwitcher.commit()
        if let session { keyboard?.close(session) }
        switch target {
        case .window(let id):
            let reply = command(["window", "focus", String(id)])
            if !reply.ok { logger.info("Switcher focus \(id): \(reply.text, privacy: .public)") }
            return reply
        case .app(let pid): return openApp(pid)
        case nil: return Reply(text: "OK")
        }
    }

    /// Opens a running app as a click on its Dock icon does: it comes to the front, unhidden, and is asked to reopen,
    /// which brings back a window in most apps that show none. Plain activation, as the native app switcher does it,
    /// would leave such an app with only its menu bar.
    func openApp(_ pid: Int32) -> Reply {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return Reply(ok: false, text: "App \(pid) is not running")
        }
        guard let url = app.bundleURL else { app.activate(); return Reply(text: "OK") }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            logger.info("Switcher open \(pid): \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
        }
        return Reply(text: "OK")
    }

    /// Q asks the selection's app to quit: the selected app, or the selected window's. Only a panel on screen takes
    /// it, so nothing quits unseen, and Finder is left alone, as in the native app switcher. The switcher stays open and
    /// follows the app going away.
    func quitSwitcherSelection() {
        guard windowSwitcher.visible, let target = windowSwitcher.selection?.selected else { return }
        let pid = target.app ?? target.window.flatMap { engine.savedState().windows[$0]?.info.pid }
        guard let pid, let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != SwitcherApp.finder else { return }
        if !app.terminate() { logger.info("Switcher quit \(pid): the app did not take the request") }
    }

    /// The switcher's bindings work while minitile is started and not suspended, with a managed display and a window
    /// or an app to offer, and the help screen's while it is started and not suspended; otherwise Cmd+Tab and Cmd+H
    /// pass to macOS.
    func updateModalAvailability() {
        let help = modalsAvailable
        let switcher = help && SwitcherSelection.offers(state: engine.savedState(), config: engine.config) { SwitcherApp.running() }
        keyboard?.availability(switcher: switcher, help: help)
        if !switcher, let session = windowSwitcher.session {
            windowSwitcher.cancel()
            keyboard?.close(session)
        }
        if !help, let session = helpScreen.session {
            helpScreen.close()
            keyboard?.close(session)
        }
    }

    /// A release of the opening binding's modifiers that the tap missed commits the switcher, like one it saw.
    func checkModalModifiers() {
        guard windowSwitcher.held, let decision = keyboard?.checkModalModifiers() else { return }
        handleKey(decision, trace: nil)
    }
}
