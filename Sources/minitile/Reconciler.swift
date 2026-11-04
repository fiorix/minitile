import AppKit
import CSkyLight
import MinitileCore

struct SpaceMove: Equatable {
    var windows: [WindowID]
    var space: UInt64
}

enum ReconcilePlan {
    static func acceptsMove(suppressed: Bool, mouseDown: Bool, actual: Rect?, lastWrite: Rect?) -> Bool {
        guard suppressed else { return true }
        guard mouseDown, let actual, let lastWrite else { return false }
        return !Geometry.near(actual, lastWrite, tolerance: 20)
    }

    /// Return every show before any hide, including when pages change on several displays.
    static func moves(scene: Scene, displays: [DisplayInfo], known: Set<WindowID>, spaces: [WindowID: UInt64]) -> [SpaceMove] {
        var shown: [SpaceMove] = [], hidden: [SpaceMove] = []
        for display in displays.sorted(by: { $0.id < $1.id }) where display.unmanagedReason == nil {
            guard let desired = scene.displays[display.id], let visible = display.visibleSpace, let stash = display.stashSpace else { continue }
            let show = desired.visible.filter { known.contains($0) && spaces[$0] != visible }
            let hide = desired.stashed.filter { known.contains($0) && spaces[$0] != stash }
            if !show.isEmpty { shown.append(SpaceMove(windows: show, space: visible)) }
            if !hide.isEmpty { hidden.append(SpaceMove(windows: hide, space: stash)) }
        }
        return shown + hidden
    }
}

enum ActivationFocus {
    static let readDelay: TimeInterval = 0.15

    /// A recorded focus owned by another app is stale once `pid` is activated.
    static func clears(owner: Int32?, activated pid: Int32) -> Bool { owner.map { $0 != pid } ?? false }
}

struct FocusEcho {
    var pid: Int32
    var until: TimeInterval

    func suppresses(_ pid: Int32, now: TimeInterval) -> Bool { self.pid == pid && now < until }
}

struct ActivationTiming: Encodable {
    var pid: Int32
    var source: String
    var notification_to_submit_ms: Double
    var submission_ms: Double
    var windows: Int
}

enum FocusForwarding {
    static func accepts(pid: Int32, frontmost: Int32?, echo: FocusEcho?, now: TimeInterval) -> Bool {
        pid == frontmost && echo?.suppresses(pid, now: now) != true
    }
}

@MainActor
final class Reconciler {
    let discovery: Discovery
    let displays: DisplayCatalog
    var dragging: WindowID?
    private(set) var scene = Scene()
    private var spaces: [WindowID: UInt64] = [:]
    private var frames: [WindowID: Rect] = [:]
    private var deferred: [WindowID: Rect] = [:]
    private var suppression: [WindowID: TimeInterval] = [:]
    private var ownFocus: FocusEcho?
    private var focusRead: DispatchWorkItem?
    var warning: ((String) -> Void)?
    private(set) var lastMilliseconds = 0.0
    var activation: (pid: Int32, source: String, received: TimeInterval)?
    private(set) var activationTimings: [ActivationTiming] = []

    init(discovery: Discovery, displays: DisplayCatalog) { self.discovery = discovery; self.displays = displays }

    func suppresses(_ id: WindowID) -> Bool { suppression[id, default: 0] > ProcessInfo.processInfo.systemUptime }
    func acceptsFocus(_ pid: Int32) -> Bool {
        FocusForwarding.accepts(pid: pid, frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                echo: ownFocus, now: ProcessInfo.processInfo.systemUptime)
    }
    func suppressesActivation(_ pid: Int32) -> Bool {
        guard let ownFocus else { return false }
        if pid != ownFocus.pid {
            self.ownFocus = nil
            focusRead?.cancel()
            return false
        }
        return ownFocus.suppresses(pid, now: ProcessInfo.processInfo.systemUptime)
    }

    func forget(_ id: WindowID) {
        spaces.removeValue(forKey: id); frames.removeValue(forKey: id)
        suppression.removeValue(forKey: id); deferred.removeValue(forKey: id)
        if dragging == id { dragging = nil }
    }

    func refreshSpaces(invalidateFrames: Bool = false) {
        if invalidateFrames { frames.removeAll() }
        spaces = [:]
        for id in discovery.windows.keys {
            let current = displays.windowSpaces(id)
            if current.count == 1 { spaces[id] = current[0] }
        }
    }

    func externalMove(_ id: WindowID) { frames.removeValue(forKey: id) }

    func acceptsMove(_ id: WindowID, mouseDown: Bool) -> Bool {
        let suppressed = suppresses(id)
        let actual = suppressed && mouseDown ? discovery.windows[id].flatMap { AX.frame($0.element) } : nil
        return ReconcilePlan.acceptsMove(suppressed: suppressed, mouseDown: mouseDown, actual: actual, lastWrite: frames[id])
    }

