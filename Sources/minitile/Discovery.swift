import AppKit
@preconcurrency import ApplicationServices
import CSkyLight
import MinitileCore

struct ObserverRegistrations {
    private(set) var names: Set<String> = []
    private(set) var unsupported: Set<String> = []

    /// An unsupported notification is settled, since retrying it can never succeed; other failures are retried.
    mutating func register(_ required: [String], add: (String) -> AXError) -> Bool {
        for name in required where !names.contains(name) && !unsupported.contains(name) {
            switch add(name) {
            case .success, .notificationAlreadyRegistered: names.insert(name)
            case .notificationUnsupported: unsupported.insert(name)
            default: break
            }
        }
        return required.allSatisfy { names.contains($0) || unsupported.contains($0) }
    }
}

@MainActor
final class Discovery {
    typealias Ticket = DiscoveryLedger.Ticket

    struct Window {
        var info: WindowInfo
        var element: AXUIElement
        var registrations = ObserverRegistrations()
        /// The ledger stamp when the window became known.
        var added = 0
        var fullscreen = FullscreenSigns()
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
    private var misses = PresenceMisses()
    private var orderedOutChecks = OrderedOutChecks()
    private var nativeTabs = NativeTabs()
    private var tabRechecks: Set<Int32> = []
    private var tabAppearances: Set<WindowID> = []
    private var lastFocused: [Int32: WindowID] = [:]
    private var rechecks = PresenceRechecks()
    private var recheckWork: DispatchWorkItem?
    /// A recheck pass is waiting for its snapshot; the next pass is scheduled once it arrives.
    private var rechecking = false
    private var creations: [Int32: [AXUIElement]] = [:]
    private var adoption: [WindowID: (pid: Int32, display: NativeDisplay)] = [:]
    private var ledger = DiscoveryLedger()
    private var passes = ScanPasses()
    /// Windows searched for by element number, once each: one not found is listed when its Space is shown.
    private var searched: Set<WindowID> = []
    private var transit = TransitRereads()
    /// Snapshots and app reads run here, one task per app, so a hung app delays only its own results. New windows are
    /// read here too, so the queue is not a low priority one.
    private let background = DispatchQueue(label: "minitile.discovery", qos: .userInitiated, attributes: .concurrent)
    var config: Config
    let displays: DisplayCatalog
    let smokeScope = SmokeScope()
    private let traceFocus = ProcessInfo.processInfo.environment["MINITILE_TRACE_FOCUS"] == "1"
    var frozen = false {
        didSet { if frozen { ledger.suspend() } }
    }
    var input: ((Input) -> Void)?
    var activated: ((Int32, TimeInterval) -> Void)?
    var focused: ((WindowID?) -> Void)?
    var acceptsFocus: ((Int32) -> Bool)?
    var moved: ((WindowID) -> Void)?
    var suppressGeometry: ((WindowID) -> Bool)?
    var fullScans: Int { passes.count }
    var fullScanMilliseconds: Double { passes.milliseconds }
    private(set) var recheckRequests = 0
    private(set) var recheckPasses = 0
    private let windowNotifications = [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                                       kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    init(config: Config, displays: DisplayCatalog) { self.config = config; self.displays = displays }

    func allows(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier && !app.isTerminated && app.activationPolicy != .prohibited
            && (config.onlyApps.isEmpty || app.bundleIdentifier.map(config.onlyApps.contains) == true)
    }

    /// Registration messages the app, so it runs only once the app's latest read was answered; a hung app would hold
    /// the main thread for the full timeout on each one.
    private func observe(_ app: NSRunningApplication) {
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
            AX.timed(context.element, name) {
                AXObserverAddNotification(observer, context.element, name as CFString, Unmanaged.passUnretained(context).toOpaque())
            }
        }
        guard complete else {
            for name in registrations.names {
                AX.timed(context.element, name) { AXObserverRemoveNotification(observer, context.element, name as CFString) }
            }
            logger.debug("AX app notifications incomplete for pid \(context.pid); retrying on the next scan")
            return
        }
        applications[context.pid] = context
        lastFocused[context.pid] = AX.focus(context.element).window
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func stop() {
        recheckWork?.cancel()
        recheckWork = nil
        rechecks = PresenceRechecks()
        creations.removeAll()
        applications.values.forEach { $0.stop() }
        applications.removeAll()
        nativeTabs = NativeTabs()
        tabRechecks.removeAll()
        tabAppearances.removeAll()
        lastFocused.removeAll()
    }

    func pruneIgnored() {
        for (pid, context) in applications {
            if let app = NSRunningApplication(processIdentifier: pid), allows(app) { continue }
            for id in windows.keys where windows[id]?.info.pid == pid { remove(id) }
            context.stop()
            applications.removeValue(forKey: pid)
            ledger.forget(pid)
            nativeTabs.forget(pid: pid)
            lastFocused.removeValue(forKey: pid)
        }
    }

    /// A full scan off the main thread: a WindowServer snapshot, then one read per app, each applied here as it
    /// finishes. It catches missed notifications and retries incomplete observer registrations.
    func scan() { scan(pids: nil) }

    /// Reads the given apps off the main thread, as a full scan does, without its presence check.
    func scan(pids: Set<Int32>?) {
        guard !frozen else { return }
        let pass = pids == nil ? passes.begin(at: ProcessInfo.processInfo.systemUptime) : nil
        let ticket = ledger.beginSnapshot()
        let probe = pids == nil ? offScreenProbe(nil) : nil
        background.async { [weak self] in
            let cg = CGWindowRecord.snapshot()
            let offScreen = cg.flatMap { probe?.run($0) } ?? []
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.scanned(cg, offScreen: offScreen, pids: pids, pass: pass, ticket: ticket) }
            }
        }
    }

