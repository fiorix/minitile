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
    command(&e, "window nudge left")
    command(&e, "window nudge right")
    command(&e, "window move up")
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
    command(&e, "page variant")
    command(&e, "window resize 2 0.2")
    let page = e.page(e.currentLocation(display: 0)!)
    #expect(abs(page.r2 - 2.0 / 3) < 0.00001)
    #expect(abs(page.r2 - page.r1 - 0.2) < 0.00001)
    command(&e, "page ratio 0.8")
    #expect(abs(e.page(e.currentLocation(display: 0)!).r2 - page.r2) < 0.00001)
}

@Test func singleSliceEdgeClampsWithoutMovingOtherCut() {
    var e = engine(3, config: Config(gaps: 0, padding: 0))
    command(&e, "page variant")
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
