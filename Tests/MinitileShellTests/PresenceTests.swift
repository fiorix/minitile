import Testing
@testable import minitile

@Test func notificationBurstUsesThreePidScopedPasses() {
    var rechecks = PresenceRechecks()
    for _ in 0..<100 { rechecks.request([10, 20]) }
    for delay in [0.15, 0.25, 0.5] {
        #expect(rechecks.delay == delay)
        let pids = rechecks.take()
        #expect(pids == [10, 20])
    }
    #expect(rechecks.isEmpty)
    rechecks.request([30])
    #expect(rechecks.delay == 0.15)
    let pids = rechecks.take()
    #expect(pids == [30])
}

@Test func laterNotificationsGetThreeChecksWithoutLosingOtherPids() {
    var rechecks = PresenceRechecks()
    rechecks.request([10])
    _ = rechecks.take()
    rechecks.request([20])
    let first = rechecks.take()
    let second = rechecks.take()
    let third = rechecks.take()
    #expect(first == [10, 20])
    #expect(second == [10, 20])
    #expect(third == [20])
    #expect(rechecks.isEmpty)
    rechecks.request([10])
    _ = rechecks.take()
    rechecks.request([10])
    for _ in 0..<3 {
        let pids = rechecks.take()
        #expect(pids == [10])
    }
    #expect(rechecks.isEmpty)
}
