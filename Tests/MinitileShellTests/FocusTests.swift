import ApplicationServices
import MinitileCore
import Testing
@testable import minitile

@Test func focusForwardingRejectsBackgroundAndAllOwnPidEchoes() {
    var echo = FocusEchoes()
    echo.add(10, now: 0.8)
    #expect(!FocusForwarding.accepts(pid: 11, frontmost: 10, echoes: FocusEchoes(), now: 1))
    #expect(!FocusForwarding.accepts(pid: 10, frontmost: 10, echoes: echo, now: 1.99))
    #expect(FocusForwarding.accepts(pid: 10, frontmost: 10, echoes: echo, now: 2))
    #expect(FocusForwarding.accepts(pid: 11, frontmost: 11, echoes: echo, now: 1))
    #expect(!FocusForwarding.accepts(pid: 10, frontmost: nil, echoes: FocusEchoes(), now: 3))
}

@Test func unreadableFocusIsDistinctFromNoFocusedWindow() {
    #expect(FocusObservation.unknown != .known(nil))
    #expect(FocusObservation.known(42).window == 42)
}

@Test func oneFocusReadSuppliesBothTheElementAndObservation() {
    let element = AXUIElementCreateApplication(9001)
    var copies = 0, ids = 0
    let read = FocusRead.read(copy: { copies += 1; return (element, .success) }, identify: { _ in ids += 1; return 42 })
    #expect(read.element.map { CFEqual($0, element) } == true)
    #expect(read.observation == .known(42))
    #expect(copies == 1 && ids == 1)
}

@Test func focusReadsPreserveFailureAndAbsenceWithoutReadingAnID() {
    for (error, expected) in [(AXError.cannotComplete, FocusObservation.unknown), (.success, .known(nil)), (.noValue, .unknown)] {
        var copies = 0, ids = 0
        let read = FocusRead.read(copy: { copies += 1; return (nil, error) }, identify: { _ in ids += 1; return 42 })
        #expect(read.observation == expected && read.element == nil)
        #expect(copies == 1 && ids == 0)
    }
    let unidentified = FocusRead.read(copy: { (AXUIElementCreateApplication(9001), .success) }, identify: { _ in nil })
    #expect(unidentified.observation == .unknown)
    let invalid = FocusRead.read(copy: { ("invalid" as CFString, .success) }, identify: { _ in Issue.record("Not an element"); return 42 })
    #expect(invalid.observation == .unknown && invalid.element == nil)
}

@Test func reappearingWindowsShareOneFocusReadPerAppInThePass() {
    var cache = FocusReads()
    var reads: [Int32] = []
    for pid: Int32 in [7, 7, 8, 7, 8] {
        let focus = cache.read(pid) { reads.append(pid); return pid == 7 ? .unknown : .known(42) }
        #expect(focus == (pid == 7 ? .unknown : .known(42)))
    }
    #expect(reads == [7, 8])
    var nextPass = FocusReads()
    #expect(nextPass.read(7) { reads.append(7); return .known(nil) } == .known(nil))
    #expect(reads == [7, 8, 7])
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

@Test func appKeepingFocusOnAHiddenPageRefusedTheFocusedWindow() {
    // Page 2 is shown and remembers a small window (10) its app cannot make key; the app keeps its window on page 3.
    var shown = PageState(id: 2)
    shown.windows = [11, 12, 10]
    shown.lastFocus = 10
    var hidden = PageState(id: 3)
    hidden.windows = [20]
    var state = SavedState()
    state.displays = [DisplayState(info: DisplayInfo(id: "d", frame: .init(x: 0, y: 0, width: 1000, height: 800)),
                                   workspaces: [WorkspaceState(id: 5, home: "d", pages: [shown, hidden], currentPage: 2)],
                                   currentWorkspace: 5)]
    state.focus = 10
    #expect(RefusedFocus.refused(10, reported: 20, state: state))
    #expect(!RefusedFocus.refused(10, reported: 10, state: state))
    #expect(!RefusedFocus.refused(10, reported: 11, state: state))
    #expect(!RefusedFocus.refused(10, reported: nil, state: state))
    #expect(!RefusedFocus.refused(10, reported: 99, state: state))
    // Focus that moved on since, or a target no longer on the shown page, is followed as before.
    state.focus = 11
    #expect(!RefusedFocus.refused(10, reported: 20, state: state))
    state.focus = 20
    #expect(!RefusedFocus.refused(20, reported: 10, state: state))
}

@Test func lateActivationsFromEarlierOwnFocusesStayEchoes() {
    var echoes = FocusEchoes()
    echoes.add(10, now: 0)
    echoes.add(20, now: 0.1)
    var results: [Bool] = []
    for (pid, now) in [(10, 0.3), (20, 0.4), (10, 1.19), (10, 1.2)] as [(Int32, Double)] {
        results.append(echoes.activation(pid, now: now))
    }
    #expect(results == [true, true, true, false])
    #expect(echoes.isEmpty)
    echoes.add(10, now: 2)
    echoes.add(20, now: 2)
    let foreign = echoes.activation(30, now: 2.1)
    let afterForeign = echoes.activation(10, now: 2.2)
    #expect(!foreign)
    #expect(!afterForeign)
}
