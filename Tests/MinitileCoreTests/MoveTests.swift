import Testing
@testable import MinitileCore

@Test func nudgeMatchesDesignExample() {
    var e = engine(5)
    command(&e, "window focus 2")
    command(&e, "window nudge right")
    #expect(grid(e) == [[[1, 3, 4], [2], [5]]])
    command(&e, "window nudge right")
    #expect(grid(e) == [[[1, 3, 4], [5, 2]]])
    command(&e, "window nudge right")
    #expect(grid(e) == [[[1, 3, 4], [5], [2]]])
    #expect(e.savedState().focus == 2)
}

@Test func nudgeAtOuterEdgeAndCarryAboveFirstAreNoOps() {
    var e = engine(1)
    command(&e, "window focus 1")
    let before = e.savedState()
    for direction in ["left", "right"] {
        let out = command(&e, "window nudge \(direction)")
        #expect(out.actions.isEmpty)
        #expect(out.events.isEmpty)
        #expect(!out.stateChanged)
    }
    command(&e, "window move up")
    #expect(e.savedState() == before)
}

@Test func loneWindowNudgesLeftPastFullNeighborOntoNewFirstPage() {
    var e = engine(5)
    let out = command(&e, "window nudge 5 left")
    #expect(grid(e) == [[[5], [1, 2, 3, 4]]])
    #expect(out.scene.displays["primary"]?.visible == [5])
    #expect(out.actions == [.focus(5)])
    #expect(out.events.contains { $0.type == "window_moved" })
}

@Test(arguments: ["left", "right"])
func loneWindowScansPastFullPagesInNudgeDirection(_ direction: String) {
    var e = engine(6)
    command(&e, "window nudge 1 left")
    command(&e, "window move 5 page 2")
    #expect(grid(e) == [[[1], [2, 3, 4, 5], [6]]])
    let id: WindowID = direction == "left" ? 6 : 1
    let out = command(&e, "window nudge \(id) \(direction)")
    let expected: [[[WindowID]]] = direction == "left" ? [[[1, 6], [2, 3, 4, 5]]] : [[[2, 3, 4, 5], [6, 1]]]
    #expect(grid(e) == expected)
    #expect(e.savedState().focus == id)
    #expect(out.actions == [.focus(id)])
}

@Test(arguments: ["left", "right"])
func loneWindowAtWorkspaceEndEmitsNothing(_ direction: String) {
    var e = engine(5)
    if direction == "left" { command(&e, "window nudge 1 left") }
    let id: WindowID = direction == "left" ? 1 : 5
    command(&e, "window focus \(id)")
    let before = e.savedState()
    let out = command(&e, "window nudge \(direction)")
    #expect(out.actions.isEmpty)
    #expect(out.events.isEmpty)
    #expect(!out.stateChanged)
    #expect(e.savedState() == before)
}

@Test func nudgeLeftCreatesPageAndFullRightNeighborSpills() {
    var e = engine(8)
    command(&e, "window nudge 1 left")
    #expect(grid(e) == [[[1], [2, 3, 4], [5, 6, 7, 8]]])
    command(&e, "window nudge 1 right")
    command(&e, "window nudge 1 right")
    command(&e, "window nudge 1 right")
    #expect(grid(e) == [[[2, 3, 4], [5, 6, 7, 8], [1]]])
}

@Test func carryCreatesWorkspaceAndReturnsToRememberedPage() {
    var e = engine(5)
    let out = command(&e, "window move 1 workspace next")
    #expect(grid(e) == [[[2, 3, 4], [5]], [[1]]])
    #expect(out.actions.last == .focus(1))
    command(&e, "window focus 5")
    command(&e, "window focus 1")
    command(&e, "window move 1 workspace prev")
    #expect(grid(e) == [[[2, 3, 4], [5, 1]]])
}

@Test func explicitPageMoveSpillsAndCrossPageSwapFollowsSource() {
    var e = engine(6)
    command(&e, "window move 1 page 2")
    #expect(grid(e) == [[[2, 3, 4], [5, 6, 1]]])
    command(&e, "window swap 1 2")
    #expect(grid(e) == [[[1, 3, 4], [5, 6, 2]]])
    #expect(e.savedState().focus == 1)
    #expect(e.makeScene().displays["primary"]?.visible == [1, 3, 4])
}

