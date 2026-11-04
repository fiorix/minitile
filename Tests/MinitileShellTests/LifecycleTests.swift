import Testing
@testable import minitile

@Test func resumeWaitsForEveryInterruptionAndRunsOnce() {
    var suspension = SuspensionState()
    for (reason, enabled) in [("locked", false), ("sleep", true), ("locked", true),
                              ("display", true), ("sleep", false), ("display", false)] {
        let resumed = suspension.set(reason, enabled: enabled)
        #expect(!resumed)
    }
    #expect(suspension.reasons == ["locked"])
    let resumed = suspension.set("locked", enabled: false)
    #expect(resumed)
    let resumedAgain = suspension.set("locked", enabled: false)
    #expect(!resumedAgain)
    #expect(suspension.reasons.isEmpty)
}
