import AppKit
import MinitileCore

/// AX move and resize notifications arrive separately, and reads can lag minitile's own writes. Hold the old
/// target until the burst and any write echo have settled. A new command's target cancels that hold.
struct GeometrySettlement {
    struct Pending: Equatable {
        var pid: Int32
        var target: Rect
        var due: TimeInterval
        var mayRestore: Bool
    }
    private(set) var pending: [WindowID: Pending] = [:]

    mutating func observe(_ id: WindowID, pid: Int32, target: Rect, now: TimeInterval, suppressedUntil: TimeInterval, mayRestore: Bool = true) {
        pending[id] = Pending(pid: pid, target: target, due: max(now + 0.25, suppressedUntil + 0.05), mayRestore: mayRestore)
    }

    mutating func cancel(_ id: WindowID) { pending.removeValue(forKey: id) }

    mutating func holds(_ id: WindowID, target: Rect) -> Bool {
        guard let change = pending[id] else { return false }
        guard change.target == target else { cancel(id); return false }
        return true
    }

    func ready(state: SavedState, now: TimeInterval) -> [WindowID: Pending] {
        let waiting = Set(state.displays.flatMap(\.workspaces).flatMap(\.pages).flatMap { page in
            page.windows.contains(where: { pending[$0].map { $0.due > now } == true }) ? page.windows : []
        })
        return pending.filter { $0.value.due <= now && !waiting.contains($0.key) }
    }
}

struct NativeSelection {
    var window: WindowID
    var frame: Rect
    var companions: [WindowID: Rect]

    init?(page: PageState, state: SavedState, area: Rect, actual: [WindowID: Rect], targets: [WindowID: Rect]) {
        let active = page.windows.filter { id in
            state.windows[id].map { !$0.floating && !$0.hidden && !$0.info.fullscreen && !$0.info.minimized && !$0.info.appHidden } == true
        }
        let changed = actual.filter { id, frame in
            active.contains(id) && targets[id].map { !Geometry.near(frame, $0, tolerance: 3) } == true
                && NativeTile(frame: frame, area: area, windows: 1) != nil
        }
        guard let id = state.focus.flatMap({ changed[$0] == nil ? nil : $0 }) ?? active.first(where: { changed[$0] != nil }),
              let frame = changed[id] else { return nil }
        let companions = changed.filter { $0.key != id }
        guard NativeTile(frame: frame, area: area, windows: active.count, companions: companions.keys.sorted().compactMap { companions[$0] }) != nil else { return nil }
        self.window = id; self.frame = frame; self.companions = companions
    }
}

extension AppDelegate {
    func trackNativeTiling(_ id: WindowID) {
        guard let reconciler, let window = discovery?.windows[id], !window.info.fullscreen,
              let target = reconciler.scene.displays.values.lazy.compactMap({ $0.frames[id] }).first else { return }
        reconciler.observeGeometry(id, pid: window.info.pid, target: target)
        guard nativeTileTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleNativeTiling() }
        }
        nativeTileTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelNativeTiling() {
        nativeTileTimer?.invalidate(); nativeTileTimer = nil
        reconciler?.geometry = GeometrySettlement()
    }

    func settleNativeTiling() {
        guard !quitting, let discovery, !discovery.frozen, let reconciler else { cancelNativeTiling(); return }
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let state = engine.savedState()
        let ready = reconciler.geometry.ready(state: state, now: now)
        var actual: [WindowID: Rect] = [:]
        for (id, pending) in ready {
            reconciler.geometry.cancel(id)
            guard let window = discovery.windows[id],
                  window.info.pid == pending.pid, reconciler.dragging != id else {
                continue
            }
            guard let frame = AX.frame(window.element) else { continue }
            actual[id] = frame
        }
        for display in state.displays where display.info.unmanagedReason == nil {
            guard let workspace = display.workspaces.first(where: { $0.id == display.currentWorkspace }),
                  let page = workspace.pages.first(where: { $0.id == workspace.currentPage }),
                  let selection = NativeSelection(page: page, state: state, area: display.info.visibleFrame,
                                                  actual: actual, targets: ready.mapValues(\.target)) else { continue }
            reconciler.acceptNativeFrame(selection.window, frame: selection.frame)
            for (id, frame) in selection.companions { reconciler.acceptNativeFrame(id, frame: frame) }
            handle(.nativeTiled(selection.window, frame: selection.frame, companions: selection.companions))
        }
        // Unrecognized app-driven geometry returns to its tile once. A window's minimum size can prevent the
        // requested frame; notifications from that correction must not start an endless write/read loop.
        for (id, pending) in ready where pending.mayRestore {
            if let frame = actual[id], !Geometry.near(frame, pending.target, tolerance: 20) {
                reconciler.restoreGeometry(id, target: pending.target)
            }
        }
        if reconciler.geometry.pending.isEmpty { cancelNativeTiling() }
    }
}