    private func scanned(_ cg: [WindowID: CGWindowRecord]?, offScreen: Set<WindowID>, pids: Set<Int32>?, pass: Int?,
                         ticket: Ticket) {
        // The reads share the snapshot's ticket, so they begin before it ends.
        defer { ledger.endSnapshot() }
        guard ledger.accepts(ticket, frozen: frozen), let cg else {
            if let pass { passes.cancel(pass) }
            return
        }
        if pids == nil {
            checkPresence(cg, offScreen: offScreen, pids: Set(windows.values.map { $0.info.pid }), taken: ticket.stamp)
            searched.formIntersection(cg.keys)
        }
        let apps = pids.map { $0.compactMap { NSRunningApplication(processIdentifier: $0) } } ?? NSWorkspace.shared.runningApplications
        let started = selection(apps, cg: cg, reading: ledger.reading).filter { startRead($0, cg: cg, ticket: ticket, pass: pass) }
        if let pass { passes.reading(pass, reads: started.count, at: ProcessInfo.processInfo.systemUptime) }
    }

    /// Startup and adoption need every readable handle before they go on, so they scan on the main thread.
    func scanNow() {
        guard !frozen, let cg = CGWindowRecord.snapshot() else { return }
        let offScreen = offScreenProbe(nil).run(cg)
        let start = ProcessInfo.processInfo.systemUptime
        let taken = ledger.stamp
        for app in selection(NSWorkspace.shared.runningApplications, cg: cg, reading: []) {
            let request = readRequest(app, cg: cg)
            let ticket = ledger.ticket
            let read = DiscoveryReader.read(request)
            apply(read, records: request.records, ticket: ticket)
            ledger.record(read.pid, answered: read.answered)
        }
        checkPresence(cg, offScreen: offScreen, pids: Set(windows.values.map { $0.info.pid }), taken: taken)
        passes.add(milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    private func selection(_ apps: [NSRunningApplication], cg: [WindowID: CGWindowRecord], reading: Set<Int32>) -> [NSRunningApplication] {
        let allowed = apps.filter(allows)
        let candidates = allowed.map { AppCandidate(pid: $0.processIdentifier, regular: $0.activationPolicy == .regular) }
        let pids = Set(DiscoveryPlan.reads(candidates, snapshot: cg, reading: reading))
        return allowed.filter { pids.contains($0.processIdentifier) }
    }

    private func readRequest(_ app: NSRunningApplication, cg: [WindowID: CGWindowRecord], candidates: [AXUIElement]? = nil) -> AppReadRequest {
        let pid = app.processIdentifier
        let records = cg.filter { $0.value.pid == pid }
        let known = candidates != nil ? [] : windows.compactMap { id, window in
            window.info.pid == pid && records[id] != nil ? KnownElement(id: id, element: AXRef(window.element)) : nil
        }
        return AppReadRequest(pid: pid, app: AXRef(applications[pid]?.element ?? AXUIElementCreateApplication(pid)), known: known,
                              candidates: candidates?.map(AXRef.init), records: records, documents: smokeScope.directory != nil,
                              fullscreenSpaces: displays.fullscreenSpaces, searched: searched)
    }

    /// False when the app's previous read is still running.
    private func startRead(_ app: NSRunningApplication, cg: [WindowID: CGWindowRecord], candidates: [AXUIElement]? = nil,
                           ticket: Ticket, pass: Int?) -> Bool {
        guard ledger.beginRead(app.processIdentifier) else { return false }
        let request = readRequest(app, cg: cg, candidates: candidates)
        let name = app.localizedName ?? "unknown app"
        background.async { [weak self] in
            let read = DiscoveryReader.read(request)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finished(read, name: name, records: request.records, ticket: ticket, pass: pass) }
            }
        }
        return true
    }

