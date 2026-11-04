import Foundation

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
