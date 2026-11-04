import MinitileCore
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

@Test func focusOnAHiddenPageRightAfterNavigationIsAnEcho() {
    var shown = PageState(id: 1)
    shown.windows = [10]
    var hidden = PageState(id: 2)
    hidden.windows = [20]
    var state = SavedState()
    state.displays = [DisplayState(info: DisplayInfo(id: "d", frame: .init(x: 0, y: 0, width: 1000, height: 800)),
                                   workspaces: [WorkspaceState(id: 5, home: "d", pages: [shown, hidden], currentPage: 1)],
                                   currentWorkspace: 5)]
    #expect(ViewChangeEcho.ignores(20, state: state, now: 1, until: 2))
    #expect(!ViewChangeEcho.ignores(20, state: state, now: 2, until: 2))
    #expect(!ViewChangeEcho.ignores(10, state: state, now: 1, until: 2))
    #expect(!ViewChangeEcho.ignores(nil, state: state, now: 1, until: 2))
    #expect(!ViewChangeEcho.ignores(99, state: state, now: 1, until: 2))
}
