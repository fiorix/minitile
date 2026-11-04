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

extension AppDelegate {
    func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        observeActivation(workspace)
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] pid in
            guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
            self?.discovery?.observe(app); self?.discovery?.scan(app); self?.discovery?.recheckSoon(pids: [pid])
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] pid in
            if let pid { self?.discovery?.terminated(pid) }
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observe(workspace, name) { [weak self] pid in
                guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
                self?.discovery?.scan(app)
            }
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self, self.discovery?.frozen == false else { return }
            self.displays.bounceFromStash()
            self.reconciler?.refreshSpaces()
            self.discovery?.recheckSoon()
            self.keyboard?.update(config: self.engine.config, displays: self.displays, dragged: self.reconciler?.dragging)
            self.updateSwipes()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.scheduleDisplays() }
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
                self.scheduleDisplays()
                self.suspend("sleep", enabled: false)
            }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.suspend("session", enabled: true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            self?.scheduleDisplays(); self?.suspend("session", enabled: false)
        }
        var ticks = 0
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                self.keyboard?.checkHealth()
                self.checkSwitcherModifiers()
                self.checkGrabModifiers()
                self.swipes?.checkHealth()
                self.warnings["secure-input"] = csl_secure_input_enabled() ? "Secure input is blocking keyboard shortcuts" : nil
                self.warnings["keyboard"] = self.keyboard?.unavailable == true ? "Keyboard tap unavailable; check Accessibility and restart" : nil
                self.warnings["swipes"] = self.swipes?.unavailable == true ? "Trackpad swipe tap unavailable; swipes stay with macOS until a config reload" : nil
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
                self.updateMenu()
            }
        }
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
        // A reconcile held for a transition goes out before freezing, which would skip it.
        if enabled { transitions.flush() }
        let wasSuspended = !suspendedReasons.isEmpty
        let shouldResume = suspension.set(reason, enabled: enabled)
        discovery?.frozen = !suspendedReasons.isEmpty
        if enabled { dropPanels.hide(); endGrab() }
        if shouldResume { resume() }
        else if wasSuspended != !suspendedReasons.isEmpty { updateSwipes() }
        updateSwitcherAvailability()
    }

    func resume() {
        guard started, !quitting, let discovery, let reconciler else { return }
        let changed = displays.refresh()
        displays.bounceFromStash()
        reconciler.refreshSpaces(invalidateFrames: true)
        if changed { transitions.displaysChanged(); handle(.displaysChanged(displays.infos)) }
        do {
            if try paths.configContents() != lastConfig { _ = reloadConfig() }
        } catch { warnings["config"] = "Config: \(error)" }
        discovery.scan()
        discovery.recheckSoon()
        finishDragIfReleased()
        discovery.refreshFocus()
        reconciler.apply(Output(scene: reconciler.scene))
        keyboard?.update(config: engine.config, displays: displays, dragged: reconciler.dragging)
        updateSwipes()
        updateMenu()
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
        guard started, discovery?.frozen == false, reconciler?.suppressesActivation(pid) != true,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastActivation, lastActivation.pid == pid, now - lastActivation.time < 0.15 { return }
        lastActivation = (pid, now)
        // Activation races macOS's own desktop switch, so a reconcile held for a transition goes out first.
        transitions.flush()
        reconciler?.activation = (pid, source, received)
        defer { reconciler?.activation = nil }
        // No AX reads before this input: Cmd-Tab's desktop switch has a narrow race.
        handle(.appActivated(pid: pid))
        if let app = NSRunningApplication(processIdentifier: pid), discovery?.allows(app) == false { handle(.focusChanged(nil)) }
        else { followActivatedFocus(pid) }
        discovery?.recheckSoon(pids: [pid])
    }

    /// Activation does not necessarily send a focus notification. Drop a focus owned by another app at once, then
    /// read the activated app's focus after macOS has settled its key window; an earlier read can return a stale one.
    func followActivatedFocus(_ pid: Int32) {
        let owner = engine.savedState().focus.flatMap { discovery?.windows[$0]?.info.pid }
        if ActivationFocus.clears(owner: owner, activated: pid) { handle(.focusChanged(nil)) }
        activationFocusRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.discovery?.refreshFocus(pid: pid) }
        }
        activationFocusRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivationFocus.readDelay, execute: work)
    }

    func windowMoved(_ id: WindowID) {
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        guard let reconciler, discovery?.frozen == false, reconciler.acceptsMove(id, mouseDown: mouseDown) else { return }
        reconciler.externalMove(id)
        if mouseDown, reconciler.dragging == nil {
            reconciler.dragging = id
            dragTile = reconciler.scene.displays.values.lazy.compactMap { $0.frames[id] }.first
            updateDragTracking()
            endGrab()
        }
    }

    func updateDragTracking() {
        keyboard?.drag(reconciler?.dragging)
        guard reconciler?.dragging != nil else {
            dragTimer?.invalidate()
            dragTimer = nil
            dragTile = nil
            dropPanels.hide()
            return
        }
        guard dragTimer == nil else { return }
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishDragIfReleased()
                self?.updateDropPicker()
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
        return DropPicker(state: engine.savedState(), config: engine.config, window: id)
    }

    func updateDropPicker() {
        guard let picker = currentDropPicker() else { dropPanels.hide(); return }
        let target = CGEvent(source: nil).flatMap { picker.target(at: $0.location) }
        dropPanels.show(DropPickerContent(picker: picker, hovered: target), preview: target.flatMap(picker.preview))
    }

    func finishDragIfReleased() {
        guard discovery?.frozen == false, let reconciler, let id = reconciler.dragging,
              NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let tile = dragTile
        reconciler.dragging = nil
        updateDragTracking()
        let frame = discovery?.windows[id].flatMap { AX.frame($0.element) }
        let cursor = CGEvent(source: nil).map { Point(x: $0.location.x, y: $0.location.y) }
        let picker = DropPicker(state: engine.savedState(), config: engine.config, window: id)
        switch DropRoute.route(frame: frame, cursor: cursor, picker: picker, tile: tile) {
        case .place(let target):
            let reply = command(target.command(id))
            if !reply.ok { logger.info("Drop \(id): \(reply.text, privacy: .public)") }
        case .dragEnded(let frame, let cursor): handle(.dragEnded(id, frame: frame, cursor: cursor))
        case .ignore: break
        }
    }
}
