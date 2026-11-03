import AppKit
@preconcurrency import ApplicationServices
import CSkyLight
import MinitileCore
import MinitileIPC
import OSLog

let logger = Logger(subsystem: "minitile", category: "shell")

@main
enum MinitileMain {
    @MainActor static func main() {
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
    var server: Server?
    var configWatcher: ConfigWatcher?
    lazy var stateWriter = StateWriter(file: paths.state)
    var saved: SavedState?
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var healthTimer: Timer?
    var dragTimer: Timer?
    var displayWork: DispatchWorkItem?
    var wakeUntil: TimeInterval = 0
    var lastActivation: (pid: Int32, time: TimeInterval)?
    var lastConfig: String?
    var quitting = false
    var signalSources: [DispatchSourceSignal] = []
    var suspendedReasons: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.command = { [weak self] in self?.command($0) ?? Reply(ok: false, text: "Starting") }
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
        var error = [CChar](repeating: 0, count: 1024)
        guard csl_init(&error, error.count) else {
            fail(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }); return
        }
        guard NSScreen.screensHaveSeparateSpaces else {
            fail("Displays have separate Spaces must be enabled"); return
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        do {
            lastConfig = try paths.configContents()
            engine = Engine(config: try Config.parse(lastConfig))
        }
        catch { fail("Config: \(error)"); return }
        do {
            let server = Server(path: try socketPath(), handlerQueue: .main) { [weak self] argv, complete in
                MainActor.assumeIsolated { complete(self?.command(argv) ?? Reply(ok: false, text: "Stopping")) }
            }
            try server.start()
            self.server = server
        } catch { fail(String(describing: error)); NSApp.terminate(nil); return }
        displays.refresh()
        displays.bounceFromStash()
        let discovery = Discovery(config: engine.config, displays: displays)
        self.discovery = discovery
        let reconciler = Reconciler(discovery: discovery, displays: displays)
        self.reconciler = reconciler
        reconciler.warning = { [weak self] message in self?.warnings["reconcile"] = message; self?.updateMenu() }
        discovery.suppressGeometry = { [weak reconciler] in reconciler?.suppresses($0) == true }
        do { saved = try stateWriter.read() }
        catch { warnings["state"] = "Cannot restore saved state: \(error)" }
        discovery.prepareStash()
        discovery.scan()
        startupStashCount = discovery.adoptionCount
        startupImmediateHandles = startupStashCount - discovery.missingAdoptionHandles.count
        logger.info("Startup stash handles immediately available: \(self.startupImmediateHandles)/\(self.startupStashCount)")
        finishStart(attempt: 0)
    }

    func finishStart(attempt: Int) {
        guard let discovery, let reconciler, !quitting else { return }
        if !discovery.missingAdoptionHandles.isEmpty, attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.discovery?.scan(); self?.finishStart(attempt: attempt + 1)
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
                        displays: displays.infos, focus: discovery.currentFocus()))
        saved = nil
        discovery.input = { [weak self] in self?.handle($0) }
        discovery.activated = { [weak self] in self?.activate($0) }
        discovery.focused = { [weak self] id in
            guard let self, self.reconciler?.suppressesFocus(id) != true else { return }
            self.handle(.focusChanged(id))
        }
        discovery.moved = { [weak self] in self?.windowMoved($0) }
        let keyboard = KeyboardTap { [weak self] in _ = self?.command($0) }
        keyboard.update(config: engine.config, displays: displays, dragged: nil)
        self.keyboard = keyboard
        keyboard.start()
        let watcher = ConfigWatcher(file: paths.config)
        watcher.changed = { [weak self] in
            guard let self else { return }
            do {
                let contents = try self.paths.configContents()
                if contents != self.lastConfig { _ = self.reloadConfig() }
            } catch { self.warnings["config"] = "Config: \(error)"; self.updateMenu() }
        }
        watcher.start()
        configWatcher = watcher
        observeLifecycle()
        updateMenu()
    }

    func fail(_ message: String) {
        starting = false
        logger.error("\(message, privacy: .public)")
        warnings["startup"] = message
        updateMenu()
    }

    func updateMenu() {
        for key in warnings.keys where key.hasPrefix("display:") { warnings.removeValue(forKey: key) }
        for display in displays.infos {
            if let reason = display.unmanagedReason { warnings["display:\(display.id)"] = "\(display.id): \(reason)" }
        }
        let snapshot = engine.savedState()
        let active = snapshot.activeDisplay ?? displays.infos.first(where: \.isPrimary)?.id
        let label = active.flatMap { reconciler?.scene.displays[$0]?.label } ?? "minitile"
        status.update(label: label, warnings: warnings.values.sorted(),
                      state: started ? "\(snapshot.windows.count) windows, \(displays.infos.count) displays" : "Starting")
    }

    @discardableResult func command(_ argv: [String]) -> Reply {
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
        let readOnly = [["state"], ["help"], ["watch"]].contains(argv)
            || (argv.count >= 2 && ["list", "info"].contains(argv[1]))
        if discovery?.frozen == true, !readOnly {
            return Reply(ok: false, text: "Session inactive; window changes are suspended")
        }
        return handle(.command(argv)) ?? Reply()
    }

    @discardableResult func handle(_ input: Input) -> Reply? {
        guard started, !quitting else { return nil }
        if case .windowGone(let id) = input { reconciler?.forget(id); keyboard?.drag(reconciler?.dragging) }
        let output = engine.handle(input)
        if discovery?.frozen != true { reconciler?.apply(output) }
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
        for action in output.actions {
            if case .focus(let id) = action { reconciler?.focus(id) }
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

    func reloadConfig() -> Reply {
        guard discovery?.frozen != true else { return Reply(ok: false, text: "Config reload deferred while the session is inactive") }
        do {
            let contents = try paths.configContents()
            let config = try Config.parse(contents)
            lastConfig = contents
            warnings.removeValue(forKey: "config")
            handle(.configLoaded(config))
            discovery?.config = config
            discovery?.pruneIgnored()
            discovery?.prepareStash()
            discovery?.scan()
            finishReloadAdoption(attempt: 0)
            keyboard?.update(config: config, displays: displays, dragged: reconciler?.dragging)
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
                self?.discovery?.scan(); self?.finishReloadAdoption(attempt: attempt + 1)
            }
        } else { discovery.finishAdoption() }
    }

    func requestQuit() {
        guard !quitting else { return }
        quitting = true
        keyboard?.stop()
        // Let the background socket writer flush the quit reply before stopping it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        keyboard?.stop(); server?.stop(); configWatcher?.stop(); discovery?.finishAdoption(restoreAll: true); discovery?.stop()
        permissionTimer?.invalidate(); healthTimer?.invalidate(); dragTimer?.invalidate(); displayWork?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        signalSources.forEach { $0.cancel() }
        stateWriter.flush()
    }
}
