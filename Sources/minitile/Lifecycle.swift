import AppKit
import CSkyLight
import MinitileCore

struct SuspensionState {
    private(set) var reasons: Set<String> = []

    /// Resume only when the last outstanding interruption ends.
    mutating func set(_ reason: String, enabled: Bool) -> Bool {
        let wasSuspended = !reasons.isEmpty
        if enabled { reasons.insert(reason) } else { reasons.remove(reason) }
        return wasSuspended && reasons.isEmpty
    }
}

enum SwitcherPressGuard {
    static func mouseDown(buttons: Int, switcherOwnsPress: Bool) -> Bool {
        buttons & 1 != 0 && !switcherOwnsPress
    }
}

struct AppearanceHooks {
    var isKnown: (WindowID, Int32) -> Bool
    var readFrame: (WindowID) -> Rect?
    var isActive: (Int32) -> Bool
    var focusedWindow: (Int32) -> FocusObservation
    var refreshFocus: () -> Void
    var retryRead: (Set<Int32>) -> Void
}

/// Holds newly discovered windows outside the core model while a non-switcher left mouse press is active, and keeps
/// entries whose mouse-up frame read failed until a later frame observation succeeds or discovery confirms removal.
struct PendingAppearances {
    struct Entry: Equatable {
        var info: WindowInfo
        /// True when discovery withheld focus on an active app's window (such as an unseen tab left behind by a detach).
        var suppressedFocus: Bool
        /// An admitted window in the core model whose slot transfers to `info.id` via `.windowTabSelected` on admission.
        var tabPrevious: WindowID?
        /// True when `info.id` is already an ordered-out window in the core model, so admission updates it in place.
        var updatesExisting = false
        /// True once a mouse-up frame read returned nil; waits for a fresh frame observation instead of 30 ms retries.
        var awaitingFrame = false
        /// A frame read delivered while the button was already up, ready to admit without another main-thread AX read.
        var recoveredFrame: Rect?
    }

    enum GoneAction: Equatable {
        case pass
        case dropped(orphanedGone: [WindowID])
        case deferred
    }

    enum TabRoute: Equatable {
        case pass
        case recorded(orphanedGone: [WindowID], activeTargetUpdate: WindowInfo?)
    }

    enum AdmissionKind: Equatable {
        case appeared(WindowInfo)
        case updated(WindowInfo)
        case tabSelected(previous: WindowID, WindowInfo)

        var input: Input {
            switch self {
            case .appeared(let info): .windowAppeared(info)
            case .updated(let info): .windowUpdated(info)
            case .tabSelected(let previous, let info): .windowTabSelected(previous: previous, info)
            }
        }
    }

    struct Admission: Equatable {
        var kind: AdmissionKind
        var deferredGone: [WindowID] = []
    }

    struct DrainResult: Equatable {
        var admissions: [Admission] = []
        var orphanedGone: [WindowID] = []
        var retryPids: Set<Int32> = []
    }

    private(set) var entries: [Entry] = []
    private(set) var deferredGone: Set<WindowID> = []

    var isEmpty: Bool { entries.isEmpty }
    var needsReleasePoll: Bool { entries.contains { !$0.awaitingFrame } }
    func contains(_ id: WindowID) -> Bool { entries.contains { $0.info.id == id } }

    mutating func appear(_ info: WindowInfo, appActive: Bool) -> [WindowID] {
        let suppressed = appActive && !info.fromFrontmostApp
        if let index = entries.firstIndex(where: { $0.info.id == info.id }) {
            if entries[index].info.pid == info.pid {
                entries[index] = Entry(info: info, suppressedFocus: suppressed, tabPrevious: entries[index].tabPrevious,
                                       updatesExisting: entries[index].updatesExisting)
                return []
            }
            let oldPrev = entries[index].tabPrevious
            entries.remove(at: index)
            entries.append(Entry(info: info, suppressedFocus: suppressed, tabPrevious: nil))
            return releaseOrphanedGone(candidates: oldPrev.map { [$0] } ?? [])
        }
        entries.append(Entry(info: info, suppressedFocus: suppressed, tabPrevious: nil))
        return []
    }

