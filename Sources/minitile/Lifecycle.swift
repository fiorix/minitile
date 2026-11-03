import AppKit
import CSkyLight
import MinitileCore

extension AppDelegate {
    func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] pid in
            if let pid { self?.activate(pid) }
        }
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] pid in
            guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
            self?.discovery?.observe(app); self?.discovery?.recheckSoon()
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
            self.scheduleDisplays()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.scheduleDisplays() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(workspace, name) { [weak self] _ in self?.suspend("sleep", enabled: true) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(workspace, name) { [weak self] _ in
                guard let self else { return }
                self.wakeUntil = ProcessInfo.processInfo.systemUptime + 5
                self.suspend("sleep", enabled: false)
                self.scheduleDisplays()
            }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.suspend("session", enabled: true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            self?.suspend("session", enabled: false); self?.scheduleDisplays()
        }
        var ticks = 0
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                self.keyboard?.checkHealth()
                self.warnings["secure-input"] = csl_secure_input_enabled() ? "Secure input is blocking keyboard shortcuts" : nil
                self.warnings["keyboard"] = self.keyboard?.unavailable == true ? "Keyboard tap unavailable; check Accessibility and restart" : nil
                let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                self.suspend("locked", enabled: session?["CGSSessionScreenIsLocked"] as? Bool == true)
                ticks += 1
                if ticks % 3 == 0, self.discovery?.frozen == false {
                    self.discovery?.scan()
                    self.keyboard?.update(config: self.engine.config, displays: self.displays, dragged: self.reconciler?.dragging)
                }
                self.updateMenu()
            }
        }
        dragTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishDragIfReleased() }
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

    func suspend(_ reason: String, enabled: Bool) {
        if enabled { suspendedReasons.insert(reason) } else { suspendedReasons.remove(reason) }
        discovery?.frozen = !suspendedReasons.isEmpty
    }

    func scheduleDisplays() {
        displayWork?.cancel()
        suspend("display", enabled: true)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                self.suspend("display", enabled: false)
                guard self.discovery?.frozen == false else { return }
                let changed = self.displays.refresh()
                self.displays.bounceFromStash()
                self.reconciler?.refreshSpaces()
                if changed { self.handle(.displaysChanged(self.displays.infos)) }
                do {
                    if try self.paths.configContents() != self.lastConfig { _ = self.reloadConfig() }
                } catch { self.warnings["config"] = "Config: \(error)" }
                self.discovery?.scan()
                self.keyboard?.update(config: self.engine.config, displays: self.displays, dragged: self.reconciler?.dragging)
                self.updateMenu()
            }
        }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, wakeUntil - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    func activate(_ pid: Int32) {
        guard started, discovery?.frozen == false, reconciler?.suppressesActivation(pid) != true,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastActivation, lastActivation.pid == pid, now - lastActivation.time < 0.15 { return }
        lastActivation = (pid, now)
        // No AX reads before this input: Cmd-Tab's desktop switch has a narrow race.
        handle(.appActivated(pid: pid))
        if discovery?.applications[pid] == nil { handle(.focusChanged(nil)) }
        discovery?.recheckSoon()
    }

    func windowMoved(_ id: WindowID) {
        guard let reconciler, !reconciler.suppresses(id), discovery?.frozen == false else { return }
        reconciler.externalMove(id)
        if NSEvent.pressedMouseButtons & 1 != 0, reconciler.dragging == nil {
            reconciler.dragging = id
            keyboard?.drag(id)
        }
    }

    func finishDragIfReleased() {
        guard discovery?.frozen == false, let reconciler, let id = reconciler.dragging,
              NSEvent.pressedMouseButtons & 1 == 0 else { return }
        reconciler.dragging = nil
        keyboard?.drag(nil)
        guard let element = discovery?.windows[id]?.element, let frame = AX.frame(element),
              let location = CGEvent(source: nil)?.location else { return }
        handle(.dragEnded(id, frame: frame, cursor: Point(x: location.x, y: location.y)))
    }
}
