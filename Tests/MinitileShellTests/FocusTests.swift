import Testing
@testable import minitile

@Test func focusForwardingRejectsBackgroundAndAllOwnPidEchoes() {
    let echo = FocusEcho(pid: 10, until: 2)
    #expect(!FocusForwarding.accepts(pid: 11, frontmost: 10, echo: nil, now: 1))
    #expect(!FocusForwarding.accepts(pid: 10, frontmost: 10, echo: echo, now: 1.99))
    #expect(FocusForwarding.accepts(pid: 10, frontmost: 10, echo: echo, now: 2))
    #expect(FocusForwarding.accepts(pid: 11, frontmost: 11, echo: echo, now: 1))
    #expect(!FocusForwarding.accepts(pid: 10, frontmost: nil, echo: nil, now: 3))
}

@Test func unreadableFocusIsDistinctFromNoFocusedWindow() {
    #expect(FocusObservation.unknown != .known(nil))
    #expect(FocusObservation.known(42).window == 42)
}

@Test func activationDropsFocusOwnedByAnotherApp() {
    #expect(ActivationFocus.clears(owner: 20, activated: 10))
    #expect(!ActivationFocus.clears(owner: 10, activated: 10))
    #expect(!ActivationFocus.clears(owner: nil, activated: 10))
}
