import AppKit
@preconcurrency import ApplicationServices
import CSkyLight
import MinitileCore

struct ObserverRegistrations {
    private(set) var names: Set<String> = []

    mutating func register(_ required: [String], add: (String) -> AXError) -> Bool {
        for name in required where !names.contains(name) {
            let result = add(name)
            if result == .success || result == .notificationAlreadyRegistered { names.insert(name) }
        }
        return required.allSatisfy(names.contains)
    }
}

@MainActor
final class Discovery {
    struct Window {
        var info: WindowInfo
        var element: AXUIElement
        var registrations = ObserverRegistrations()
    }

    @MainActor final class Application {
        let pid: Int32
        let element: AXUIElement
        var observer: AXObserver?
        weak var owner: Discovery?

        init(pid: Int32, owner: Discovery) {
            self.pid = pid
            self.element = AXUIElementCreateApplication(pid)
            self.owner = owner
        }

        func stop() {
            if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        }
    }

    private(set) var windows: [WindowID: Window] = [:]
    private(set) var applications: [Int32: Application] = [:]
    private var misses: [WindowID: Int] = [:]
    private var rechecks = PresenceRechecks()
    private var recheckWork: DispatchWorkItem?
    private var creations: [Int32: [AXUIElement]] = [:]
    private var adoption: [WindowID: (pid: Int32, display: NativeDisplay)] = [:]
    var config: Config
    let displays: DisplayCatalog
    let smokeScope = SmokeScope()
    private let traceFocus = ProcessInfo.processInfo.environment["MINITILE_TRACE_FOCUS"] == "1"
    var frozen = false
    var input: ((Input) -> Void)?
    var activated: ((Int32, TimeInterval) -> Void)?
    var focused: ((WindowID?) -> Void)?
    var acceptsFocus: ((Int32) -> Bool)?
    var moved: ((WindowID) -> Void)?
    var suppressGeometry: ((WindowID) -> Bool)?
    private(set) var fullScans = 0
    private(set) var fullScanMilliseconds = 0.0
    private(set) var recheckRequests = 0
    private(set) var recheckPasses = 0
    private let windowNotifications = [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                                       kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    init(config: Config, displays: DisplayCatalog) { self.config = config; self.displays = displays }

    func allows(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier && !app.isTerminated && app.activationPolicy != .prohibited
            && (config.onlyApps.isEmpty || app.bundleIdentifier.map(config.onlyApps.contains) == true)
    }

    func observe(_ app: NSRunningApplication) {
        guard allows(app), applications[app.processIdentifier] == nil else { return }
        let context = Application(pid: app.processIdentifier, owner: self)
        var observer: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, { _, element, notification, pointer in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                let context = Unmanaged<Application>.fromOpaque(pointer).takeUnretainedValue()
                context.owner?.notification(pid: context.pid, element: element, name: notification as String)
            }
        }, &observer)
        guard result == .success, let observer else { return }
        context.observer = observer
        AXUIElementSetMessagingTimeout(context.element, 1)
        var registrations = ObserverRegistrations()
        let complete = registrations.register([kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                               kAXMainWindowChangedNotification, kAXApplicationActivatedNotification]) { name in
            AXObserverAddNotification(observer, context.element, name as CFString, Unmanaged.passUnretained(context).toOpaque())
        }
        guard complete else {
            for name in registrations.names { AXObserverRemoveNotification(observer, context.element, name as CFString) }
            logger.debug("AX app notifications incomplete for pid \(context.pid); retrying on the next scan")
            return
        }
        applications[context.pid] = context
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func stop() {
        recheckWork?.cancel()
        recheckWork = nil
        rechecks = PresenceRechecks()
        creations.removeAll()
        applications.values.forEach { $0.stop() }
        applications.removeAll()
    }

    func pruneIgnored() {
        for (pid, context) in applications {
            if let app = NSRunningApplication(processIdentifier: pid), allows(app) { continue }
            for id in windows.keys where windows[id]?.info.pid == pid { remove(id) }
            context.stop()
            applications.removeValue(forKey: pid)
        }
    }