    mutating func update(_ info: WindowInfo, appActive: Bool) -> Bool {
        guard let index = entries.firstIndex(where: { $0.info.id == info.id }),
              entries[index].info.pid == info.pid else { return false }
        if entries[index].info.orderedOut && !info.orderedOut {
            entries[index].suppressedFocus = appActive && !info.fromFrontmostApp
        }
        entries[index].info = info
        return true
    }

    mutating func observeFrame(_ id: WindowID, pid: Int32, frame: Rect, mouseDown: Bool, frozen: Bool) -> Bool {
        guard let index = entries.firstIndex(where: { $0.info.id == id && $0.info.pid == pid }) else { return false }
        entries[index].info.frame = frame
        guard entries[index].awaitingFrame else { return false }
        entries[index].awaitingFrame = false
        if !mouseDown && !frozen {
            entries[index].recoveredFrame = frame
            return true
        }
        entries[index].recoveredFrame = nil
        return false
    }

    mutating func gone(_ id: WindowID, admittedInModel: Bool) -> GoneAction {
        if let index = entries.firstIndex(where: { $0.info.id == id }) {
            let removed = entries.remove(at: index)
            let orphaned = releaseOrphanedGone(candidates: removed.tabPrevious.map { [$0] } ?? [])
            return .dropped(orphanedGone: admittedInModel ? orphaned + [id] : orphaned)
        }
        if entries.contains(where: { $0.tabPrevious == id }) {
            deferredGone.insert(id)
            return .deferred
        }
        return .pass
    }

    mutating func tabSelected(previous: WindowID, info: WindowInfo, mouseDown: Bool, appActive: Bool,
                              previousState: WindowState?, targetState: WindowState?) -> TabRoute {
        let previousPending = contains(previous)
        let targetPending = contains(info.id)
        guard previousPending || targetPending || (mouseDown && targetState == nil) else { return .pass }
        if previous == info.id {
            if targetPending { _ = update(info, appActive: appActive) }
            return .recorded(orphanedGone: [], activeTargetUpdate: nil)
        }
        let suppressed = appActive && !info.fromFrontmostApp
        let updatesExisting = targetState?.info.pid == info.pid && !deferredGone.contains(info.id)
        var orphaned: [WindowID] = []
        if let prevIndex = entries.firstIndex(where: { $0.info.id == previous }) {
            let inherited = entries[prevIndex].tabPrevious
            entries[prevIndex].info.orderedOut = true
            entries[prevIndex].tabPrevious = nil
            if updatesExisting, targetState?.info.orderedOut == false, !targetPending,
               inherited == nil || inherited == info.id {
                return .recorded(orphanedGone: [], activeTargetUpdate: info)
            }
            var newInfo = info
            newInfo.orderedOut = false
            let updated = Entry(info: newInfo, suppressedFocus: suppressed, tabPrevious: inherited,
                                updatesExisting: updatesExisting)
            if let existing = entries.firstIndex(where: { $0.info.id == info.id }) {
                let oldPrev = entries[existing].tabPrevious
                entries.remove(at: existing)
                let insertAt = existing < prevIndex ? prevIndex : prevIndex + 1
                entries.insert(updated, at: insertAt)
                if let oldPrev, oldPrev != inherited { orphaned = releaseOrphanedGone(candidates: [oldPrev]) }
            } else {
                entries.insert(updated, at: prevIndex + 1)
            }
            return .recorded(orphanedGone: orphaned, activeTargetUpdate: nil)
        }
        let inherited = (previousState != nil && previousState?.info.pid == info.pid && !deferredGone.contains(previous))
            ? previous : nil
        if let inherited {
            for idx in entries.indices where entries[idx].tabPrevious == inherited && entries[idx].info.id != info.id {
                entries[idx].info.orderedOut = true
                entries[idx].tabPrevious = nil
            }
        }
        var newInfo = info
        newInfo.orderedOut = false
        let updated = Entry(info: newInfo, suppressedFocus: suppressed, tabPrevious: inherited,
                            updatesExisting: updatesExisting)
        if let existing = entries.firstIndex(where: { $0.info.id == info.id }) {
            let oldPrev = entries[existing].tabPrevious
            entries[existing] = updated
            if let oldPrev, oldPrev != inherited { orphaned = releaseOrphanedGone(candidates: [oldPrev]) }
        } else {
            entries.append(updated)
        }
        return .recorded(orphanedGone: orphaned, activeTargetUpdate: nil)
    }

