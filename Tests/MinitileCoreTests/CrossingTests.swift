import Testing
@testable import MinitileCore

/// A centre display with one display of the same size on each side.
private let plusDisplays: [DisplayInfo] = [("centre", 0, 0), ("left", -1000, 0), ("right", 1000, 0), ("above", 0, -800), ("below", 0, 800)]
    .map { DisplayInfo(id: $0.0, frame: Rect(x: $0.1, y: $0.2, width: 1000, height: 800), isPrimary: $0.0 == "centre") }

private func plus(_ windows: [(WindowID, DisplayID)], displays: [DisplayInfo] = plusDisplays, focus: WindowID? = nil) -> Engine {
    var e = Engine()
    _ = e.handle(.started(saved: nil, windows: windows.map { window($0.0, display: $0.1) }, displays: displays, focus: focus))
    return e
}

private func grid(_ engine: Engine, _ id: DisplayID) -> [[[WindowID]]] {
    grid(engine, display: engine.savedState().displays.firstIndex { $0.info.id == id }!)
}

/// The displays of the output's `page_shown` events, in order.
private func shown(_ out: Output) -> [String] {
    out.events.compactMap { event in
        guard event.type == "page_shown", case .object(let data) = event.data, case .string(let id) = data["display"] else { return nil }
        return id
    }
}

/// Display 0's neighbour among displays with these frames; `unmanaged` are indices.
private func neighbour(_ frames: [Rect], unmanaged: Set<Int> = [], dx: Int, dy: Int) -> Int? {
    var e = Engine()
    let infos = frames.enumerated().map { index, frame in
        DisplayInfo(id: "d\(index)", frame: frame, isPrimary: index == 0, unmanagedReason: unmanaged.contains(index) ? "Unmanaged" : nil)
    }
    _ = e.handle(.started(saved: nil, windows: [], displays: infos, focus: nil))
    return e.neighbour(of: 0, dx: dx, dy: dy)
}

private let home = Rect(x: 0, y: 0, width: 1000, height: 800)

@Test func neighbourSharesTheEdgeOnThatSide() {
    let beside = Rect(x: 1000, y: 0, width: 1200, height: 900)
    #expect(neighbour([home, beside], dx: 1, dy: 0) == 1)
    #expect(neighbour([home, beside], dx: -1, dy: 0) == nil)
    #expect(neighbour([home, beside], dx: 0, dy: -1) == nil)
    #expect(neighbour([home, beside], dx: 0, dy: 1) == nil)
    #expect(neighbour([home, Rect(x: -1440, y: 0, width: 1440, height: 900)], dx: -1, dy: 0) == 1)
    let above = Rect(x: 200, y: -600, width: 800, height: 600)
    #expect(neighbour([home, above], dx: 0, dy: -1) == 1)
    #expect(neighbour([home, above], dx: 0, dy: 1) == nil)
    #expect(neighbour([home, Rect(x: 0, y: 800, width: 1000, height: 800)], dx: 0, dy: 1) == 1)
}

@Test func neighbourNeedsAnOverlapOfPositiveLength() {
    #expect(neighbour([home, Rect(x: 1000, y: 700, width: 1000, height: 800)], dx: 1, dy: 0) == 1)
    #expect(neighbour([home, Rect(x: -300, y: 799, width: 400, height: 300)], dx: 0, dy: 1) == 1)
    let corner = Rect(x: 1000, y: 800, width: 1000, height: 800)
    #expect(neighbour([home, corner], dx: 1, dy: 0) == nil)
    #expect(neighbour([home, corner], dx: 0, dy: 1) == nil)
    #expect(neighbour([home, Rect(x: 1000, y: -800, width: 1000, height: 800)], dx: 1, dy: 0) == nil)
}

@Test(arguments: [(999.0, true), (1001.0, true), (998.0, false), (1002.0, false)])
func neighbourEdgeMayBeOffByAPoint(_ x: Double, _ found: Bool) {
    #expect((neighbour([home, Rect(x: x, y: 0, width: 1000, height: 800)], dx: 1, dy: 0) == 1) == found)
}

