import Testing
@testable import MinitileCore

let secondDisplay = DisplayInfo(id: "secondary", frame: Rect(x: 1120, y: 80, width: 1200, height: 900))
func twoDisplays() -> Engine {
    var e = Engine()
    _ = e.handle(.started(saved: nil, windows: [window(1), window(2, display: "secondary")], displays: [testDisplay, secondDisplay], focus: 1))
    return e
}

@Test func displayMergeAndReturnPreserveHomeAndNewWindows() {
    var e = twoDisplays()
    let merged = e.handle(.displaysChanged([testDisplay]))
    #expect(grid(e) == [[[1]], [[2]]])
    #expect(merged.scene.displays["primary"]?.stashed == [2])
    #expect(merged.scene.displays["secondary"] == nil)
    command(&e, "workspace next")
    _ = e.handle(.windowAppeared(window(3)))
    #expect(e.savedState().displays[0].workspaces[1].home == "secondary")
    let returned = e.handle(.displaysChanged([testDisplay, secondDisplay]))
    #expect(grid(e) == [[[1]]])
    #expect(grid(e, display: 1) == [[[2, 3]]])
    #expect(returned.scene.displays["primary"]?.visible == [1])
    #expect(returned.scene.displays["secondary"]?.visible == [2, 3])
    #expect(e.savedState().windows[3]?.display == "secondary")
}

@Test func workspaceCreatedWhileMergedBelongsToPhysicalDisplay() {
    var e = twoDisplays()
    _ = e.handle(.displaysChanged([testDisplay]))
    command(&e, "workspace next")
    command(&e, "workspace next")
    _ = e.handle(.windowAppeared(window(3)))
    _ = e.handle(.displaysChanged([testDisplay, secondDisplay]))
    #expect(grid(e) == [[[1]], [[3]]])
    #expect(grid(e, display: 1) == [[[2]]])
    #expect(e.savedState().displays[0].workspaces.allSatisfy { $0.home == "primary" })
}

@Test func returningViewedWorkspaceSelectsWorkspaceAboveIt() {
    var e = twoDisplays()
    command(&e, "workspace next")
    _ = e.handle(.windowAppeared(window(3)))
    _ = e.handle(.displaysChanged([testDisplay]))
    command(&e, "workspace next")
    let out = e.handle(.displaysChanged([testDisplay, secondDisplay]))
    #expect(out.scene.displays["primary"]?.visible == [3])
    #expect(out.actions.last == .focus(3))
}

@Test func hiddenWindowsUseCurrentHostStashAndReturnHome() {
    var e = twoDisplays()
    command(&e, "window hide 2")
    let merged = e.handle(.displaysChanged([testDisplay]))
    #expect(merged.scene.displays["primary"]?.stashed.contains(2) == true)
    let returned = e.handle(.displaysChanged([testDisplay, secondDisplay]))
    #expect(returned.scene.displays["secondary"]?.stashed == [2])
}

@Test func unmanagedDisplayHasNoSceneAndRejectsWindows() {
    var e = Engine()
    var unmanaged = secondDisplay
    unmanaged.unmanagedReason = "Requires two desktops"
    let out = e.handle(.started(saved: nil, windows: [window(1), window(2, display: "secondary")], displays: [testDisplay, unmanaged], focus: nil))
    #expect(out.scene.displays["secondary"] == nil)
    #expect(e.savedState().windows[2] == nil)
    #expect(e.savedState().displays.count == 2)
    let before = e.savedState()
    #expect(e.handle(.command(["window", "move", "1", "display", "secondary"])).reply?.ok == false)
    #expect(e.savedState() == before)
}

@Test func disconnectedOnlyDisplayRetainsStateUntilReturn() {
    var e = engine(2)
    #expect(e.handle(.displaysChanged([])).scene.displays.isEmpty)
    #expect(e.savedState().windows.count == 2)
    let out = e.handle(.displaysChanged([testDisplay]))
    #expect(out.scene.displays["primary"]?.visible == [1, 2])
}

@Test func explicitDisplayMoveChangesWorkspaceOwnership() {
    var e = twoDisplays()
    let out = command(&e, "window move 1 display secondary")
    #expect(out.scene.displays["secondary"]?.visible == [2, 1])
    #expect(e.savedState().windows[1]?.display == "secondary")
    #expect(out.actions.last == .focus(1))
}

@Test func commandDisplayFollowsFocusThenActiveDisplay() {
    var e = Engine()
    _ = e.handle(.started(saved: nil, windows: [window(1), window(2, display: "secondary")], displays: [testDisplay, secondDisplay], focus: nil))
    #expect(e.commandDisplay == "primary")
    _ = e.handle(.focusChanged(2))
    #expect(e.commandDisplay == "secondary")
    _ = e.handle(.focusChanged(nil))
    #expect(e.commandDisplay == "secondary")
    _ = e.handle(.focusChanged(1))
    #expect(e.commandDisplay == "primary")
}

@Test func navigationCanAddressADisplayOtherThanTheCommandDisplay() {
    var e = twoDisplays()
    #expect(e.commandDisplay == "primary")
    command(&e, "page next display secondary")
    #expect(grid(e) == [[[1]]])
    #expect(grid(e, display: 1) == [[[2], []]])
    #expect(e.savedState().activeDisplay == "secondary")
    let back = command(&e, "page prev display secondary")
    #expect(back.actions == [.focus(2)])
    #expect(e.savedState().focus == 2)
    command(&e, "workspace next display secondary")
    #expect(grid(e, display: 1) == [[[2]], [[]]])
    #expect(grid(e) == [[[1]]])
    // Nothing above the primary's first workspace: the view stays put on both displays.
    let before = e.savedState()
    command(&e, "workspace prev display primary")
    #expect(e.savedState() == before)
    command(&e, "workspace prev display secondary")
    #expect(grid(e, display: 1) == [[[2]]])
    command(&e, "page next display primary")
    #expect(e.savedState().activeDisplay == "primary")
    #expect(grid(e) == [[[1], []]])
}

@Test(arguments: ["page next display nowhere", "workspace prev display nowhere", "page next display secondary", "workspace next display secondary",
                  "page next display", "page next screen primary", "workspace prev display primary extra", "workspace new display primary"])
func addressedNavigationRejectsUnknownAndUnmanagedDisplays(_ text: String) {
    var e = Engine()
    var unmanaged = secondDisplay
    unmanaged.unmanagedReason = "Create two desktops in Mission Control"
    _ = e.handle(.started(saved: nil, windows: [window(1)], displays: [testDisplay, unmanaged], focus: 1))
    let before = e.savedState()
    let out = e.handle(.command(text.split(separator: " ").map(String.init)))
    #expect(out.reply?.ok == false)
    #expect(e.savedState() == before)
}