    mutating func revalidate(isKnown: (WindowID, Int32) -> Bool) -> [WindowID] {
        var kept: [Entry] = []
        var removedPrevs: [WindowID] = []
        for var entry in entries {
            guard isKnown(entry.info.id, entry.info.pid) else {
                if let prev = entry.tabPrevious { removedPrevs.append(prev) }
                continue
            }
            entry.awaitingFrame = false
            entry.recoveredFrame = nil
            kept.append(entry)
        }
        entries = kept
        return releaseOrphanedGone(candidates: removedPrevs)
    }

    mutating func drain(isKnown: (WindowID, Int32) -> Bool, readFrame: (WindowID) -> Rect?,
                        isActive: (Int32) -> Bool, focusedWindow: (Int32) -> FocusObservation) -> DrainResult {
        var result = DrainResult()
        var kept: [Entry] = []
        var removedPrevs: [WindowID] = []
        var admittedPrevs: [WindowID] = []
        var focusReads = FocusReads()
        for var entry in entries {
            let id = entry.info.id, pid = entry.info.pid
            guard isKnown(id, pid) else {
                if let prev = entry.tabPrevious { removedPrevs.append(prev) }
                continue
            }
            if entry.awaitingFrame {
                kept.append(entry)
                continue
            }
            guard let frame = entry.recoveredFrame ?? readFrame(id) else {
                entry.awaitingFrame = true
                entry.recoveredFrame = nil
                kept.append(entry)
                result.retryPids.insert(pid)
                continue
            }
            entry.info.frame = frame
            entry.recoveredFrame = nil
            let active = isActive(pid)
            if entry.tabPrevious != nil || entry.suppressedFocus {
                entry.info.fromFrontmostApp = active && focusReads.read(pid, using: { focusedWindow(pid) }).window == id
            } else {
                entry.info.fromFrontmostApp = active
            }
            let kind: AdmissionKind
            if let previous = entry.tabPrevious {
                kind = .tabSelected(previous: previous, entry.info)
                admittedPrevs.append(previous)
            } else if entry.updatesExisting {
                kind = .updated(entry.info)
            } else {
                kind = .appeared(entry.info)
            }
            result.admissions.append(Admission(kind: kind))
        }
        entries = kept
        for index in result.admissions.indices {
            if case .tabSelected(let previous, _) = result.admissions[index].kind,
               !entries.contains(where: { $0.tabPrevious == previous }),
               deferredGone.remove(previous) != nil {
                result.admissions[index].deferredGone.append(previous)
            }
        }
        result.orphanedGone = releaseOrphanedGone(candidates: removedPrevs + admittedPrevs)
        return result
    }

    private mutating func releaseOrphanedGone(candidates: [WindowID]) -> [WindowID] {
        var released: [WindowID] = []
        for id in candidates where !released.contains(id) {
            if !entries.contains(where: { $0.tabPrevious == id }), deferredGone.remove(id) != nil {
                released.append(id)
            }
        }
        return released
    }
}

