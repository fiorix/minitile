import Foundation
import MinitileCore

struct PresenceRechecks {
    private var remaining: [Int32: Int] = [:]
    private var round = 0

    var isEmpty: Bool { remaining.isEmpty }
    var delay: TimeInterval { [0.15, 0.25, 0.5][min(round, 2)] }

    mutating func request(_ pids: Set<Int32>) {
        for pid in pids { remaining[pid] = 3 }
    }

    mutating func take() -> Set<Int32> {
        let pids = Set(remaining.keys)
        for pid in pids {
            let count = remaining[pid, default: 0] - 1
            remaining[pid] = count > 0 ? count : nil
        }
        round = remaining.isEmpty ? 0 : round + 1
        return pids
    }
}

/// Disappearance is confirmed after three snapshots in a row without the window's ID and pid.
struct PresenceMisses {
    struct Known: Equatable {
        var id: WindowID
        var pid: Int32
        /// The discovery ledger stamp when the window became known.
        var added: Int
    }

    private(set) var counts: [WindowID: Int] = [:]

    /// Checks the windows of `pids` against a snapshot taken at ledger stamp `taken`, and returns those confirmed gone.
    /// A window that became known after the snapshot was taken is not counted, since the snapshot may predate it.
    mutating func check(_ known: [Known], pids: Set<Int32>, snapshot: [WindowID: CGWindowRecord], taken: Int) -> [WindowID] {
        var gone: [WindowID] = []
        for window in known where pids.contains(window.pid) && window.added <= taken {
            if snapshot[window.id]?.pid == window.pid { counts.removeValue(forKey: window.id); continue }
            counts[window.id, default: 0] += 1
            if counts[window.id, default: 0] >= 3 { gone.append(window.id) }
        }
        return gone.sorted()
    }

    mutating func forget(_ id: WindowID) { counts.removeValue(forKey: id) }
}

/// A window is ordered out after three snapshots show it off screen on a shown desktop or on no Space (an inactive
/// native tab), and back on the first snapshot that shows it. Fullscreen transitions also leave all Spaces briefly.
struct OrderedOutChecks {
    struct Known: Equatable {
        var info: WindowInfo
        /// The discovery ledger stamp when the window became known.
        var added: Int
    }

    private(set) var counts: [WindowID: Int] = [:]

    /// Checks the windows of `pids` against a snapshot taken at ledger stamp `taken`, in which `offScreen` are those
    /// off screen on a shown desktop or no Space. Returns changed ordered-out states. Minimized, app-hidden and
    /// fullscreen windows tell nothing about whether their app ordered them out.
    mutating func check(_ known: [Known], pids: Set<Int32>, snapshot: [WindowID: CGWindowRecord], offScreen: Set<WindowID>,
                        taken: Int) -> [WindowID: Bool] {
        var changes: [WindowID: Bool] = [:]
        for window in known where pids.contains(window.info.pid) && window.added <= taken {
            let info = window.info
            let seen = snapshot[info.id].flatMap {
                $0.pid == info.pid && !info.minimized && !info.appHidden && !info.fullscreen ? $0.onScreen : nil
            }
            if seen == false && offScreen.contains(info.id) && !info.orderedOut {
                counts[info.id, default: 0] += 1
                if counts[info.id, default: 0] >= 3 { changes[info.id] = true; counts.removeValue(forKey: info.id) }
                continue
            }
            counts.removeValue(forKey: info.id)
            if seen == true && info.orderedOut { changes[info.id] = false }
        }
        return changes
    }

    mutating func forget(_ id: WindowID) { counts.removeValue(forKey: id) }
}
