import AppKit
@preconcurrency import ApplicationServices
import CSkyLight
import MinitileCore
import MinitileIPC
import OSLog

let logger = Logger(subsystem: "minitile", category: "shell")

func startupLog(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("minitile: \(message)\n".utf8))
}

@main
enum MinitileMain {
    @MainActor static func main() {
        startupLog("Process launched from \(Bundle.main.bundlePath)")
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths = ShellPaths()
    let status = StatusMenu()
    let gridIndicator = GridIndicator()
    let switcherPanel = SwitcherPanel()
    lazy var windowSwitcher = WindowSwitcher(presenter: switcherPanel)
    let helpPanel = HelpPanel()
    lazy var helpScreen = HelpScreen(presenter: helpPanel)
    let dropPanels = DropPickerPanels()
    let grabPanel = GrabPanel()
    lazy var grabHighlight = GrabHighlight(presenter: grabPanel)
    let desktopNotice = DesktopNotice()
    let transitions = Transitions()
    var screenRecordingRequested = false
    var permissionTimer: Timer?
    var engine = Engine()
    var started = false
    var starting = false
    var startupStashCount = 0
    var startupImmediateHandles = 0
    var warnings: [String: String] = [:]
    let displays = DisplayCatalog()
    var discovery: Discovery?
    var reconciler: Reconciler?
    var keyboard: KeyboardTap?
    var swipes: SwipeTap?
    var server: Server?
    var configWatcher: ConfigWatcher?
    lazy var stateWriter = StateWriter(file: paths.state)
    var saved: SavedState?
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var healthTimer: Timer?
    var dragTimer: Timer?
    /// The dragged window's tile when the drag began.
    var dragTile: Rect?
    var displayWork: DispatchWorkItem?
    var wakeUntil: TimeInterval = 0
    var lastActivation: (pid: Int32, time: TimeInterval)?
    var activationFocusRead: DispatchWorkItem?
    /// Keeps App Nap away: a windowless accessory app looks idle, and a napping one handles keys and gestures late.
    var napActivity: NSObjectProtocol?
    var lastResumeMilliseconds = 0.0
    /// The display the latest command crossed into, if it did; a swipe that crosses moves the pointer there.
    var lastCrossed: DisplayID?
    var inputWaits = InputWaits()
    var viewEchoUntil: TimeInterval = 0
    var lastConfig: String?
    var quitting = false
    var signalSources: [DispatchSourceSignal] = []
    var suspension = SuspensionState()
    var suspendedReasons: Set<String> { suspension.reasons }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startupLog("Application launched; Accessibility trusted: \(AXIsProcessTrusted())")
        napActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                            reason: "Window management responds to keys and gestures")
        status.command = { [weak self] in self?.command($0) ?? Reply(ok: false, text: "Starting") }
        watchConfig()
        if !AXIsProcessTrusted() {
            warnings["accessibility"] = "Grant Accessibility to Minitile.app in System Settings > Privacy & Security"
            updateMenu()
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    self?.permissionTimer?.invalidate()
                    self?.permissionTimer = nil
                    self?.warnings.removeValue(forKey: "accessibility")
                    self?.start()
                }
            }
        } else { start() }
    }

    func start() {
        guard !started, !starting else { return }
        starting = true
        warnings.removeValue(forKey: "startup")
        startupLog("Checking SkyLight and display setup")
        var error = [CChar](repeating: 0, count: 1024)
        guard csl_init(&error, error.count) else {
            fail(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }); return
        }
        guard NSScreen.screensHaveSeparateSpaces else {
            fail(SetupAdvice.separateSpaces.title); return
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        // Keep IPC available after a config error so mntl can retry startup.
        if server == nil {
            do {
                let server = Server(path: try socketPath(), handlerQueue: .main) { [weak self] argv, complete in
                    MainActor.assumeIsolated {
                        guard let self else { complete(Reply(ok: false, text: "Stopping")); return }
                        let reply = self.command(argv)
                        // Scripts expect windows to have been moved once a command returns; a watcher must not miss events.
                        if argv == ["watch"] { complete(reply) } else { self.transitions.afterReconcile { complete(reply) } }
                    }
                }
                try server.start()
                self.server = server
                startupLog("Listening on \(try socketPath())")
            } catch { fail(String(describing: error)); NSApp.terminate(nil); return }
        }
        do {
            lastConfig = try paths.configContents()
            engine = Engine(config: try Config.parse(lastConfig))
            warnings.removeValue(forKey: "config")
        }
        catch { fail("Config: \(error)"); return }
        startupLog("Config loaded; only_apps: \(engine.config.onlyApps)")
        displays.refresh()
        displays.bounceFromStash()
        let discovery = Discovery(config: engine.config, displays: displays)
        self.discovery = discovery
        let reconciler = Reconciler(discovery: discovery, displays: displays)
        self.reconciler = reconciler
        reconciler.warning = { [weak self] message in self?.warnings["reconcile"] = message; self?.updateMenu() }
        // A dragged window's frame is read as it moves, even right after a write, since the drop picker follows it.
        discovery.suppressGeometry = { [weak reconciler] id in reconciler.map { $0.suppresses(id) && $0.dragging != id } == true }
        do { saved = try stateWriter.read() }
        catch { warnings["state"] = "Cannot restore saved state: \(error)" }
        discovery.prepareStash()
        discovery.scanNow()
        startupStashCount = discovery.adoptionCount
        startupImmediateHandles = startupStashCount - discovery.missingAdoptionHandles.count
        logger.info("Startup stash handles immediately available: \(self.startupImmediateHandles)/\(self.startupStashCount)")
        finishStart(attempt: 0)
    }

    func finishStart(attempt: Int) {
        guard let discovery, let reconciler, !quitting else { return }
        if !discovery.missingAdoptionHandles.isEmpty, attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.discovery?.scanNow(); self?.finishStart(attempt: attempt + 1)
            }
            return
        }
        if !discovery.missingAdoptionHandles.isEmpty {
            warnings["adoption"] = "Could not read stash windows \(discovery.missingAdoptionHandles); left them on the stash"
        }
        discovery.finishAdoption()
        reconciler.refreshSpaces()
        started = true
        starting = false
        handle(.started(saved: saved, windows: discovery.windows.values.map(\.info).sorted { $0.id < $1.id },
                        displays: displays.infos, focus: discovery.currentFocus().window))
        saved = nil
        discovery.input = { [weak self] in self?.handle($0) }
        discovery.activated = { [weak self] pid, received in self?.activate(pid, received: received, source: "ax") }
        discovery.acceptsFocus = { [weak reconciler] in reconciler?.acceptsFocus($0) == true }
        discovery.focused = { [weak self] in self?.focusReported($0) }
        discovery.moved = { [weak self] in self?.windowMoved($0) }
        transitions.commit = { [weak self] in self?.commitHeld($0) }
        transitions.model = { [weak self] in self?.engine.savedState() ?? SavedState() }
        transitions.visibleIsCurrent = { [weak self] id in
            guard let display = self?.displays.displays.first(where: { $0.info.id == id }), let visible = display.info.visibleSpace else { return true }
            return csl_current_space(display.identifier as CFString) == visible
        }
        transitions.uncovered = { [weak self] in self?.updateGrab() }
        grabHighlight.due = { [weak self] in self?.updateGrab() }
        updateTransitions()
        let keyboard = KeyboardTap(traceEnabled: ProcessInfo.processInfo.environment["MINITILE_TRACE_KEYS"] == "1") { [weak self] decision, trace, received in
            self?.handleKey(decision, trace: trace, received: received)
        }
        keyboard.update(config: engine.config, displays: displays, dragged: nil)
        self.keyboard = keyboard
        updateFrontmost()
        windowSwitcher.willShow = { [weak self] in self?.checkModalModifiers() }
        helpPanel.clickedOutside = { [weak self] in
            guard let self, let session = self.helpScreen.session else { return }
            self.helpScreen.close()
            self.keyboard?.close(session)
        }
        updateModalAvailability()
        keyboard.start()
        updateSwipes()
        observeLifecycle()
        startupLog("Ready; \(displays.infos.count) displays, \(discovery.windows.count) windows")
        updateMenu()
        configWatcher?.changed?()
    }

    /// Watch before startup parses the config, so correcting an initial error can retry startup.
    func watchConfig() {
        guard configWatcher == nil else { return }
        let watcher = ConfigWatcher(file: paths.config)
        watcher.changed = { [weak self] in
            guard let self, !self.quitting else { return }
            do {
                let contents = try self.paths.configContents()
                if !self.started || contents != self.lastConfig { _ = self.command(["config", "reload"]) }
            } catch { self.warnings["config"] = "Config: \(error)"; self.updateMenu() }
        }
        watcher.start()
        configWatcher = watcher
    }

    func fail(_ message: String) {
        starting = false
        startupLog("Startup failed: \(message)")
        warnings["startup"] = message
        updateMenu()
    }

    func updateMenu() {
        updateModalAvailability()
        let snapshot = engine.savedState()
        gridIndicator.update(state: snapshot, config: engine.config)
        if let closed = windowSwitcher.update(state: snapshot, config: engine.config) { keyboard?.close(closed) }
        updateGrab()
        desktopNotice.update(needing: started && !quitting ? DesktopNoticeTiming.needing(displays.infos) : [])
        let active = snapshot.activeDisplay ?? displays.infos.first(where: \.isPrimary)?.id
        let label = started ? active.flatMap { reconciler?.scene.displays[$0]?.label } : nil
        status.update(label: label, warnings: statusWarnings,
                      state: started ? "\(snapshot.windows.count) windows, \(displays.infos.count) displays" : "Starting")
    }

    /// The menu's warnings, with advice for each display setup minitile cannot make itself.
    var statusWarnings: StatusWarnings {
        let advice = SetupAdvice.list(displays: displays.infos, names: DisplayCatalog.names(),
                                      separateSpaces: NSScreen.screensHaveSeparateSpaces)
        return StatusWarnings(warnings.values, advice: advice)
    }

    /// `grab` is the key router's session of a binding whose modifiers hold a grab; commands without one grab for a
    /// moment.
    @discardableResult func command(_ argv: [String], grab: Int? = nil) -> Reply {
        if argv == ["quit"], !started || discovery?.frozen == true { requestQuit(); return Reply() }
        if !started, argv == ["config", "open"] {
            do { try paths.openConfig(); return Reply() }
            catch { return Reply(ok: false, text: String(describing: error)) }
        }
        if !started, argv == ["config", "reload"] {
            guard AXIsProcessTrusted() else { return Reply(ok: false, text: "Waiting for Accessibility permission") }
            start()
            return Reply(ok: warnings["startup"] == nil, text: warnings["startup"] ?? "Starting")
        }
        if argv.first == "debug" { return debug(Array(argv.dropFirst())) }
        guard started, !quitting else { return Reply(ok: false, text: "minitile is starting or stopping") }
        if argv == ["help", "show"] { return helpCommand() }
        let readOnly = [["state"], ["help"], ["watch"], ["ignore"]].contains(argv)
            || (argv.count >= 2 && ["list", "info"].contains(argv[1]))
        if discovery?.frozen == true, !readOnly {
            return Reply(ok: false, text: "Session inactive; window changes are suspended")
        }
        if argv.first == "switcher" { return switcherCommand(argv) }
        return handle(.command(argv), grab: grab) ?? Reply()
    }

    @discardableResult func handle(_ input: Input, grab session: Int? = nil) -> Reply? {
        guard started, !quitting else { return nil }
        if case .windowGone(let id) = input { reconciler?.forget(id); updateDragTracking() }
        var argv: [String]?
        if case .command(let command) = input { argv = command }
        let before = argv.map { _ in engine.savedState() }
        let context = argv.flatMap { _ in engine.commandDisplay }
        var grabbing: (argv: [String], focus: WindowID?)?
        if let argv, GrabCommand.grabs(argv) { grabbing = (argv, before?.focus) }
        let output = engine.handle(input)
        let grab = grabbing.flatMap { GrabCommand(argv: $0.argv, focus: $0.focus, output: output) }
        // The pointer already holds a dragged window, so nothing grabs it, Ctrl+arrow during the drag included.
        if let grab, grab.window != reconciler?.dragging {
            grabHighlight.command(grab, session: session, focus: engine.savedState().focus)
        }
        if case .command = input, output.events.contains(where: { $0.type == "page_shown" }) {
            viewEchoUntil = ProcessInfo.processInfo.systemUptime + ViewChangeEcho.interval
        }
        var plan: [DisplayID: TransitionKind] = [:]
        if let argv, let before, output.reply?.ok == true {
            let after = engine.savedState()
            let crossed = output.crossed
            lastCrossed = crossed
            // A display crossed into usually keeps its shown page, which alone would not show the indicator there.
            if let crossed { gridIndicator.show(on: crossed) }
            plan = TransitionPlan.plan(before: before, after: after, argv: argv, context: context, crossed: crossed != nil)
        }
        let held = transitions.hold(output, plan: plan, before: before)
        if !held, discovery?.frozen != true { reconciler?.apply(output) }
        var reply = output.reply
        for action in output.actions {
            switch action {
            case .reloadConfig: reply = reloadConfig()
            case .openConfig:
                do { try paths.openConfig() }
                catch { reply = Reply(ok: false, text: String(describing: error)) }
            case .quit: requestQuit()
            default: break
            }
        }
        if !held {
            for action in output.actions {
                if case .focus(let id) = action { reconciler?.focus(id) }
            }
        }
        for event in output.events { server?.broadcast(event: event) }
        if output.stateChanged {
            stateWriter.save(engine.savedState()) { [weak self] error in
                self?.warnings["state-save"] = error; self?.updateMenu()
            }
        }
        updateMenu()
        return reply
    }

    /// A focus report from discovery, minus echoes of a command having just hidden the reported window.
    func focusReported(_ id: WindowID?) {
        let now = ProcessInfo.processInfo.systemUptime
        if ViewChangeEcho.ignores(id, state: engine.savedState(), now: now, until: viewEchoUntil) { return }
        handle(.focusChanged(id))
    }

    /// Apply a reconcile that waited for a transition capture, with the same ordering as `handle`.
    func commitHeld(_ output: Output) {
        if discovery?.frozen != true { reconciler?.apply(output, held: true) }
        for action in output.actions {
            if case .focus(let id) = action { reconciler?.focus(id) }
        }
        updateMenu()
    }

    func updateTransitions() {
        let milliseconds = engine.config.transitionMs
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let granted = CGPreflightScreenCaptureAccess()
        transitions.configure(milliseconds: milliseconds, reduceMotion: reduceMotion, screenRecording: granted)
        // The switcher's slide between displays moves its own panel, so it needs no screen capture.
        switcherPanel.slides = milliseconds > 0 && !reduceMotion
        let missing = TransitionGate.needsPermission(milliseconds: milliseconds, reduceMotion: reduceMotion, screenRecording: granted)
        if missing, !screenRecordingRequested {
            screenRecordingRequested = true
            _ = CGRequestScreenCaptureAccess()
        }
        warnings["transitions"] = missing ? "Grant Screen Recording to Minitile.app for page transitions" : nil
    }

    func reloadConfig() -> Reply {
        guard discovery?.frozen != true else { return Reply(ok: false, text: "Config reload deferred while the session is inactive") }
        do {
            let contents = try paths.configContents()
            let config = try Config.parse(contents)
            lastConfig = contents
            warnings.removeValue(forKey: "config")
            handle(.configLoaded(config))
            updateTransitions()
            discovery?.config = config
            discovery?.pruneIgnored()
            discovery?.prepareStash()
            discovery?.scanNow()
            finishReloadAdoption(attempt: 0)
            keyboard?.update(config: config, displays: displays, dragged: reconciler?.dragging)
            // A reload retries a swipe tap that could not be created.
            if swipes?.unavailable == true { swipes = nil }
            updateSwipes()
            updateFrontmost()
            return Reply(text: "Config reloaded")
        } catch {
            warnings["config"] = "Config: \(error)"
            updateMenu()
            return Reply(ok: false, text: "Config: \(error)")
        }
    }

    func finishReloadAdoption(attempt: Int) {
        guard !quitting, let discovery else { return }
        if !discovery.missingAdoptionHandles.isEmpty, attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.discovery?.scanNow(); self?.finishReloadAdoption(attempt: attempt + 1)
            }
        } else { discovery.finishAdoption() }
    }

    func requestQuit() {
        guard !quitting else { return }
        quitting = true
        endGrab()
        updateModalAvailability()
        keyboard?.stop()
        updateSwipes()
        // Let the background socket writer flush the quit reply before stopping it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        keyboard?.stop(); swipes?.stop(); server?.stop(); configWatcher?.stop(); discovery?.finishAdoption(restoreAll: true); discovery?.stop()
        gridIndicator.stop()
        windowSwitcher.cancel()
        switcherPanel.stop()
        helpScreen.close()
        helpPanel.stop()
        dropPanels.stop()
        grabPanel.stop()
        desktopNotice.stop()
        transitions.stop()
        permissionTimer?.invalidate(); healthTimer?.invalidate(); dragTimer?.invalidate(); displayWork?.cancel(); activationFocusRead?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        signalSources.forEach { $0.cancel() }
        stateWriter.flush()
    }
}
