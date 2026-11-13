import Testing
@testable import MinitileCore

@Test func nativeTabSelectionKeepsSlotLayoutAndFocusAcrossSwitches() {
    var e = engine(3)
    command(&e, "window focus 2")
    e.state.displays[0].workspaces[0].pages[0].variant = .oneByTwoWide
    e.state.displays[0].workspaces[0].pages[0].r1 = 0.63
    let original = e.makeScene().displays["primary"]!
    let page = e.state.displays[0].workspaces[0].pages[0]
    var previous: WindowID = 2
    for selected: WindowID in [5, 2, 5, 2] {
        let out = e.handle(.windowTabSelected(previous: previous, window(selected, pid: 102, frontmost: true)))
        #expect(grid(e) == [[[1, selected, 3]]])
        #expect(out.scene.displays["primary"]?.frames[selected] == original.frames[2])
        #expect(out.scene.displays["primary"]?.frames[1] == original.frames[1])
        #expect(out.scene.displays["primary"]?.frames[3] == original.frames[3])
        #expect(out.scene.displays["primary"]?.frames[previous] == nil)
        #expect(e.state.windows[previous]?.info.orderedOut == true)
        #expect(e.state.focus == selected)
        #expect(e.state.displays[0].workspaces[0].pages[0].id == page.id)
        #expect(e.state.displays[0].workspaces[0].pages[0].variant == page.variant)
        #expect(e.state.displays[0].workspaces[0].pages[0].r1 == page.r1)
        #expect(out.actions.isEmpty)
        previous = selected
    }
}

@Test func nativeTabSelectionRemovesAnAlreadyManagedTabFromItsFormerPage() {
    var e = engine(4)
    _ = e.handle(.windowAppeared(window(5, pid: 102)))
    #expect(grid(e) == [[[1, 2, 3, 4], [5]]])
    _ = e.handle(.windowTabSelected(previous: 2, window(5, pid: 102)))
    #expect(grid(e) == [[[1, 5, 3, 4]]])
    #expect(e.state.windows[2]?.info.orderedOut == true)
}

@Test func nativeTabSelectionOnAStashedPageDoesNotChangeTheView() {
    var e = engine(5)
    command(&e, "page next")
    let out = e.handle(.windowTabSelected(previous: 2, window(6, pid: 102)))
    #expect(grid(e) == [[[1, 6, 3, 4], [5]]])
    #expect(out.scene.displays["primary"]?.visible == [5])
    #expect(out.scene.displays["primary"]?.stashed == [1, 3, 4, 6])
    #expect(e.state.focus == 5)
    #expect(out.actions.isEmpty)
}

@Test func nativeTabSelectionCarriesFloatingAndExplicitHiddenState() {
    var e = engine(2)
    command(&e, "window float 2 on")
    command(&e, "window hide 2")
    let out = e.handle(.windowTabSelected(previous: 2, window(3, pid: 102)))
    #expect(grid(e) == [[[1]]])
    #expect(e.state.windows[3]?.floatingOverride == true)
    #expect(e.state.windows[3]?.floating == true)
    #expect(e.state.windows[3]?.hidden == true)
    #expect(e.state.windows[2]?.hidden == false)
    #expect(out.scene.displays["primary"]?.stashed == [3])
    command(&e, "window show 3")
    #expect(grid(e) == [[[1, 3]]])
}

@Test func nativeTabSelectionDoesNotReplaceAnotherProcessWindow() {
    var e = engine(2)
    _ = e.handle(.windowTabSelected(previous: 2, window(3, pid: 999)))
    #expect(grid(e) == [[[1, 2, 3]]])
    #expect(e.state.windows[2]?.info.orderedOut == false)
}

@Test func nativeTabSelectionPreservesAnAdoptedNativeHalf() {
    var e = engine(1)
    let half = Rect(x: 120, y: 80, width: 500, height: 800)
    let before = e.handle(.nativeTiled(1, frame: half))
    let after = e.handle(.windowTabSelected(previous: 1, window(2, pid: 101)))
    #expect(after.scene.displays["primary"]?.frames[2] == before.scene.displays["primary"]?.frames[1])
    #expect(e.state.displays[0].workspaces[0].pages[0].nativeLayout?.windows == [2])
}

@Test func nativeTabSelectionFollowsActualFocusAfterAnUnknownWindowReport() {
    var e = engine(5)
    command(&e, "page next")
    _ = e.handle(.focusChanged(nil))
    let out = e.handle(.windowTabSelected(previous: 2, window(6, pid: 102, frontmost: true)))
    #expect(out.scene.displays["primary"]?.visible == [1, 6, 3, 4])
    #expect(e.state.focus == 6)
    #expect(out.actions.isEmpty)
}