@Test func longestOverlapWinsThenNearestCentre() {
    let home = Rect(x: 0, y: 0, width: 1000, height: 1000)
    let short = Rect(x: 1000, y: 0, width: 800, height: 300)
    let long = Rect(x: 1000, y: 300, width: 800, height: 700)
    #expect(neighbour([home, short, long], dx: 1, dy: 0) == 2)
    #expect(neighbour([home, long, short], dx: 1, dy: 0) == 1)
    // Both overlap by 500 pt; the first one's centre is nearer.
    let near = Rect(x: 1000, y: -500, width: 800, height: 1000)
    let far = Rect(x: 1000, y: 500, width: 800, height: 2000)
    #expect(neighbour([home, far, near], dx: 1, dy: 0) == 2)
    #expect(neighbour([home, near, far], dx: 1, dy: 0) == 1)
}

@Test func unmanagedDisplaysAreNeverNeighbours() {
    let home = Rect(x: 0, y: 0, width: 1000, height: 1000)
    let short = Rect(x: 1000, y: 0, width: 800, height: 300)
    let long = Rect(x: 1000, y: 300, width: 800, height: 700)
    #expect(neighbour([home, short, long], unmanaged: [2], dx: 1, dy: 0) == 1)
    #expect(neighbour([home, long], unmanaged: [1], dx: 1, dy: 0) == nil)
    #expect(neighbour([home, long], unmanaged: [0], dx: 1, dy: 0) == nil)
}

@Test func ctrlLeftAndCtrlUpPastTheGridFocusTheDisplayOnThatSide() {
    var e = plus([(1, "centre"), (2, "left"), (3, "above")], focus: 1)
    let left = command(&e, "page prev")
    #expect(e.commandDisplay == "left")
    #expect(e.savedState().activeDisplay == "left")
    #expect(e.savedState().focus == 2)
    #expect(left.actions == [.focus(2)])
    #expect(shown(left).isEmpty)
    #expect(left.scene.displays["centre"]?.visible == [1])
    #expect(left.scene.displays["left"]?.visible == [2])
    command(&e, "window focus 1")
    let up = command(&e, "workspace prev")
    #expect(e.commandDisplay == "above")
    #expect(e.savedState().focus == 3)
    #expect(up.actions == [.focus(3)])
    #expect(shown(up).isEmpty)
    #expect(grid(e, "centre") == [[[1]]])
}

@Test func ctrlRightPastAnEmptyLastPageCrossesAndTheEmptyPageGoes() {
    var e = plus([(1, "centre"), (2, "right")], focus: 1)
    command(&e, "page next")
    #expect(grid(e, "centre") == [[[1], []]])
    let out = command(&e, "page next")
    #expect(e.commandDisplay == "right")
    #expect(e.savedState().focus == 2)
    #expect(out.actions == [.focus(2)])
    // The page before the empty one comes back.
    #expect(grid(e, "centre") == [[[1]]])
    #expect(out.scene.displays["centre"]?.visible == [1])
    #expect(shown(out) == ["centre"])
    #expect(out.events.first { $0.type == "page_shown" }?.data == .object(["display": .string("centre"), "workspace": .number(1), "page": .number(1)]))
}

@Test func ctrlDownPastAnEmptyLastWorkspaceCrossesAndReturnsToThePageLastViewedAbove() {
    var e = plus([(1, "centre"), (2, "centre"), (3, "centre"), (4, "centre"), (5, "centre"), (6, "below")], focus: 1)
    command(&e, "page next")
    command(&e, "workspace next")
    #expect(grid(e, "centre") == [[[1, 2, 3, 4], [5]], [[]]])
    let out = command(&e, "workspace next")
    #expect(e.commandDisplay == "below")
    #expect(e.savedState().focus == 6)
    #expect(grid(e, "centre") == [[[1, 2, 3, 4], [5]]])
    #expect(out.scene.displays["centre"]?.visible == [5])
    #expect(shown(out) == ["centre"])
}

@Test func navigationDoesNothingPastTheGridWithoutADisplayThere() {
    let displays = plusDisplays.filter { ["centre", "right"].contains($0.id) }
    var e = plus([(1, "centre"), (2, "right")], displays: displays, focus: 1)
    let before = e.savedState()
    for text in ["page prev", "workspace prev"] {
        let out = command(&e, text)
        #expect(out.events.isEmpty && out.actions.isEmpty)
        #expect(e.savedState() == before)
    }
    command(&e, "workspace next")
    let empty = e.savedState()
    command(&e, "workspace next")
    #expect(e.savedState() == empty)
}