@Test func dragMoveSwapsOnlyOnSamePageOtherwiseRewrites() {
    var e = engine(5)
    let frames = e.makeScene().displays["primary"]!.frames
    var moved = frames[1]!
    moved.x += 100
    _ = e.handle(.dragEnded(1, frame: moved, cursor: frames[2]!.center))
    #expect(grid(e) == [[[2, 1, 3, 4], [5]]])
    let current = e.makeScene().displays["primary"]!.frames[1]!
    let out = e.handle(.dragEnded(1, frame: current, cursor: Point(x: -1000, y: -1000)))
    #expect(out.rewrite == [1])
    #expect(grid(e) == [[[2, 1, 3, 4], [5]]])
}

@Test func edgeAndCornerDragsAdjustCutsAndBorderSnapsBack() {
    var e = engine(4, config: Config(gaps: 0, padding: 0))
    var frame = e.makeScene().displays["primary"]!.frames[1]!
    frame.width = 600
    frame.height = 480
    let resized = e.handle(.dragEnded(1, frame: frame, cursor: frame.center))
    #expect(resized.scene.displays["primary"]?.frames[1] == Rect(x: 120, y: 80, width: 600, height: 480))
    #expect(e.page(e.currentLocation(display: 0)!).r1 == 0.6)
    #expect(e.page(e.currentLocation(display: 0)!).r2 == 0.6)
    frame.x -= 30
    frame.width += 30
    let border = e.handle(.dragEnded(1, frame: frame, cursor: frame.center))
    #expect(border.rewrite.contains(1))
    #expect(e.page(e.currentLocation(display: 0)!).r1 == 0.6)
}

@Test func resizeUsesTileShareAndRespectsGapCenters() {
    var e = engine(2)
    command(&e, "window resize 1 0.6")
    #expect(abs(e.page(e.currentLocation(display: 0)!).r1 - 0.6) < 0.00001)
    command(&e, "window resize 2 0.7")
    #expect(abs(e.page(e.currentLocation(display: 0)!).r1 - 0.3) < 0.00001)
    command(&e, "page variant")
    command(&e, "window resize 1 0.6")
    #expect(abs(e.page(e.currentLocation(display: 0)!).r1 - 0.6) < 0.00001)
}

@Test func portraitDragChangesLongAxisCut() {
    var e = Engine(config: Config(gaps: 0, padding: 0))
    let display = DisplayInfo(id: "primary", frame: Rect(x: -800, y: 200, width: 800, height: 1000))
    _ = e.handle(.started(saved: nil, windows: [window(1), window(2)], displays: [display], focus: nil))
    let out = e.handle(.dragEnded(1, frame: Rect(x: -800, y: 200, width: 800, height: 650), cursor: Point(x: -400, y: 850)))
    #expect(out.scene.displays["primary"]?.frames[1]?.height == 650)
}

@Test func invalidMovePreservesState() {
    var e = engine(2)
    let before = e.savedState()
    #expect(e.handle(.command(["window", "move", "1", "page", "99"])).reply?.ok == false)
    #expect(e.savedState() == before)
}

@Test func middleSliceResizeUsesItsShareAndKeepsOtherCut() {
    var e = engine(3)
    command(&e, "window place 1 alternate 0")
    command(&e, "window resize 2 0.2")
    let page = e.page(e.currentLocation(display: 0)!)
    #expect(abs(page.r2 - 2.0 / 3) < 0.00001)
    #expect(abs(page.r2 - page.r1 - 0.2) < 0.00001)
    command(&e, "page ratio 0.8")
    #expect(abs(e.page(e.currentLocation(display: 0)!).r2 - page.r2) < 0.00001)
}

@Test func singleSliceEdgeClampsWithoutMovingOtherCut() {
    var e = engine(3, config: Config(gaps: 0, padding: 0))
    command(&e, "window place 1 alternate 0")
    var frame = e.makeScene().displays["primary"]!.frames[1]!
    frame.width = 900
    _ = e.handle(.dragEnded(1, frame: frame, cursor: frame.center))
    let page = e.page(e.currentLocation(display: 0)!)
    #expect(abs(page.r2 - 2.0 / 3) < 0.00001)
    #expect(abs(page.r1 - (2.0 / 3 - 0.2)) < 0.00001)
}

