import AppKit
@preconcurrency import ApplicationServices
import CSkyLight
import MinitileCore

@MainActor
final class Discovery {
    struct Window {
        var info: WindowInfo
        var element: AXUIElement
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
    private var adoption: [WindowID: (pid: Int32, display: NativeDisplay)] = [:]
    var config: Config
    let displays: DisplayCatalog
    let smokeScope = SmokeScope()
    var frozen = false
    var input: ((Input) -> Void)?
    var activated: ((Int32) -> Void)?
    var focused: ((WindowID?) -> Void)?
    var moved: ((WindowID) -> Void)?
    var suppressGeometry: ((WindowID) -> Bool)?

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
        applications[context.pid] = context
        AXUIElementSetMessagingTimeout(context.element, 1)
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                     kAXMainWindowChangedNotification, kAXApplicationActivatedNotification] {
            AXObserverAddNotification(observer, context.element, name as CFString, Unmanaged.passUnretained(context).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func stop() {
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
        for app in NSWorkspace.shared.runningApplications where allows(app) {
            observe(app)
            scan(app, cg: cg)
        }
        for id in Array(windows.keys) {
            guard let window = windows[id] else { continue }
            if cg[id]?.pid == window.info.pid { misses.removeValue(forKey: id) }
            else {
                misses[id, default: 0] += 1
                if misses[id, default: 0] >= 3 { remove(id) }
            }
        }
    }

    func scan(_ app: NSRunningApplication, cg: [WindowID: CGWindowRecord]? = nil) {
        guard !frozen, allows(app), let context = applications[app.processIdentifier],
              let cg = cg ?? CGWindowRecord.snapshot() else { return }
        let listed = AX.value(context.element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for element in listed { discover(element, app: app, cg: cg) }
        // AXWindows omits stashed windows; retained elements remain readable.
        for (id, window) in Array(windows) where window.info.pid == app.processIdentifier && cg[id]?.pid == app.processIdentifier {
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
        if let context = applications[app.processIdentifier], let observer = context.observer {
            for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                         kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(context).toOpaque())
            }
        }
        if let info = windows[id]?.info { input?(.windowAppeared(info)) }
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
            for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                         kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                AXObserverRemoveNotification(observer, window.element, name as CFString)
            }
        }
        misses.removeValue(forKey: id)
        input?(.windowGone(id))
    }

    func terminated(_ pid: Int32) {
        applications.removeValue(forKey: pid)?.stop()
        recheckSoon()
    }

    func recheckSoon() {
        for delay in [0.15, 0.4, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
        }
    }

    private func notification(pid: Int32, element: AXUIElement, name: String) {
        guard !frozen else { return }
        // Activation must reach the reconciler before any AX discovery reads.
        if name == kAXApplicationActivatedNotification { activated?(pid); return }
        if name == kAXFocusedWindowChangedNotification || name == kAXMainWindowChangedNotification {
            let current = applications[pid].flatMap { AX.element($0.element, kAXFocusedWindowAttribute) }.flatMap(AX.id)
            focused?(current)
            recheckSoon()
            return
        }
        let id = AX.id(element) ?? windows.first { $0.value.info.pid == pid && CFEqual($0.value.element, element) }?.key
        if name == kAXUIElementDestroyedNotification { recheckSoon(); return }
        if let id, windows[id] != nil {
            if name == kAXMovedNotification || name == kAXResizedNotification { moved?(id) }
            update(id)
        } else { recheckSoon() }
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

    func currentFocus() -> WindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication, let context = applications[app.processIdentifier],
              let element = AX.element(context.element, kAXFocusedWindowAttribute) else { return nil }
        return AX.id(element)
    }
}