extension AppDelegate {
    func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        observeActivation(workspace)
        // An app that starts or quits changes the switcher's apps row, which `updateMenu` brings up to date.
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] pid in
            guard let pid else { return }
            self?.discovery?.scan(pids: [pid]); self?.discovery?.recheckSoon(pids: [pid])
            self?.updateMenu()
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] pid in
            if let pid { self?.discovery?.terminated(pid) }
            self?.updateMenu()
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observe(workspace, name) { [weak self] pid in
                guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
                self?.discovery?.hiddenChanged(app)
            }
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            self.edgeDrops?.cancel()
            self.edgePanels.hide()
            self.edgeDisplayCache.refreshSpaces { csl_current_space($0 as CFString) }
            guard self.discovery?.frozen == false else { return }
            self.displays.bounceFromStash()
            // The model learns of windows entering or leaving full screen before the reconciler rereads where
            // windows stand, so no later reconcile pulls a full screen window back to the desktop.
            _ = self.displays.spacesChanged()
            self.discovery?.spaceChanged()
            self.reconciler?.refreshSpaces()
            self.discovery?.recheckSoon()
            self.keyboard?.update(config: self.engine.config, displays: self.displays, dragged: self.reconciler?.dragging)
            self.updateSwipes()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            self?.scheduleDisplays()
            self?.updateMenu()
        }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
            self?.updateTransitions(); self?.updateMenu()
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(workspace, name) { [weak self] _ in self?.suspend("sleep", enabled: true) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(workspace, name) { [weak self] _ in
                guard let self else { return }
                self.wakeUntil = ProcessInfo.processInfo.systemUptime + 5
                // Displays almost always come back as they were. Settling only for a real change keeps the first
                // shortcuts after the screen wakes from being rejected; a monitor that arrives later still
                // reports a screen change, which settles then.
                let unchanged = self.displays.unchanged()
                logger.notice("Woke; displays unchanged: \(unchanged)")
                if !unchanged { self.scheduleDisplays() }
                self.suspend("sleep", enabled: false)
            }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.suspend("session", enabled: true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            guard let self else { return }
            if !self.displays.unchanged() { self.scheduleDisplays() }
            self.suspend("session", enabled: false)
        }
        var ticks = 0
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                self.keyboard?.checkHealth()
                self.checkModalModifiers()
                self.checkGrabModifiers()
                self.swipes?.checkHealth()
                self.edgeDrops?.checkHealth()
                self.warnings["secure-input"] = csl_secure_input_enabled() ? "Secure input is blocking keyboard shortcuts" : nil
                self.warnings["keyboard"] = self.keyboard?.unavailable == true ? "Keyboard tap unavailable; check Accessibility and restart" : nil
                self.warnings["swipes"] = self.swipes?.unavailable == true ? "Trackpad swipe tap unavailable; swipes stay with macOS until a config reload" : nil
                self.warnings["edge-drops"] = self.edgeDrops?.unavailable == true ? "Edge drop tap unavailable; screen edges stay with macOS until a config reload" : nil
                let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                self.suspend("locked", enabled: session?["CGSSessionScreenIsLocked"] as? Bool == true)
                ticks += 1
                if ticks % 3 == 0, self.discovery?.frozen == false {
                    if self.displays.spacesChanged() {
                        self.scheduleDisplays()
                    } else {
                        self.discovery?.scan()
                        self.keyboard?.update(config: self.engine.config, displays: self.displays, dragged: self.reconciler?.dragging)
                        self.updateSwipes()
                    }
                }
            }
        }
        healthTimer?.tolerance = 0.1
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.requestQuit() } }
            source.resume()
            signalSources.append(source)
        }
    }

    func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor @Sendable (Int32?) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { action(pid) }
        }
        observers.append((center, token))
    }

    func observeActivation(_ center: NotificationCenter) {
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] notification in
            let received = ProcessInfo.processInfo.systemUptime
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            let deliver: @MainActor @Sendable () -> Void = { [weak self] in
                self?.activate(pid, received: received, source: "workspace")
                self?.updateFrontmost(pid)
                // An app that gains a Dock icon without launching activates, which brings the switcher's apps row up to date.
                self?.updateMenu()
            }
            if Thread.isMainThread { MainActor.assumeIsolated { deliver() } }
            else { DispatchQueue.main.async(execute: deliver) }
        }
        observers.append((center, token))
    }

    /// The keyboard tap passes the window-cycling key through in apps minitile does not manage. Unlike `activate`,
    /// this runs for every activation, including suspended sessions and minitile's own focus actions.
    func updateFrontmost(_ pid: Int32? = nil) {
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) } ?? NSWorkspace.shared.frontmostApplication
        keyboard?.frontmost(managed: app.map { discovery?.allows($0) == true } ?? false)
    }

    func suspend(_ reason: String, enabled: Bool) {
        guard suspendedReasons.contains(reason) != enabled else { return }
        // A reconcile held for a transition goes out before freezing, which would skip it.
        if enabled { transitions.flush() }
        let wasSuspended = !suspendedReasons.isEmpty
        let shouldResume = suspension.set(reason, enabled: enabled)
        discovery?.frozen = !suspendedReasons.isEmpty
        if enabled {
            dropPanels.hide(); edgeDrops?.cancel(); edgePanels.hide(); endGrab(); cancelNativeTiling()
            suspendPendingAppearances()
            closeFocusRead?.cancel(); closeFocus = CloseFocus(); spaceSync = []
        }
        if shouldResume { resume() }
        else if wasSuspended != !suspendedReasons.isEmpty { updateSwipes() }
        updateModalAvailability()
    }

    func resume() {
        guard started, !quitting, let discovery, let reconciler else { return }
        let start = ProcessInfo.processInfo.systemUptime
        func since(_ time: TimeInterval) -> Double { (ProcessInfo.processInfo.systemUptime - time) * 1000 }
        let changed = displays.refresh()
        displays.bounceFromStash()
        // A window that went full screen meanwhile must leave the scene before it is applied again.
        discovery.spaceChanged()
        reconciler.refreshSpaces(invalidateFrames: true)
        let displaysMs = since(start)
        if changed { transitions.displaysChanged(); handle(.displaysChanged(displays.infos)) }
        else { transitions.warm() }
        do {
            if try paths.configContents() != lastConfig { _ = reloadConfig() }
        } catch { warnings["config"] = "Config: \(error)" }
        discovery.recheckSoon()
        finishDragIfReleased(cursor: CGEvent(source: nil)?.location)
        resumePendingAppearances()
        discovery.refreshFocus()
        let applyStart = ProcessInfo.processInfo.systemUptime
        reconciler.apply(Output(scene: reconciler.scene))
        let applyMs = since(applyStart)
        // The scan runs off the main thread and reports what changed as it finishes. Started after the frame writes
        // above, its reads of those windows are not stale.
        discovery.scan()
        keyboard?.update(config: engine.config, displays: displays, dragged: reconciler.dragging)
        updateSwipes()
        updateMenu()
        lastResumeMilliseconds = since(start)
        // Input waits behind this work on the main thread, so its cost is worth seeing in the log.
        logger.notice("Resume took \(Int(self.lastResumeMilliseconds)) ms: displays \(Int(displaysMs)), reconcile \(Int(applyMs))")
    }

    func scheduleDisplays() {
        displayWork?.cancel()
        suspend("display", enabled: true)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                self.suspend("display", enabled: false)
            }
        }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, wakeUntil - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    func activate(_ pid: Int32, received: TimeInterval, source: String) {
        guard started, discovery?.frozen == false, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now < viewEchoUntil, discovery?.hasTerminatedApplication() == true { closeFocus.noteClose(now: now) }
        var skipPageShow = now < spaceSwitchedUntil
        switch closeFocus.activation(pid: pid, focus: engine.savedState().focus, holding: transitions.isHolding,
                                     now: now, echoUntil: viewEchoUntil) {
        case .accept: break
        case .ignore: return
        case .refocus(let id): reconciler?.focus(id); return
        case .skipPageShow: skipPageShow = true
        }
        guard reconciler?.suppressesActivation(pid) != true else { return }
        if let lastActivation, lastActivation.pid == pid, now - lastActivation.time < 0.15 { return }
        lastActivation = (pid, now)
        // Activation races macOS's own desktop switch, so a reconcile held for a transition goes out first.
        transitions.flush()
        reconciler?.activation = (pid, source, received)
        defer { reconciler?.activation = nil }
        // No AX reads before this input: Cmd-Tab's desktop switch has a narrow race. Right after minitile switched a
        // display's Space, or right after a close while a navigation command's echo window is open, the activation is
        // macOS's answer to that, so it shows no page and only its focus is followed.
        if !skipPageShow { handle(.appActivated(pid: pid)) }
        if let app = NSRunningApplication(processIdentifier: pid), discovery?.allows(app) == false { handle(.focusChanged(nil)) }
        else { followActivatedFocus(pid) }
        discovery?.recheckSoon(pids: [pid])
    }

    /// Activation does not necessarily send a focus notification. Drop a focus owned by another app at once, then
    /// read the activated app's focus after macOS has settled its key window; an earlier read can return a stale one.
    func followActivatedFocus(_ pid: Int32) {
        let focused = engine.savedState().focus
        let owner = focused.flatMap { discovery?.windows[$0]?.info.pid }
        if ActivationFocus.clears(owner: owner, activated: pid) {
            closeFocus.activationCleared(focused, now: ProcessInfo.processInfo.systemUptime)
            handle(.focusChanged(nil))
        }
        activationFocusRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.discovery?.refreshFocus(pid: pid) }
        }
        activationFocusRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivationFocus.readDelay, execute: work)
    }

    /// Reads the frontmost app's focus a moment after a close (see `CloseFocus`), once macOS has had time to report
    /// the focus it picked.
    func checkFocusAfterClose() {
        closeFocusRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.started, !self.quitting, let discovery = self.discovery, !discovery.frozen else { return }
                let now = ProcessInfo.processInfo.systemUptime
                switch CloseFocus.step(focus: self.engine.savedState().focus, read: discovery.focusAfterClose(),
                                       holdsUnfocusedView: self.closeFocus.holdsUnfocusedView, now: now,
                                       echoUntil: self.viewEchoUntil) {
                case .none: break
                case .follow(let id): self.focusReported(id)
                case .fallback: self.handle(.noFocusAfterClose)
                }
            }
        }
        closeFocusRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivationFocus.readDelay, execute: work)
    }

    func windowMoved(_ id: WindowID) {
        guard !pendingAppearances.contains(id) else { return }
        let mouseDown = SwitcherPressGuard.mouseDown(buttons: pressedMouseButtons(), switcherOwnsPress: switcherOwnsPress)
        if !mouseDown, reconciler?.dragging != id, discovery?.frozen == false {
            trackNativeTiling(id)
            return
        }
        guard let reconciler, discovery?.frozen == false, reconciler.acceptsMove(id, mouseDown: mouseDown) else { return }
        reconciler.geometry.cancel(id)
        reconciler.externalMove(id)
        if mouseDown, reconciler.dragging == nil {
            reconciler.dragging = id
            dragTile = reconciler.scene.displays.values.lazy.compactMap { $0.frames[id] }.first
            dragOrigin = discovery?.dragOrigin(id)
            dragPress = edgeDrops?.sequence
            updateDragTracking()
            endGrab()
        }
    }

    func startSwitcherPressTimer() {
        guard switcherPressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pressedMouseButtons() & 1 == 0 else { return }
                self.switcherPressTimer?.invalidate()
                self.switcherPressTimer = nil
                self.switcherOwnsPress = false
                if self.windowSwitcher.consumeDeferredReleaseCommit() {
                    _ = self.commitSwitcher()
                }
            }
        }
        switcherPressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func updateDragTracking() {
        keyboard?.drag(reconciler?.dragging)
        engine.dragging = reconciler?.dragging
        guard reconciler?.dragging != nil else {
            dragTimer?.invalidate()
            dragTimer = nil
            dragTile = nil
            dragOrigin = nil
            dragPress = nil
            dropPickerCache = DragCache()
            edgeDisplayCache = EdgeDropDisplayCache()
            edgeDrops?.cancel()
            edgePanels.hide()
            dropPanels.hide()
            return
        }
        guard dragTimer == nil else { return }
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let start = ProcessInfo.processInfo.systemUptime
                let cursor = CGEvent(source: nil)?.location
                self.finishDragIfReleased(cursor: cursor)
                self.drainPendingAppearancesIfReleased()
                self.updateEdgePreview()
                self.updateDropPicker(cursor: cursor)
                self.dragTicks.record((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The picker for the dragged window's page, shown while the window is dragged as a move. The frame comes from the
    /// window's move notifications, so polling reads no AX attributes.
    func currentDropPicker() -> DropPicker? {
        guard !quitting, discovery?.frozen == false, let id = reconciler?.dragging, let tile = dragTile,
              let frame = discovery?.windows[id]?.info.frame, DragMove.isMove(frame, from: tile) else { return nil }
        return cachedDropPicker(for: id)
    }

    func cachedDropPicker(for id: WindowID) -> DropPicker? {
        dropPickerCache.value(window: id, generation: dragGeneration.value) {
            DropPicker(state: engine.savedState(), config: engine.config, window: id)
        }
    }

    func updateDropPicker(cursor: CGPoint?) {
        guard edgeDrops?.preview?.edge == nil else { dropPanels.hide(); return }
        guard let picker = currentDropPicker() else { dropPanels.hide(); return }
        let target = cursor.flatMap(picker.target)
        dropPanels.show(DropPickerContent(picker: picker, hovered: target), preview: target.flatMap(picker.preview))
    }

    func finishDragIfReleased(cursor: CGPoint?) {
        guard discovery?.frozen == false, let reconciler, let id = reconciler.dragging,
              pressedMouseButtons() & 1 == 0 else { return }
        let owner = updateEdgePolicy()
        guard case .ready(let release) = edgeDrops?.finish() ?? .ready(nil) else { return }
        let tile = dragTile
        let picker = cachedDropPicker(for: id)
        reconciler.dragging = nil
        updateDragTracking()
        let frame = discovery?.windows[id].flatMap { AX.frame($0.element) }
        let cursor = cursor.map { Point(x: $0.x, y: $0.y) }
        if let release, release.owner == owner, let edge = release.edge, let frame, DragMove.isMove(frame, from: release.owner.origin) {
            // Clearing both dragging flags first permits the same cross-display carry as Ctrl+Shift+arrows.
            let reply = command(edge.command(id))
            endGrab()
            if !reply.ok { logger.info("Edge drop \(id): \(reply.text, privacy: .public)") }
            return
        }
        // A native menu selection or edge snap can finish while the button is still reported down. Its final
        // resize follows the same settled path as a selection whose notifications arrive after mouse-up.
        if let frame, let tile, !DragMove.isMove(frame, from: tile) || cursor.map({ !frame.contains($0) }) == true,
           !Geometry.near(frame, tile, tolerance: 20),
           let display = engine.savedState().displays.first(where: { $0.info.id == discovery?.windows[id]?.info.display }),
           NativeTile(frame: frame, area: display.info.visibleFrame, windows: 1) != nil {
            trackNativeTiling(id)
            return
        }
        switch DropRoute.route(frame: frame, cursor: cursor, picker: picker, tile: tile) {
        case .place(let target):
            let reply = command(target.command(id))
            if !reply.ok { logger.info("Drop \(id): \(reply.text, privacy: .public)") }
        case .dragEnded(let frame, let cursor): handle(.dragEnded(id, frame: frame, cursor: cursor))
        case .ignore: break
        }
    }

    private var isLeftMouseHeldForDeferral: Bool {
        SwitcherPressGuard.mouseDown(buttons: pressedMouseButtons(), switcherOwnsPress: switcherOwnsPress)
    }

    func interceptPendingAppearance(_ input: Input) -> Bool {
        let mouseDown = isLeftMouseHeldForDeferral
        let frozen = discovery?.frozen == true || !suspendedReasons.isEmpty
        switch input {
        case .windowAppeared(let info):
            guard mouseDown || frozen || pendingAppearances.needsReleasePoll else { return false }
            let orphaned = pendingAppearances.appear(info, appActive: isPendingAppActive(info.pid))
            admitGone(orphaned)
            if !mouseDown && !frozen { drainPendingAppearancesIfReleased() }
            else { updateAppearanceTracking() }
            return true
        case .windowUpdated(let info):
            return pendingAppearances.update(info, appActive: isPendingAppActive(info.pid))
        case .windowTabSelected(let previous, let info):
            let windows = engine.savedState().windows
            switch pendingAppearances.tabSelected(previous: previous, info: info, mouseDown: mouseDown || frozen,
                                                  appActive: isPendingAppActive(info.pid), previousState: windows[previous],
                                                  targetState: windows[info.id]) {
            case .pass:
                return false
            case .recorded(let orphaned, let activeUpdate):
                admitGone(orphaned)
                if let activeUpdate { _ = handle(.windowUpdated(activeUpdate), admitting: true) }
                if !mouseDown && !frozen { drainPendingAppearancesIfReleased() }
                else { updateAppearanceTracking() }
                return true
            }
        case .windowGone(let id):
            switch pendingAppearances.gone(id, admittedInModel: engine.savedState().windows[id] != nil) {
            case .pass:
                return false
            case .deferred:
                updateAppearanceTracking()
                return true
            case .dropped(let orphaned):
                updateAppearanceTracking()
                admitGone(orphaned)
                return true
            }
        case .focusChanged(let id):
            return id.map { pendingAppearances.contains($0) } == true
        default:
            return false
        }
    }

    func suspendPendingAppearances() {
        appearanceTimer?.invalidate()
        appearanceTimer = nil
    }

    func resumePendingAppearances() {
        guard started, !quitting, discovery?.frozen != true, suspendedReasons.isEmpty else { return }
        let orphaned = pendingAppearances.revalidate { id, pid in isPendingWindowKnown(id, pid: pid) }
        admitGone(orphaned)
        if !isLeftMouseHeldForDeferral { drainPendingAppearancesIfReleased() }
        else { updateAppearanceTracking() }
    }

    func observedWindowFrame(_ id: WindowID, pid: Int32, frame: Rect) {
        let frozen = discovery?.frozen == true || !suspendedReasons.isEmpty
        let mouseDown = isLeftMouseHeldForDeferral
        if pendingAppearances.observeFrame(id, pid: pid, frame: frame, mouseDown: mouseDown, frozen: frozen) {
            drainPendingAppearancesIfReleased()
        } else {
            updateAppearanceTracking()
        }
    }

    func updateAppearanceTracking() {
        guard started, !quitting, discovery?.frozen != true, suspendedReasons.isEmpty,
              pendingAppearances.needsReleasePoll else {
            appearanceTimer?.invalidate()
            appearanceTimer = nil
            return
        }
        guard appearanceTimer == nil else { return }
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainPendingAppearancesIfReleased() }
        }
        appearanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func drainPendingAppearancesIfReleased() {
        guard started, !quitting, !drainingAppearances, discovery?.frozen != true, suspendedReasons.isEmpty,
              !isLeftMouseHeldForDeferral else { return }
        if reconciler?.dragging != nil {
            finishDragIfReleased(cursor: CGEvent(source: nil)?.location)
            guard reconciler?.dragging == nil else {
                updateAppearanceTracking()
                return
            }
        }
        guard pendingAppearances.needsReleasePoll else {
            updateAppearanceTracking()
            return
        }
        drainingAppearances = true
        let result = pendingAppearances.drain(
            isKnown: { id, pid in isPendingWindowKnown(id, pid: pid) },
            readFrame: { id in readPendingWindowFrame(id) },
            isActive: { pid in isPendingAppActive(pid) },
            focusedWindow: { pid in readPendingAppFocus(pid) }
        )
        for admission in result.admissions {
            _ = handle(admission.kind.input, admitting: true)
            admitGone(admission.deferredGone)
        }
        admitGone(result.orphanedGone)
        drainingAppearances = false
        updateAppearanceTracking()
        if !result.retryPids.isEmpty { retryPendingReads(result.retryPids) }
        if !result.admissions.isEmpty { refreshFocusAfterAdmission() }
    }

    private func admitGone(_ ids: [WindowID]) {
        for id in ids { _ = handle(.windowGone(id), admitting: true) }
    }

    private func isPendingWindowKnown(_ id: WindowID, pid: Int32) -> Bool {
        if let hooks = appearanceHooks { return hooks.isKnown(id, pid) }
        return discovery?.windows[id]?.info.pid == pid
    }

    private func readPendingWindowFrame(_ id: WindowID) -> Rect? {
        if let hooks = appearanceHooks { return hooks.readFrame(id) }
        return discovery?.windows[id].flatMap { AX.frame($0.element) }
    }

    private func isPendingAppActive(_ pid: Int32) -> Bool {
        if let hooks = appearanceHooks { return hooks.isActive(pid) }
        return NSRunningApplication(processIdentifier: pid)?.isActive == true
    }

    private func readPendingAppFocus(_ pid: Int32) -> FocusObservation {
        if let hooks = appearanceHooks { return hooks.focusedWindow(pid) }
        return discovery?.applications[pid].map { AX.focus($0.element) } ?? .unknown
    }

    private func refreshFocusAfterAdmission() {
        if let hooks = appearanceHooks { hooks.refreshFocus(); return }
        discovery?.refreshFocus()
    }

    private func retryPendingReads(_ pids: Set<Int32>) {
        if let hooks = appearanceHooks { hooks.retryRead(pids); return }
        discovery?.recheckSoon(pids: pids)
        discovery?.scan(pids: pids)
    }
}