    private func finished(_ read: AppRead, name: String, records: [WindowID: CGWindowRecord], ticket: Ticket, pass: Int?) {
        // Staleness checks need the touches kept while this read runs, so it ends after them.
        defer {
            ledger.endRead(read.pid, answered: read.answered)
            if let pass { passes.readFinished(pass, at: ProcessInfo.processInfo.systemUptime) }
        }
        if read.milliseconds > Slow.backgroundRead {
            logger.notice("Background read of \(name, privacy: .public) (pid \(read.pid)) took \(Int(read.milliseconds)) ms")
        }
        guard ledger.accepts(ticket, frozen: frozen) else { return }
        apply(read, records: records, ticket: ticket)
        keepUnresolved(read)
    }

    private func apply(_ read: AppRead, records: [WindowID: CGWindowRecord], ticket: Ticket) {
        guard let app = NSRunningApplication(processIdentifier: read.pid), allows(app) else { return }
        searched.formUnion(read.searched)
        let answers = read.answered ?? ledger.answers(read.pid)
        if answers { observe(app) }
        for window in read.windows where !ledger.stale(window.id, since: ticket) {
            if window.listed { discover(window, app: app, record: records[window.id], register: answers) }
            else { reread(window, app: app, register: answers) }
        }
    }

    /// The known windows of `pids`, or all of them, and each managed display's visible desktop.
    private func offScreenProbe(_ pids: Set<Int32>?) -> OffScreenProbe {
        OffScreenProbe(windows: windows.filter { pids?.contains($0.value.info.pid) ?? true }.map(\.key),
                       desktops: displays.displays.compactMap { display in
                           guard display.info.unmanagedReason == nil, let space = display.info.visibleSpace else { return nil }
                           return (display.identifier, space)
                       })
    }

    private func checkPresence(_ cg: [WindowID: CGWindowRecord], offScreen: Set<WindowID>, pids: Set<Int32>, taken: Int) {
        let changing = nativeTabs.changing
        let known = windows.filter { !changing.contains($0.key) }
            .map { PresenceMisses.Known(id: $0.key, pid: $0.value.info.pid, added: $0.value.added) }
        for id in misses.check(known, pids: pids, snapshot: cg, taken: taken) { remove(id) }
        checkOrderedOut(cg, offScreen: offScreen, pids: pids, taken: taken, changing: changing)
    }

    private func checkOrderedOut(_ cg: [WindowID: CGWindowRecord], offScreen: Set<WindowID>, pids: Set<Int32>, taken: Int,
                                 changing: Set<WindowID>) {
        let known = windows.values.filter { !changing.contains($0.info.id) }
            .map { OrderedOutChecks.Known(info: $0.info, added: $0.added) }
        for (id, value) in orderedOutChecks.check(known, pids: pids, snapshot: cg, offScreen: offScreen, taken: taken) {
            if traceFocus { startupLog("Ordered out id=\(id) value=\(value)") }
            guard var info = windows[id]?.info else { continue }
            info.orderedOut = value
            if !value { info.fromFrontmostApp = NSRunningApplication(processIdentifier: info.pid)?.isActive == true }
            windows[id]?.info = info
            input?(.windowUpdated(info))
        }
    }

