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

/// Right after a command changes the shown page, the app that was frontmost can still report the window minitile
/// just hid as focused. Following that report would undo the navigation, so it is treated as an echo.
enum ViewChangeEcho {
    static let interval: TimeInterval = 1.2

    static func ignores(_ id: WindowID?, state: SavedState, now: TimeInterval, until: TimeInterval) -> Bool {
        guard now < until, let id else { return false }
        return state.pageShown(holding: id) == false
    }
}

/// Some windows cannot become key, such as a small untitled window an app keeps open, and their app keeps the key
/// window it had, often on the page minitile just hid. The reread after minitile focuses such a window names that
/// window; following it would undo the navigation, so minitile keeps the page and focuses another window on it.
enum RefusedFocus {
    static func refused(_ target: WindowID, reported: WindowID?, state: SavedState) -> Bool {
        guard let reported, reported != target, state.focus == target else { return false }
        return state.pageShown(holding: target) == true && state.pageShown(holding: reported) == false
    }
}

extension SavedState {
    /// Whether the page holding `id` is its display's shown page; nil when no page holds it.
    func pageShown(holding id: WindowID) -> Bool? {
        for display in displays {
            for workspace in display.workspaces {
                for page in workspace.pages where page.windows.contains(id) {
                    return display.currentWorkspace == workspace.id && workspace.currentPage == page.id
                }
            }
        }
        return nil
    }
}

enum ActivationFocus {
    static let readDelay: TimeInterval = 0.15

    /// A recorded focus owned by another app is stale once `pid` is activated.
    static func clears(owner: Int32?, activated pid: Int32) -> Bool { owner.map { $0 != pid } ?? false }
}

/// minitile's own recent focus actions, by pid. The activations and focus notifications they cause arrive late and
/// out of order when focus moves quickly between apps, so each app's echo is kept for its own interval.
struct FocusEchoes {
    static let interval: TimeInterval = 1.2
    private(set) var until: [Int32: TimeInterval] = [:]

    var isEmpty: Bool { until.isEmpty }

    mutating func add(_ pid: Int32, now: TimeInterval) {
        until = until.filter { $0.value > now }
        until[pid] = now + Self.interval
    }

    func suppresses(_ pid: Int32, now: TimeInterval) -> Bool { until[pid].map { now < $0 } ?? false }

    /// An activation that is not an echo is the user's: minitile's pending echoes no longer apply.
    mutating func activation(_ pid: Int32, now: TimeInterval) -> Bool {
        if suppresses(pid, now: now) { return true }
        until.removeAll()
        return false
    }
}

struct ActivationTiming: Encodable {
    var pid: Int32
    var source: String
    var notification_to_submit_ms: Double
    var submission_ms: Double
    var windows: Int
}

enum FocusForwarding {
    static func accepts(pid: Int32, frontmost: Int32?, echoes: FocusEchoes, now: TimeInterval) -> Bool {
        pid == frontmost && !echoes.suppresses(pid, now: now)
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
    private var ownFocus = FocusEchoes()
    private var focusRead: DispatchWorkItem?
    private var pendingFocus: WindowID?
    /// The reread once a focus action's echo interval ends: the window minitile focused and the app's focus then.
    var focusSettled: ((_ target: WindowID, _ reported: WindowID?) -> Void)?
    private(set) var lastFocusMilliseconds = 0.0
    var warning: ((String) -> Void)?
    private(set) var lastMilliseconds = 0.0
    var activation: (pid: Int32, source: String, received: TimeInterval)?
    private(set) var activationTimings: [ActivationTiming] = []

    init(discovery: Discovery, displays: DisplayCatalog) { self.discovery = discovery; self.displays = displays }

    func suppresses(_ id: WindowID) -> Bool { suppression[id, default: 0] > ProcessInfo.processInfo.systemUptime }
    func acceptsFocus(_ pid: Int32) -> Bool {
        FocusForwarding.accepts(pid: pid, frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                echoes: ownFocus, now: ProcessInfo.processInfo.systemUptime)
    }
    func suppressesActivation(_ pid: Int32) -> Bool {
        guard !ownFocus.isEmpty else { return false }
        if ownFocus.activation(pid, now: ProcessInfo.processInfo.systemUptime) { return true }
        focusRead?.cancel()
        return false
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
            let current = DisplayCatalog.windowSpaces(id)
            if current.count == 1 { spaces[id] = current[0] }
        }
    }

    func externalMove(_ id: WindowID) { frames.removeValue(forKey: id) }

    func acceptsMove(_ id: WindowID, mouseDown: Bool) -> Bool {
        let suppressed = suppresses(id)
        let actual = suppressed && mouseDown ? discovery.windows[id].flatMap { AX.frame($0.element) } : nil
        return ReconcilePlan.acceptsMove(suppressed: suppressed, mouseDown: mouseDown, actual: actual, lastWrite: frames[id])
    }

    /// `held` marks a reconcile that waited for a slide's capture, for the slow reconcile log.
    func apply(_ output: Output, held: Bool = false) {
        let start = ProcessInfo.processInfo.systemUptime
        scene = output.scene
        let moves = ReconcilePlan.moves(scene: scene, displays: displays.infos,
                                        known: Set(discovery.windows.keys), spaces: spaces)
        for move in moves { submit(move) }
        // macOS gives a window that leaves full screen the frame it had before, so its tile is written again then.
        frames = frames.filter { discovery.windows[$0.key]?.info.fullscreen != true }
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
        if lastMilliseconds > Slow.reconcile {
            logger.notice("\(held ? "Held reconcile" : "Reconcile", privacy: .public) took \(Int(self.lastMilliseconds)) ms")
        }
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
                let actual = DisplayCatalog.windowSpaces(id)
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
                discovery.wroteFrame(id)
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

    /// The echo starts now, but the Accessibility calls run once per main-loop turn for the latest target only, so a
    /// burst of focus commands (Cmd+` pressed quickly) does not queue one slow round of calls per press.
    func focus(_ id: WindowID) {
        guard let window = discovery.windows[id] else { return }
        ownFocus.add(window.info.pid, now: ProcessInfo.processInfo.systemUptime)
        focusRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .known(let reported) = self.discovery.acceptedFocus(pid: window.info.pid) else { return }
                self.focusSettled?(id, reported)
            }
        }
        focusRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusEchoes.interval, execute: work)
        let scheduled = pendingFocus != nil
        pendingFocus = id
        if !scheduled {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.applyPendingFocus() } }
        }
    }

    private func applyPendingFocus() {
        guard let id = pendingFocus else { return }
        pendingFocus = nil
        guard let window = discovery.windows[id], let app = NSRunningApplication(processIdentifier: window.info.pid) else { return }
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastFocusMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        AX.set(window.element, kAXMainAttribute, kCFBooleanTrue)
        AX.set(window.element, kAXFocusedAttribute, kCFBooleanTrue)
        AX.perform(window.element, kAXRaiseAction)
        app.activate(options: [])
        if !csl_focus_window(window.info.pid, id) { warning?("Could not focus window \(id)") }
    }

    private func close(_ id: WindowID) {
        guard let window = discovery.windows[id], let button = AX.element(window.element, kAXCloseButtonAttribute) else { return }
        AX.perform(button, kAXPressAction)
        discovery.recheckSoon(pids: [window.info.pid])
    }
}