    func scan() {
        guard !frozen, let cg = CGWindowRecord.snapshot() else { return }
        let start = ProcessInfo.processInfo.systemUptime
        fullScans += 1
        defer { fullScanMilliseconds += (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        for app in NSWorkspace.shared.runningApplications where allows(app) {
            observe(app)
            scan(app, cg: cg)
        }
        checkPresence(cg, pids: Set(windows.values.map { $0.info.pid }))
    }

    private func checkPresence(_ cg: [WindowID: CGWindowRecord], pids: Set<Int32>) {
        for id in Array(windows.keys) where windows[id].map({ pids.contains($0.info.pid) }) == true {
            guard let window = windows[id] else { continue }
            if cg[id]?.pid == window.info.pid { misses.removeValue(forKey: id) }
            else {
                misses[id, default: 0] += 1
                if misses[id, default: 0] >= 3 { remove(id) }
            }
        }
    }

    func scan(_ app: NSRunningApplication, cg: [WindowID: CGWindowRecord]? = nil) {
        guard !frozen, allows(app), let cg = cg ?? CGWindowRecord.snapshot() else { return }
        let element = applications[app.processIdentifier]?.element ?? AXUIElementCreateApplication(app.processIdentifier)
        let listed = AX.value(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for element in listed { discover(element, app: app, cg: cg) }
        // AXWindows omits stashed windows; retained elements remain readable.
        for (id, window) in Array(windows) where window.info.pid == app.processIdentifier && cg[id]?.pid == app.processIdentifier {
            registerWindow(id)
            update(id, app: app)
        }
    }

    private func discover(_ element: AXUIElement, app: NSRunningApplication, cg: [WindowID: CGWindowRecord]) {
        guard let id = AX.id(element), let record = cg[id], record.pid == app.processIdentifier, record.real,
              AX.value(element, kAXRoleAttribute) as? String == kAXWindowRole,
              smokeScope.allows(document: AX.value(element, kAXDocumentAttribute) as? String) else { return }
        if let previous = windows[id] {
            if previous.info.pid == app.processIdentifier && CFEqual(previous.element, element) { return }
            remove(id)
        }
        let spaces = displays.windowSpaces(id)
        guard let display = adoption[id]?.display ?? displays.owner(spaces: spaces),
              let frame = AX.frame(element) else { return }
        let info = WindowInfo(id: id, pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                              appName: app.localizedName ?? record.app, title: record.title, frame: frame,
                              tileable: false, appHidden: app.isHidden,
                              fromFrontmostApp: app.isActive, display: display.info.id,
                              onStash: adoption[id] != nil || spaces.contains(display.info.stashSpace ?? 0))
        windows[id] = Window(info: info, element: element)
        readInfo(id, app: app)
        registerWindow(id)
        if let info = windows[id]?.info {
            if traceFocus {
                startupLog("Window appeared id=\(id) pid=\(info.pid) app_active=\(info.fromFrontmostApp) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
            }
            input?(.windowAppeared(info))
        }
    }

    private func registerWindow(_ id: WindowID) {
        guard var window = windows[id], let context = applications[window.info.pid], let observer = context.observer else { return }
        let complete = window.registrations.register(windowNotifications) { name in
            AXObserverAddNotification(observer, window.element, name as CFString, Unmanaged.passUnretained(context).toOpaque())
        }
        if !complete { logger.debug("AX window notifications incomplete for window \(id); retrying on the next scan") }
        windows[id] = window
    }

    private func readInfo(_ id: WindowID, app: NSRunningApplication) {
        guard var window = windows[id] else { return }
        let element = window.element
        window.info.title = AX.value(element, kAXTitleAttribute) as? String ?? window.info.title
        window.info.minimized = AX.value(element, kAXMinimizedAttribute) as? Bool ?? window.info.minimized
        window.info.appHidden = app.isHidden
        if suppressGeometry?(id) != true { window.info.frame = AX.frame(element) ?? window.info.frame }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success,
           let subrole = AX.value(element, kAXSubroleAttribute) as? String,
           let modal = AX.value(element, kAXModalAttribute) as? Bool {
            window.info.tileable = subrole == kAXStandardWindowSubrole && !modal && settable.boolValue
        }
        windows[id] = window
    }

    func update(_ id: WindowID, app: NSRunningApplication? = nil) {
        guard !frozen, let old = windows[id],
              let app = app ?? NSRunningApplication(processIdentifier: old.info.pid) else { return }
        if smokeScope.directory != nil, let document = AX.value(old.element, kAXDocumentAttribute) as? String,
           !smokeScope.allows(document: document) { remove(id); return }
        readInfo(id, app: app)
        if let info = windows[id]?.info, info != old.info { input?(.windowUpdated(info)) }
    }

    func remove(_ id: WindowID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        if let observer = applications[window.info.pid]?.observer {
            for name in window.registrations.names {
                AXObserverRemoveNotification(observer, window.element, name as CFString)
            }
        }
        misses.removeValue(forKey: id)
        input?(.windowGone(id))
    }

    func terminated(_ pid: Int32) {
        applications.removeValue(forKey: pid)?.stop()
        creations.removeValue(forKey: pid)
        recheckSoon(pids: [pid])
    }

    func recheckSoon(pids: Set<Int32>? = nil) {
        recheckRequests += 1
        rechecks.request(pids ?? Set(windows.values.map { $0.info.pid }))
        scheduleRecheck()
    }

    private func scheduleRecheck() {
        guard recheckWork == nil, !rechecks.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recheckWork = nil
                guard !self.frozen else {
                    self.rechecks = PresenceRechecks()
                    self.creations.removeAll()
                    return
                }
                let pids = self.rechecks.take()
                self.recheckPasses += 1
                if let cg = CGWindowRecord.snapshot() {
                    self.checkPresence(cg, pids: pids)
                    // Only new-window elements need AX reads; focus/destroy bursts use CG presence alone.
                    for pid in pids {
                        guard let app = NSRunningApplication(processIdentifier: pid), self.allows(app) else { continue }
                        let candidates = self.creations.removeValue(forKey: pid) ?? []
                        for element in candidates {
                            self.discover(element, app: app, cg: cg)
                            if let id = AX.id(element), self.windows[id] != nil { continue }
                            self.creations[pid, default: []].append(element)
                        }
                    }
                }
                if self.rechecks.isEmpty { self.creations.removeAll() }
                self.scheduleRecheck()
            }
        }
        recheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rechecks.delay, execute: work)
    }

    private func notification(pid: Int32, element: AXUIElement, name: String) {
        let received = ProcessInfo.processInfo.systemUptime
        guard !frozen else { return }
        // Activation must reach the reconciler before any AX discovery reads.
        if name == kAXApplicationActivatedNotification { activated?(pid, received); return }
        if name == kAXFocusedWindowChangedNotification || name == kAXMainWindowChangedNotification {
            refreshFocus(pid: pid)
            recheckSoon(pids: [pid])
            return
        }
        if name == kAXWindowCreatedNotification {
            if creations[pid]?.contains(where: { CFEqual($0, element) }) != true { creations[pid, default: []].append(element) }
            recheckSoon(pids: [pid])
            return
        }
        let id = AX.id(element) ?? windows.first { $0.value.info.pid == pid && CFEqual($0.value.element, element) }?.key
        if name == kAXUIElementDestroyedNotification { recheckSoon(pids: [pid]); return }
        if let id, windows[id] != nil {
            if name == kAXMovedNotification || name == kAXResizedNotification { moved?(id) }
            update(id)
        } else { recheckSoon(pids: [pid]) }
    }

    /// Temporarily expose allowed stash windows to acquire AX handles at startup.
    func prepareStash() {
        guard !frozen, let cg = CGWindowRecord.snapshot() else { return }
        let allowed = Set(NSWorkspace.shared.runningApplications.filter(allows).map(\.processIdentifier))
        for display in displays.displays where display.info.unmanagedReason == nil {
            guard let stash = display.info.stashSpace, let visible = display.info.visibleSpace else { continue }
            let records = cg.values.filter {
                windows[$0.id] == nil && $0.real && allowed.contains($0.pid) && smokeScope.allowsStash(id: $0.id, pid: $0.pid)
                    && displays.windowSpaces($0.id).contains(stash)
            }
            let ids = records.map(\.id).sorted()
            guard !ids.isEmpty, csl_move_windows(ids, ids.count, visible) else { continue }
            for record in records { adoption[record.id] = (record.pid, display) }
        }
    }

    var missingAdoptionHandles: [WindowID] { adoption.keys.filter { windows[$0] == nil }.sorted() }
    var adoptionCount: Int { adoption.count }

    func finishAdoption(restoreAll: Bool = false) {
        // Unreadable windows retain their original desktop and are never adopted by guesswork.
        for (id, original) in adoption where restoreAll || windows[id] == nil {
            guard CGWindowRecord.snapshot()?[id]?.pid == original.pid, let stash = original.display.info.stashSpace else { continue }
            var id = id
            _ = csl_move_windows(&id, 1, stash)
        }
        adoption.removeAll()
    }

    func currentFocus() -> FocusObservation {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        guard allows(app) else { return .known(nil) }
        guard let context = applications[app.processIdentifier] else { return .unknown }
        return AX.focus(context.element)
    }

    func refreshFocus(pid: Int32? = nil) {
        guard !frozen, let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let accepted = (pid == nil || pid == frontmost) && acceptsFocus?(frontmost) != false
        if traceFocus { startupLog("Focus notification pid=\(pid ?? frontmost) frontmost=\(frontmost) accepted=\(accepted)") }
        guard accepted else { return }
        if case .known(let id) = currentFocus() {
            if traceFocus { startupLog("Focus read id=\(id.map(String.init) ?? "none")") }
            focused?(id)
        }
    }
}