@Test func navigationThatNamesADisplayNeverCrosses() {
    var e = plus([(1, "centre"), (2, "left"), (3, "right"), (4, "above"), (5, "below")], focus: 1)
    var before = e.savedState()
    command(&e, "page prev display centre")
    command(&e, "workspace prev display centre")
    #expect(e.savedState() == before)
    command(&e, "page next display centre")
    command(&e, "workspace next display centre")
    before = e.savedState()
    #expect(grid(e, "centre") == [[[1]], [[]]])
    command(&e, "page next display centre")
    command(&e, "workspace next display centre")
    command(&e, "workspace new")
    #expect(e.savedState() == before)
}

@Test func crossingFocusesTheLastFocusedWindowOnTheShownPageElseTheFirst() {
    var e = plus([(1, "centre"), (2, "left"), (3, "left")], focus: 1)
    command(&e, "page prev")
    #expect(e.savedState().focus == 2)
    command(&e, "window focus 3")
    command(&e, "window focus 1")
    command(&e, "page prev")
    #expect(e.savedState().focus == 3)
}

@Test func crossingToAnEmptyPageFocusesNothingAndAnOnlyEmptyPageStays() {
    var e = plus([(1, "centre")], focus: 1)
    let up = command(&e, "workspace prev")
    #expect(e.commandDisplay == "above")
    #expect(e.savedState().focus == nil)
    #expect(up.actions.isEmpty)
    #expect(up.events.map(\.type) == ["focus"])
    #expect(up.events.first?.data == .null)
    // Above's only page is empty and its last workspace, so Ctrl+Down crosses back, and above keeps its page.
    let down = command(&e, "workspace next")
    #expect(e.commandDisplay == "centre")
    #expect(e.savedState().focus == 1)
    #expect(down.actions == [.focus(1)])
    #expect(grid(e, "above") == [[[]]])
    #expect(shown(down).isEmpty)
}

@Test func anEmptyFirstPageGivesWayToThePageAfterIt() {
    var e = plus([(1, "centre"), (2, "centre"), (3, "left")], focus: 2)
    command(&e, "window nudge right")
    command(&e, "window focus 1")
    _ = e.handle(.windowGone(1))
    #expect(grid(e, "centre") == [[[], [2]]])
    let out = command(&e, "page prev")
    #expect(e.savedState().focus == 3)
    #expect(grid(e, "centre") == [[[2]]])
    #expect(out.scene.displays["centre"]?.visible == [2])
    #expect(shown(out) == ["centre"])
}

@Test func anEmptyFirstWorkspaceGivesWayToTheWorkspaceBelow() {
    var e = plus([(1, "centre"), (2, "centre"), (3, "centre"), (4, "above")], focus: 1)
    command(&e, "window move 2 workspace next")
    command(&e, "window move 3 workspace next")
    command(&e, "window nudge 3 right")
    command(&e, "window focus 1")
    _ = e.handle(.windowGone(1))
    #expect(grid(e, "centre") == [[[]], [[2], [3]]])
    let out = command(&e, "workspace prev")
    #expect(e.savedState().focus == 4)
    // The workspace below shows the page last viewed there.
    #expect(grid(e, "centre") == [[[2], [3]]])
    #expect(out.scene.displays["centre"]?.visible == [3])
    #expect(out.events.first { $0.type == "page_shown" }?.data == .object(["display": .string("centre"), "workspace": .number(1), "page": .number(2)]))
}

@Test func aLoneWindowNudgedPastTheGridMovesToTheDisplayOnThatSide() {
    var e = plus([(1, "centre"), (2, "centre"), (3, "left")], focus: 1)
    // 1 shares its page, so the first nudge gives it its own page.
    command(&e, "window nudge left")
    #expect(grid(e, "centre") == [[[1], [2]]])
    #expect(grid(e, "left") == [[[3]]])
    let out = command(&e, "window nudge left")
    #expect(grid(e, "centre") == [[[2]]])
    #expect(grid(e, "left") == [[[3, 1]]])
    #expect(e.savedState().windows[1]?.display == "left")
    #expect(e.savedState().focus == 1)
    #expect(e.commandDisplay == "left")
    #expect(out.actions == [.focus(1)])
    #expect(out.events.contains { $0.type == "window_moved" && $0.data == .number(1) })
    #expect(shown(out) == ["centre"])
    #expect(out.scene.displays["centre"]?.visible == [2])
    #expect(out.scene.displays["left"]?.visible == [3, 1])
    // `window move right` is a nudge too: from its own last page on left, 1 goes back to centre, left of which it is.
    command(&e, "window nudge right")
    #expect(grid(e, "left") == [[[3], [1]]])
    let back = command(&e, "window move right")
    #expect(grid(e, "left") == [[[3]]])
    #expect(grid(e, "centre") == [[[2, 1]]])
    #expect(shown(back) == ["left"])
    #expect(e.commandDisplay == "centre")
}