@Test func twoDimensionalResizeMapsPhysicalAxesForLowerTile() {
    var e = engine(4)
    command(&e, "window resize 3 0.6x0.7")
    let page = e.page(e.currentLocation(display: 0)!)
    #expect(abs(page.r1 - 0.6) < 0.00001)
    #expect(abs(page.r2 - 0.3) < 0.00001)
}

@Test func newPageAndWorkspaceInsertionsPlaceAtRequestedOneBasedPositions() {
    var e = engine(5)
    // [1, 2, 3, 4], [5]
    command(&e, "window move 2 page new")
    #expect(grid(e) == [[[1, 3, 4], [5], [2]]])
    command(&e, "window move 3 page new 1")
    #expect(grid(e) == [[[3], [1, 4], [5], [2]]])
    command(&e, "window move 4 page new 3")
    #expect(grid(e) == [[[3], [1], [4], [5], [2]]])
    command(&e, "window move 5 workspace new")
    #expect(grid(e) == [[[3], [1], [4], [2]], [[5]]])
    command(&e, "window move 4 workspace new 1")
    #expect(grid(e) == [[[4]], [[3], [1], [2]], [[5]]])
    command(&e, "window move 2 workspace new 2 page new 1")
    #expect(grid(e) == [[[4]], [[2]], [[3], [1]], [[5]]])
    command(&e, "window move 1 workspace 4 page 1")
    #expect(grid(e) == [[[4]], [[2]], [[3]], [[5, 1]]])
}

@Test func composedDisplayWorkspaceAndPageMovesAndRejectsInvalidBoundsAndStates() {
    var e = Engine()
    let second = DisplayInfo(id: "secondary", frame: Rect(x: 1120, y: 80, width: 1000, height: 800))
    _ = e.handle(.started(saved: nil, windows: [window(1), window(2), window(3, display: "secondary")],
                          displays: [testDisplay, second], focus: 1))
    command(&e, "window move 2 display secondary workspace 1 page new 1 stay")
    #expect(grid(e, display: 0) == [[[1]]])
    #expect(grid(e, display: 1) == [[[2], [3]]])
    let before = e.savedState()
    for bad in ["window move 1 page new 3", "window move 1 workspace new 3", "window move 1 workspace 2 page 1",
                "window move 1 display missing page 1"] {
        #expect(e.handle(.command(bad.split(separator: " ").map(String.init))).reply?.ok == false, "\(bad)")
        #expect(e.savedState() == before)
    }
    var fs = window(1)
    fs.fullscreen = true
    _ = e.handle(.windowUpdated(fs))
    #expect(e.handle(.command(["window", "move", "1", "page", "new", "stay"])).reply?.ok == false)
    var orderedOut = window(2, display: "secondary")
    orderedOut.orderedOut = true
    _ = e.handle(.windowUpdated(orderedOut))
    #expect(e.handle(.command(["window", "move", "2", "page", "new", "stay"])).reply?.ok == false)
}

@Test func loneWindowPageAndWorkspaceAdjacencyMovesAreNoOps() {
    var e = engine(5)
    command(&e, "window nudge 1 left")
    // Grid: W1 [[1], [2, 3, 4], [5]]
    let before = e.savedState()
    for noop in ["window move 1 page new 1 stay", "window move 1 page new 2 stay",
                 "window move 5 page new 3 stay", "window move 5 page new 4 stay",
                 "window move 5 page next stay", "window move 1 page prev stay"] {
        let out = command(&e, noop)
        #expect(!out.stateChanged && out.events.isEmpty && out.actions.isEmpty, "\(noop)")
        #expect(e.savedState().serial == before.serial)
    }
    command(&e, "window move 5 workspace new stay")
    // Grid: W1 [[1], [2, 3, 4]], W2 [[5]]
    let wsBefore = e.savedState()
    for noop in ["window move 5 workspace new 2 stay", "window move 5 workspace new 3 stay",
                 "window move 5 workspace next stay"] {
        let out = command(&e, noop)
        #expect(!out.stateChanged && out.events.isEmpty && out.actions.isEmpty, "\(noop)")
        #expect(e.savedState().serial == wsBefore.serial)
    }
}