    func apply(_ output: Output) {
        let start = ProcessInfo.processInfo.systemUptime
        scene = output.scene
        let moves = ReconcilePlan.moves(scene: scene, displays: displays.infos,
                                        known: Set(discovery.windows.keys), spaces: spaces)
        for move in moves { submit(move) }
        var targets = scene.displays.values.reduce(into: [WindowID: Rect]()) { $0.merge($1.frames) { _, new in new } }
        for action in output.actions {
            if case .setFrame(let id, let frame) = action { deferred[id] = frame }
        }
        targets.merge(deferred) { _, new in new }
        let writes = targets.filter { id, target in
            id != dragging && discovery.windows[id] != nil && (frames[id] != target || output.rewrite.contains(id))
        }
        writeFrames(writes, verify: true)
        for id in deferred.keys where id != dragging { deferred.removeValue(forKey: id) }
        // Focus runs after all other actions, including close and explicit float resize.
        for action in output.actions {
            if case .close(let id) = action { close(id) }
        }
        lastMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    private func submit(_ move: SpaceMove, verify: Bool = true) {
        let before = ProcessInfo.processInfo.systemUptime
        guard csl_move_windows(move.windows, move.windows.count, move.space) else {
            warning?("Could not submit a desktop move"); return
        }
        if let activation {
            let submitted = ProcessInfo.processInfo.systemUptime
            activationTimings.append(ActivationTiming(pid: activation.pid, source: activation.source,
                notification_to_submit_ms: (submitted - activation.received) * 1000,
                submission_ms: (submitted - before) * 1000, windows: move.windows.count))
            if activationTimings.count > 128 { activationTimings.removeFirst() }
            self.activation = nil
        }
        let until = ProcessInfo.processInfo.systemUptime + 1.2
        let identities = move.windows.compactMap { id in discovery.windows[id].map { (id, $0.info.pid) } }
        for id in move.windows { spaces[id] = move.space; suppression[id] = until }
        guard verify else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.discovery.frozen else { return }
            let failed = identities.compactMap { id, pid -> WindowID? in
                guard self.discovery.windows[id]?.info.pid == pid, self.spaces[id] == move.space else { return nil }
                let actual = self.displays.windowSpaces(id)
                return !actual.isEmpty && !actual.contains(move.space) ? id : nil
            }
            if !failed.isEmpty {
                self.warning?("Desktop move did not settle for windows \(failed)")
                self.submit(SpaceMove(windows: failed, space: move.space), verify: false)
            }
        }
    }

    private func writeFrames(_ writes: [WindowID: Rect], verify: Bool) {
        let groups = Dictionary(grouping: writes.keys) { discovery.windows[$0]!.info.pid }
        for (pid, ids) in groups {
            let app = discovery.applications[pid]?.element ?? AXUIElementCreateApplication(pid)
            let enhanced = AX.value(app, "AXEnhancedUserInterface") as? Bool
            if enhanced == true { AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
            for id in ids {
                guard let window = discovery.windows[id], let target = writes[id] else { continue }
                frames[id] = target
                suppression[id] = ProcessInfo.processInfo.systemUptime + 1.2
                AX.setFrame(window.element, target)
                if verify {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
                        guard let self, !self.discovery.frozen, NSEvent.pressedMouseButtons & 1 == 0,
                              self.dragging != id, self.frames[id] == target,
                              let current = self.discovery.windows[id], CFEqual(current.element, window.element),
                              let actual = AX.frame(current.element) else { return }
                        if !Geometry.near(actual, target, tolerance: 20) { self.writeFrames([id: target], verify: false) }
                        self.discovery.update(id)
                    }
                }
            }
            if enhanced == true { AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
        }
    }

    func focus(_ id: WindowID) {
        guard let window = discovery.windows[id], let app = NSRunningApplication(processIdentifier: window.info.pid) else { return }
        ownFocus = FocusEcho(pid: window.info.pid, until: ProcessInfo.processInfo.systemUptime + 1.2)
        focusRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.discovery.refreshFocus(pid: window.info.pid) }
        }
        focusRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        AX.set(window.element, kAXMainAttribute, kCFBooleanTrue)
        AX.set(window.element, kAXFocusedAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        app.activate(options: [])
        if !csl_focus_window(window.info.pid, id) { warning?("Could not focus window \(id)") }
    }

    private func close(_ id: WindowID) {
        guard let window = discovery.windows[id], let button = AX.element(window.element, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        discovery.recheckSoon(pids: [window.info.pid])
    }
}
