import Foundation

/// Thresholds, in milliseconds, above which the shell logs work that delays input at notice level.
enum Slow {
    /// A key binding or swipe waiting for the main thread, from its tap callback to the start of its handling.
    static let inputWait = 150.0
    static let keyCommand = 100.0
    static let reconcile = 100.0
    static let mainThreadAXCall = 200.0
    static let backgroundRead = 500.0
}

/// Number, total duration and longest duration of operations, in milliseconds, since creation.
struct TimingCounter {
    private(set) var count = 0
    private(set) var total = 0.0
    private(set) var longest = 0.0

    mutating func record(_ milliseconds: Double) {
        count += 1
        total += milliseconds
        longest = max(longest, milliseconds)
    }
}

/// How long key bindings and swipes waited for the main thread: the latest wait and the longest since launch.
struct InputWaits {
    private(set) var latest = 0.0
    private(set) var longest = 0.0

    /// Returns true when the wait is long enough to log.
    mutating func record(_ milliseconds: Double) -> Bool {
        latest = milliseconds
        longest = max(longest, milliseconds)
        return milliseconds > Slow.inputWait
    }
}