@Test func insertingBeforeTheShownLoneLastPageVacatesTheEmptiedPage() {
    var e = engine(5)
    // W1: P1 [1, 2, 3, 4], P2 [5]; show P2 and focus 5.
    command(&e, "window focus 2")
    command(&e, "window focus 5")
    #expect(e.makeScene().displays["primary"]?.visible == [5])
    let out = command(&e, "window move 5 page new 1 stay")
    #expect(grid(e) == [[[5], [1, 2, 3, 4]]])
    // Vacate shows P2 (the former P1 holding 2, focused most recently among remaining windows), leaving no empty page.
    #expect(out.scene.displays["primary"]?.visible == [1, 2, 3, 4])
    #expect(e.savedState().focus == 2)
    #expect(out.actions == [.focus(2)])
}

@Test func stayMovesKeepShownPageAndFocusRulesAcrossPages() {
    var e = engine(6)
    // W1: P1 [1, 2, 3, 4], P2 [5, 6]
    command(&e, "window focus 1")
    // Stashed to stashed: P2 -> new P3.
    var out = command(&e, "window move 6 page new stay")
    #expect(grid(e) == [[[1, 2, 3, 4], [5], [6]]])
    #expect(out.scene.displays["primary"]?.visible == [1, 2, 3, 4])
    #expect(e.savedState().focus == 1 && out.actions.isEmpty)
    #expect(!out.events.contains { $0.type == "page_shown" })
    // Stashed onto shown with room: 6 joins P1 after freeing a slot.
    command(&e, "window move 4 page 2 stay")
    out = command(&e, "window move 6 page 1 stay")
    #expect(grid(e) == [[[1, 2, 3, 6], [5, 4]]])
    #expect(e.savedState().focus == 1 && out.actions.isEmpty)
    // Focused window on shown page with remaining windows moves to stashed: focus stays on P1.
    out = command(&e, "window move 1 page 2 stay")
    #expect(grid(e) == [[[2, 3, 6], [5, 4, 1]]])
    #expect(out.scene.displays["primary"]?.visible == [2, 3, 6])
    #expect(e.savedState().focus == 2 && out.actions == [.focus(2)])
    // Last window on shown page moves to stashed: vacate picks the most recently focused other window's page, not dest.
    command(&e, "window focus 5")
    command(&e, "window move 6 page new stay")
    command(&e, "window focus 6")
    // Now W1 has P1 [2, 3], P2 [5, 4, 1] (5 focused most recently after 6), P3 [6] (shown, focused).
    // Move 6 onto P1 with stay: P3 is vacated in favour of P2 (where 5 was focused last), not P1 (destination).
    out = command(&e, "window move 6 page 1 stay")
    #expect(grid(e) == [[[2, 3, 6], [5, 4, 1]]])
    #expect(out.scene.displays["primary"]?.visible == [5, 4, 1])
    #expect(e.savedState().focus == 5 && out.actions == [.focus(5)])
}

@Test func stayNeverAssignsFocusWhenNothingWasFocused() {
    var e = engine(5)
    // Unmanaged app frontmost: focus is nil while P1 [1, 2, 3, 4] is shown.
    _ = e.handle(.focusChanged(nil))
    var out = command(&e, "window move 1 page 2 stay")
    #expect(e.savedState().focus == nil && out.actions.isEmpty)
    // Moving a stashed window onto an empty shown page also keeps focus nil.
    command(&e, "page next")
    command(&e, "page next")
    #expect(grid(e) == [[[2, 3, 4], [5, 1], []]])
    _ = e.handle(.focusChanged(nil))
    out = command(&e, "window move 5 page 3 stay")
    #expect(grid(e) == [[[2, 3, 4], [1], [5]]])
    #expect(out.scene.displays["primary"]?.visible == [5])
    #expect(e.savedState().focus == nil && out.actions.isEmpty)
}

