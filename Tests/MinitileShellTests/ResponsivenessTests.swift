import Testing
@testable import minitile

@Test func inputWaitsKeepTheLatestAndLongestAndFlagSlowOnes() {
    var waits = InputWaits()
    #expect(waits.latest == 0 && waits.longest == 0)
    let quick = waits.record(40)
    #expect(!quick)
    let slow = waits.record(900)
    #expect(slow)
    let after = waits.record(12)
    #expect(!after)
    #expect(waits.latest == 12)
    #expect(waits.longest == 900)
}

@Test func inputWaitThresholdIsExclusive() {
    var waits = InputWaits()
    let atThreshold = waits.record(Slow.inputWait)
    #expect(!atThreshold)
    let above = waits.record(Slow.inputWait + 1)
    #expect(above)
}

@Test func slowLogThresholdsMatchTheDesign() {
    #expect(Slow.inputWait == 150)
    #expect(Slow.keyCommand == 100)
    #expect(Slow.reconcile == 100)
    #expect(Slow.mainThreadAXCall == 200)
    #expect(Slow.backgroundRead == 500)
}

@Test func keyDecisionRoutesNameEveryKind() {
    #expect(KeyDecision.pass.route.name == "pass")
    #expect(KeyDecision.swallow.route.name == "swallow")
    #expect(KeyDecision.command(["page", "next"]).route == ("command", ["page", "next"]))
    #expect(KeyDecision.switcher(.commit, session: 1).route == ("switcher", ["commit"]))
    #expect(KeyDecision.help(.close, session: 2).route == ("help", ["close"]))
    #expect(KeyDecision.grabReleased(3).route == ("grab_released", []))
}