@Test func aDraggedWindowNeverCrosses() {
    var e = plus([(1, "centre"), (2, "left")], focus: 1)
    e.dragging = 1
    command(&e, "window nudge 1 left")
    command(&e, "window move 1 workspace prev")
    #expect(grid(e, "centre") == [[[1]]])
    #expect(grid(e, "left") == [[[2]]])
    e.dragging = nil
    command(&e, "window nudge 1 left")
    #expect(grid(e, "left") == [[[2, 1]]])
}

@Test func aCarryUpFromTheFirstWorkspaceMovesTheWindowToTheDisplayAbove() {
    var e = plus([(1, "centre"), (2, "centre"), (3, "above")], focus: 1)
    let out = command(&e, "window move workspace prev")
    #expect(grid(e, "centre") == [[[2]]])
    #expect(grid(e, "above") == [[[3, 1]]])
    #expect(e.commandDisplay == "above")
    #expect(out.actions == [.focus(1)])
    #expect(shown(out).isEmpty)
    // Nothing lies above the display above.
    let before = e.savedState()
    let none = command(&e, "window move up")
    #expect(e.savedState() == before)
    #expect(none.events.isEmpty && none.actions.isEmpty)
}

@Test func aCarryDownCrossesOnlyFromALastWorkspaceTheWindowIsAloneIn() {
    var e = plus([(1, "centre"), (2, "centre"), (3, "centre"), (4, "below")], focus: 1)
    command(&e, "window move 2 workspace next")
    command(&e, "window move 3 workspace next")
    command(&e, "window nudge 3 right")
    #expect(grid(e, "centre") == [[[1]], [[2], [3]]])
    // 3 shares the last workspace with 2, so it gets a workspace of its own.
    command(&e, "window move 3 down")
    #expect(grid(e, "centre") == [[[1]], [[2]], [[3]]])
    #expect(grid(e, "below") == [[[4]]])
    let out = command(&e, "window move down")
    #expect(grid(e, "centre") == [[[1]], [[2]]])
    #expect(grid(e, "below") == [[[4, 3]]])
    #expect(e.commandDisplay == "below")
    #expect(e.savedState().focus == 3)
    #expect(out.scene.displays["centre"]?.visible == [2])
    #expect(shown(out) == ["centre"])
}

@Test func aWindowCarriedAcrossSpillsPastAFullShownPage() {
    var e = plus([(1, "centre"), (2, "right"), (3, "right"), (4, "right"), (5, "right"), (6, "right")], focus: 1)
    #expect(grid(e, "right") == [[[2, 3, 4, 5], [6]]])
    let out = command(&e, "window nudge right")
    #expect(grid(e, "right") == [[[2, 3, 4, 5], [6, 1]]])
    #expect(out.scene.displays["right"]?.visible == [6, 1])
    // Centre has no other page, so it keeps its empty one.
    #expect(grid(e, "centre") == [[[]]])
    #expect(shown(out) == ["right"])
    #expect(out.events.first { $0.type == "page_shown" }?.data == .object(["display": .string("right"), "workspace": .number(1), "page": .number(2)]))
    #expect(out.actions == [.focus(1)])
}

@Test func aFullShownPageOnTheOtherDisplaySpillsOntoANewLastPage() {
    var e = plus([(1, "centre"), (2, "above"), (3, "above"), (4, "above"), (5, "above")], focus: 1)
    command(&e, "window move up")
    #expect(grid(e, "above") == [[[2, 3, 4, 5], [1]]])
    #expect(e.makeScene().displays["above"]?.visible == [1])
}