    private func discover(_ read: WindowRead, app: NSRunningApplication, record: CGWindowRecord?, register: Bool) {
        let id = read.id, element = read.element.element
        guard let record, record.real, read.attributes.popup != true,
              smokeScope.allows(document: read.attributes.document) else { return }
        if let previous = windows[id] {
            if previous.info.pid == app.processIdentifier && CFEqual(previous.element, element) { return }
            remove(id)
        }
        let spaces = DisplayCatalog.windowSpaces(id)
        // A window first seen on a fullscreen Space is taken only if it is the full screen window itself; a window
        // its app opened beside it stays out of the grid.
        let owner = adoption[id]?.display ?? displays.owner(spaces: spaces)
            ?? (read.attributes.fullscreen == true ? displays.fullscreenOwner(spaces: spaces) : nil)
        guard let display = owner, let frame = read.attributes.frame else { return }
        var info = WindowInfo(id: id, pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                              appName: app.localizedName ?? record.app, title: record.title, frame: frame,
                              tileable: read.attributes.tileable ?? false, appHidden: app.isHidden,
                              fromFrontmostApp: app.isActive, display: display.info.id,
                              onStash: adoption[id] != nil || spaces.contains(display.info.stashSpace ?? 0))
        var signs = FullscreenSigns()
        signs.observe(attribute: read.attributes.fullscreen, space: displays.onFullscreenSpace(spaces))
        info.apply(read.attributes, appHidden: app.isHidden, geometry: suppressGeometry?(id) != true, fullscreen: signs.fullscreen)
        windows[id] = Window(info: info, element: element, added: ledger.touch(id), fullscreen: signs)
        if register { registerWindow(id) }
        if traceFocus {
            startupLog("Window appeared id=\(id) pid=\(info.pid) app_active=\(info.fromFrontmostApp) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
        }
        if !selectTab(info, group: read.tabGroup, isNew: true) { input?(.windowAppeared(info)) }
    }

    private func reread(_ read: WindowRead, app: NSRunningApplication, register: Bool) {
        // A window removed meanwhile, or replaced under the same ID, is ignored.
        guard let window = windows[read.id], CFEqual(window.element, read.element.element) else { return }
        if register { registerWindow(read.id) }
        applyAttributes(read.attributes, to: read.id, app: app, tabGroup: read.tabGroup, tabsRead: true)
    }

    private func applyAttributes(_ attributes: WindowAttributes, to id: WindowID, app: NSRunningApplication,
                                 tabGroup: AXRef? = nil, tabsRead: Bool = false) {
        guard let old = windows[id] else { return }
        if attributes.popup == true { remove(id); return }
        if smokeScope.directory != nil, let document = attributes.document, !smokeScope.allows(document: document) { remove(id); return }
        var info = old.info, signs = old.fullscreen
        signs.observe(attribute: attributes.fullscreen, space: attributes.spaces.map { displays.onFullscreenSpace($0) })
        info.apply(attributes, appHidden: app.isHidden, geometry: suppressGeometry?(id) != true, fullscreen: signs.fullscreen)
        windows[id]?.info = info
        windows[id]?.fullscreen = signs
        // Entering or leaving full screen, a window stands on no Space for a moment; it is reread until it lands.
        if transit.reread(id, inTransit: signs.fullscreen && attributes.spaces == nil) {
            DispatchQueue.main.asyncAfter(deadline: .now() + TransitRereads.interval) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.transit.fired(id) else { return }
                    self.update(id)
                }
            }
        }
        if tabsRead, selectTab(info, group: tabGroup) { return }
        if info != old.info { input?(.windowUpdated(info)) }
    }

    private func selectTab(_ info: WindowInfo, group: AXRef?, isNew: Bool = false) -> Bool {
        let previous = isNew ? lastFocused[info.pid].flatMap { id -> WindowID? in
            guard let old = windows[id]?.info, old.pid == info.pid, !old.orderedOut, !old.minimized,
                  !old.appHidden, !old.fullscreen else { return nil }
            return id
        } : nil
        guard let selection = nativeTabs.select(info.id, pid: info.pid, group: group, previousFocus: previous,
                                               now: ProcessInfo.processInfo.systemUptime, inactive: { previous in
            guard let snapshot = CGWindowRecord.snapshot() else { return false }
            guard let record = snapshot[previous] else { return true }
            guard record.pid == info.pid, !record.onScreen, let spaces = DisplayCatalog.readWindowSpaces(previous) else { return false }
            return spaces.isEmpty
        }) else { return false }
        if selection.waiting {
            if isNew { tabAppearances.insert(info.id) }
            if tabRechecks.insert(info.pid).inserted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.tabRechecks.remove(info.pid) != nil else { return }
                    self.scan(pids: [info.pid])
                }
            }
            return true
        }
        let appeared = tabAppearances.remove(info.id) != nil
        if traceFocus {
            let spaces = selection.previous.map { DisplayCatalog.windowSpaces($0) } ?? []
            let shown = selection.previous.flatMap { CGWindowRecord.snapshot()?[$0]?.onScreen }
            startupLog("Tab selection id=\(info.id) previous=\(selection.previous.map(String.init) ?? "none") spaces=\(spaces) shown=\(String(describing: shown)) group=\(group.map { CFHash($0.element) } ?? 0)")
        }
        recheckSoon(pids: [info.pid])
        guard let previous = selection.previous, let old = windows[previous], old.info.pid == info.pid else {
            if appeared { input?(.windowAppeared(info)) }
            return appeared
        }
        var info = info
        info.orderedOut = false
        info.fromFrontmostApp = NSRunningApplication(processIdentifier: info.pid)?.isActive == true
            && applications[info.pid].map { AX.focus($0.element).window == info.id } == true
        windows[previous]?.info.orderedOut = true
        windows[info.id]?.info = info
        ledger.touch(previous)
        ledger.touch(info.id)
        orderedOutChecks.forget(previous)
        orderedOutChecks.forget(info.id)
        input?(.windowTabSelected(previous: previous, info))
        return true
    }

    private func registerWindow(_ id: WindowID) {
        guard var window = windows[id], let context = applications[window.info.pid], let observer = context.observer else { return }
        let complete = window.registrations.register(windowNotifications) { name in
            AX.timed(window.element, name) {
                AXObserverAddNotification(observer, window.element, name as CFString, Unmanaged.passUnretained(context).toOpaque())
            }
        }
        if !complete { logger.debug("AX window notifications incomplete for window \(id); retrying on the next scan") }
        windows[id] = window
    }

    /// Rereads a window on the main thread, as its notifications ask. Background reads begun earlier become stale.
    func update(_ id: WindowID, tabsRead: Bool = false) {
        guard !frozen, let old = windows[id], let app = NSRunningApplication(processIdentifier: old.info.pid) else { return }
        ledger.touch(id)
        applyAttributes(DiscoveryReader.attributes(old.element, id: id, documents: smokeScope.directory != nil), to: id, app: app,
                        tabGroup: tabsRead ? NativeTabs.group(old.element) : nil, tabsRead: tabsRead)
    }

    /// A window enters and leaves full screen with a native Space change, which no window notification is sure to
    /// follow. Rereads the windows that were full screen and those now standing on a fullscreen Space.
    func spaceChanged() {
        guard !frozen else { return }
        for id in windows.keys.sorted() {
            guard let window = windows[id] else { continue }
            if window.info.fullscreen || displays.onFullscreenSpace(DisplayCatalog.windowSpaces(id)) { update(id) }
        }
    }

    /// minitile wrote the window's frame, so background reads begun earlier are stale.
    func wroteFrame(_ id: WindowID) { ledger.touch(id) }

    /// Hiding changes no attribute read through AX, so the app's windows update at once; the app is then read in the
    /// background.
    func hiddenChanged(_ app: NSRunningApplication) {
        guard !frozen, allows(app) else { return }
        for (id, window) in windows where window.info.pid == app.processIdentifier && window.info.appHidden != app.isHidden {
            windows[id]?.info.appHidden = app.isHidden
            if let info = windows[id]?.info { input?(.windowUpdated(info)) }
        }
        scan(pids: [app.processIdentifier])
    }

    func remove(_ id: WindowID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        ledger.touch(id)
        if let observer = applications[window.info.pid]?.observer {
            for name in window.registrations.names {
                AX.timed(window.element, name) { AXObserverRemoveNotification(observer, window.element, name as CFString) }
            }
        }
        misses.forget(id)
        orderedOutChecks.forget(id)
        transit.forget(id)
        nativeTabs.forget(id)
        tabAppearances.remove(id)
        input?(.windowGone(id))
    }

    func terminated(_ pid: Int32) {
        applications.removeValue(forKey: pid)?.stop()
        creations.removeValue(forKey: pid)
        ledger.forget(pid)
        nativeTabs.forget(pid: pid)
        lastFocused.removeValue(forKey: pid)
        recheckSoon(pids: [pid])
    }

    func recheckSoon(pids: Set<Int32>? = nil) {
        recheckRequests += 1
        rechecks.request(pids ?? Set(windows.values.map { $0.info.pid }))
        scheduleRecheck()
    }

    private func scheduleRecheck() {
        guard recheckWork == nil, !rechecking, !rechecks.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.recheck() } }
        recheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rechecks.delay, execute: work)
    }

    private func recheck() {
        recheckWork = nil
        guard !frozen else {
            rechecks = PresenceRechecks()
            creations.removeAll()
            return
        }
        let pids = rechecks.take()
        recheckPasses += 1
        rechecking = true
        let ticket = ledger.beginSnapshot()
        let probe = offScreenProbe(pids)
        background.async { [weak self] in
            let cg = CGWindowRecord.snapshot()
            let offScreen = cg.map(probe.run) ?? []
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.rechecked(cg, offScreen: offScreen, pids: pids, ticket: ticket) }
            }
        }
    }

    private func rechecked(_ cg: [WindowID: CGWindowRecord]?, offScreen: Set<WindowID>, pids: Set<Int32>, ticket: Ticket) {
        // The candidate reads share the snapshot's ticket, so they begin before it ends.
        defer { ledger.endSnapshot() }
        rechecking = false
        guard !frozen else {
            rechecks = PresenceRechecks()
            creations.removeAll()
            return
        }
        if ledger.accepts(ticket, frozen: frozen), let cg {
            checkPresence(cg, offScreen: offScreen, pids: pids, taken: ticket.stamp)
            // Only new-window elements need AX reads; focus/destroy bursts use CG presence alone. An app whose read
            // is running keeps its candidates for the next pass.
            for pid in pids {
                guard let app = NSRunningApplication(processIdentifier: pid), allows(app),
                      let candidates = creations[pid], !candidates.isEmpty, !ledger.reading.contains(pid) else { continue }
                creations.removeValue(forKey: pid)
                _ = startRead(app, cg: cg, candidates: candidates, ticket: ticket, pass: nil)
            }
        }
        if rechecks.isEmpty { creations.removeAll() }
        scheduleRecheck()
    }

    /// Creation candidates that are not windows yet wait for the next pass of the same recheck sequence.
    private func keepUnresolved(_ read: AppRead) {
        guard !rechecks.isEmpty else { return }
        for candidate in read.candidates {
            if let id = candidate.id, windows[id] != nil { continue }
            let element = candidate.element.element
            if creations[read.pid]?.contains(where: { CFEqual($0, element) }) != true { creations[read.pid, default: []].append(element) }
        }
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
            update(id, tabsRead: name == kAXResizedNotification)
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
                    && DisplayCatalog.windowSpaces($0.id).contains(stash)
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
        guard !frozen else { return }
        if let pid, let context = applications[pid], let app = NSRunningApplication(processIdentifier: pid),
           let element = AX.element(context.element, kAXFocusedWindowAttribute), let id = AX.id(element) {
            defer { if windows[id] != nil { lastFocused[pid] = id } }
            let group = NativeTabs.group(element)
            if windows[id] != nil, group != nil || nativeTabs.hasGroups(pid: pid) {
                ledger.touch(id)
                applyAttributes(DiscoveryReader.attributes(element, id: id, documents: smokeScope.directory != nil),
                                to: id, app: app, tabGroup: group, tabsRead: true)
            } else if let group, let record = CGWindowRecord.snapshot()?[id] {
                let read = WindowRead(id: id, element: AXRef(element), listed: true,
                                      attributes: DiscoveryReader.attributes(element, id: id, documents: smokeScope.directory != nil),
                                      tabGroup: group)
                discover(read, app: app, record: record, register: true)
            }
        }
        if case .known(let id) = acceptedFocus(pid: pid) { focused?(id) }
    }

    /// The frontmost app's focus, or unknown when `pid` is not frontmost or its focus reports are not accepted.
    func acceptedFocus(pid: Int32? = nil) -> FocusObservation {
        guard !frozen, let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return .unknown }
        let accepted = (pid == nil || pid == frontmost) && acceptsFocus?(frontmost) != false
        if traceFocus { startupLog("Focus notification pid=\(pid ?? frontmost) frontmost=\(frontmost) accepted=\(accepted)") }
        guard accepted else { return .unknown }
        let focus = currentFocus()
        if traceFocus, case .known(let id) = focus { startupLog("Focus read id=\(id.map(String.init) ?? "none")") }
        return focus
    }
}