@Test func crossDisplayStayKeepsSourceFocusWhenPossibleAndFollowsWhenAlone() {
    var e = Engine()
    let second = DisplayInfo(id: "secondary", frame: Rect(x: 1120, y: 80, width: 1000, height: 800))
    _ = e.handle(.started(saved: nil, windows: [window(1), window(2), window(3, display: "secondary")],
                          displays: [testDisplay, second], focus: 1))
    // 1 moves to secondary while 2 remains on primary: focus moves to 2 and activeDisplay stays primary.
    var out = command(&e, "window move 1 display secondary stay")
    #expect(grid(e, display: 0) == [[[2]]])
    #expect(grid(e, display: 1) == [[[3, 1]]])
    #expect(e.savedState().focus == 2 && e.savedState().activeDisplay == "primary")
    #expect(out.actions == [.focus(2)])
    // Now 2 is alone on primary and moves to secondary's shown page: nothing focusable remains on primary, so focus stays
    // on 2 and activeDisplay goes with it.
    out = command(&e, "window move 2 display secondary stay")
    #expect(grid(e, display: 0) == [[[]]])
    #expect(grid(e, display: 1) == [[[3, 1, 2]]])
    #expect(e.savedState().focus == 2 && e.savedState().activeDisplay == "secondary")
    #expect(out.actions.isEmpty)
}

@Test func swapStayParsesImplicitAndExplicitTargetsAndKeepsFocusInView() {
    var e = Engine()
    let second = DisplayInfo(id: "secondary", frame: Rect(x: 1120, y: 80, width: 1000, height: 800))
    _ = e.handle(.started(saved: nil, windows: [window(1), window(2), window(3), window(4), window(5),
                                                window(6, display: "secondary")],
                          displays: [testDisplay, second], focus: 1))
    // Same-page swap with implicit focused ID and `stay` keeps focus on 1 (not parsing `2` as ID).
    var out = command(&e, "window swap 2 stay")
    #expect(grid(e, display: 0) == [[[2, 1, 3, 4], [5]]])
    #expect(e.savedState().focus == 1 && out.actions.isEmpty)
    // `swap next stay` on same page also leaves focus on 1.
    out = command(&e, "window swap next stay")
    #expect(grid(e, display: 0) == [[[2, 3, 1, 4], [5]]])
    #expect(e.savedState().focus == 1 && out.actions.isEmpty)
    // Cross-page swap when focused window 1 swaps with stashed 5: P1 stays shown and focuses a window on P1.
    out = command(&e, "window swap 5 stay")
    #expect(grid(e, display: 0) == [[[2, 3, 5, 4], [1]]])
    #expect(out.scene.displays["primary"]?.visible == [2, 3, 5, 4])
    #expect(e.savedState().focus == 2 && out.actions == [.focus(2)])
    // Explicit IDs where the second window holds focus (2 on shown P1, swapped from stashed 1).
    out = command(&e, "window swap 1 2 stay")
    #expect(grid(e, display: 0) == [[[1, 3, 5, 4], [2]]])
    #expect(e.savedState().focus == 1 && out.actions == [.focus(1)])
    // Cross-display swap with stay keeps focus on primary's shown page.
    out = command(&e, "window swap 1 6 stay")
    #expect(grid(e, display: 0) == [[[6, 3, 5, 4], [2]]])
    #expect(grid(e, display: 1) == [[[1]]])
    #expect(e.savedState().focus == 6 && e.savedState().activeDisplay == "primary")
    #expect(out.actions == [.focus(6)])
}

@Test func hiddenWindowMovedWithStayUnhidesWithoutTakingFocus() {
    var e = engine(2)
    command(&e, "window focus 1")
    command(&e, "window hide 2")
    #expect(e.savedState().windows[2]?.hidden == true)
    let out = command(&e, "window move 2 page new stay")
    #expect(e.savedState().windows[2]?.hidden == false)
    #expect(grid(e) == [[[1], [2]]])
    #expect(out.scene.displays["primary"]?.visible == [1])
    #expect(e.savedState().focus == 1 && out.actions.isEmpty)
    #expect(out.events.map(\.type) == ["window_moved"])
}
