import AppKit
import MinitileCore
import Testing
@testable import minitile

private let area = Rect(x: 0, y: 33, width: 1512, height: 945)

/// A display whose workspaces hold pages of window IDs, with `shown` the page it shows.
private struct Screen {
    var id: DisplayID
    var frame: Rect
    var grid: [[[WindowID]]]
    var shown = GridCell(workspace: 0, page: 0)
    var unmanaged = false
}

/// Displays in the model's order, the first one primary and active. `recent` lists windows most recently focused first.
private func model(_ screens: [Screen], floating: Set<WindowID> = [], minimized: Set<WindowID> = [], appHidden: Set<WindowID> = [],
                   focus: WindowID? = nil, recent: [WindowID] = []) -> SavedState {
    var state = SavedState()
    for (d, screen) in screens.enumerated() {
        let workspaces = screen.grid.enumerated().map { w, pages in
            let states = pages.enumerated().map { p, ids in
                var page = PageState(id: UInt64(10_000 * (d + 1) + 100 * (w + 1) + p))
                page.windows = ids
                return page
            }
            return WorkspaceState(id: UInt64(100 * (d + 1) + w + 1), home: screen.id, pages: states,
                                  currentPage: states[w == screen.shown.workspace ? screen.shown.page : 0].id)
        }
        let visible = screen.id == "d" ? area : screen.frame
        state.displays.append(DisplayState(info: DisplayInfo(id: screen.id, frame: screen.frame, visibleFrame: visible, isPrimary: d == 0,
                                                             unmanagedReason: screen.unmanaged ? "No desktop pair" : nil),
                                           workspaces: workspaces, currentWorkspace: workspaces[screen.shown.workspace].id))
        for id in screen.grid.flatMap({ $0.flatMap { $0 } }) {
            let info = WindowInfo(id: id, pid: Int32(id), appName: "App \(id)", title: "Title \(id)", tileable: !floating.contains(id),
                                  minimized: minimized.contains(id), appHidden: appHidden.contains(id), display: screen.id)
            state.windows[id] = WindowState(info: info, display: screen.id, floating: floating.contains(id))
        }
    }
    for (index, id) in recent.enumerated() { state.windows[id]?.lastFocused = UInt64(recent.count - index) }
    state.focus = focus
    state.activeDisplay = screens.first?.id
    return state
}

/// A display "d" alone.
private func model(_ grid: [[[WindowID]]], floating: Set<WindowID> = [], minimized: Set<WindowID> = [], appHidden: Set<WindowID> = [],
                   focus: WindowID? = nil, recent: [WindowID] = [], shown: GridCell = GridCell(workspace: 0, page: 0)) -> SavedState {
    model([Screen(id: "d", frame: Rect(x: 0, y: 0, width: 1512, height: 982), grid: grid, shown: shown)], floating: floating,
          minimized: minimized, appHidden: appHidden, focus: focus, recent: recent)
}

private func open(_ state: SavedState, forward: Bool = true) -> SwitcherSelection? {
    SwitcherSelection(state: state, config: .default, forward: forward)
}

@Test func switcherRingRunsInGridOrderFromTheFocusedWindow() throws {
    let state = model([[[1, 2, 3, 4], [5, 6]]], focus: 1, recent: [1, 5, 2])
    var selection = try #require(open(state))
    #expect(selection.order == [1, 2, 3, 4, 5, 6])
    #expect(selection.selected == 2)
    #expect(open(state, forward: false)?.selected == 6)
    var visited: [WindowID] = []
    for _ in 0..<6 { selection.step(forward: true); visited.append(selection.selected) }
    #expect(visited == [3, 4, 5, 6, 1, 2])
    selection.step(forward: false)
    #expect(selection.selected == 1)
    selection.step(forward: false)
    #expect(selection.selected == 6)
}

@Test func switcherRingVisitsTilesInReadingOrder() throws {
    var state = model([[[1, 2, 3]], [[4]]], focus: 2)
    state.displays[0].workspaces[0].pages[0].variant = .twoByOneTall
    let selection = try #require(open(state))
    #expect(selection.order == [2, 1, 3, 4])
    #expect(selection.selected == 1)
}

@Test func switcherWithoutManagedFocusStartsAtTheEnds() throws {
    let state = model([[[1, 2, 3, 4], [5, 6]]], recent: [5, 2])
    let selection = try #require(open(state))
    #expect(selection.order == [1, 2, 3, 4, 5, 6])
    #expect(selection.selected == 1)
    #expect(open(state, forward: false)?.selected == 6)
    var elsewhere = state
    elsewhere.focus = 99
    #expect(open(elsewhere)?.selected == 1)
    let single = model([[[7]]], focus: 7, recent: [7])
    #expect(open(single)?.selected == 7)
    #expect(open(single, forward: false)?.selected == 7)
}

@Test func switcherOffersTiledAndFloatingWindowsButNotMinimizedOrHiddenOnes() throws {
    let state = model([[[1, 2, 3, 7]], [[4, 5, 8]]], floating: [7, 8], minimized: [2, 8], appHidden: [4], focus: 1, recent: [1])
    let selection = try #require(open(state))
    #expect(selection.grid.entries.map(\.window) == [1, 3, 7, 5])
    #expect(selection.order == [1, 3, 7, 5])
    #expect(selection.grid.entries.map(\.cell) == [GridCell(workspace: 0, page: 0), GridCell(workspace: 0, page: 0),
                                                   GridCell(workspace: 0, page: 0), GridCell(workspace: 1, page: 0)])
    #expect(selection.grid.pages[0][0].floaters.map(\.window) == [7])
    #expect(selection.grid.pages[0][0].slots.allSatisfy { !$0.focused })
    #expect(open(model([[[]]])) == nil)
    #expect(open(model([[[2]]], minimized: [2])) == nil)
    var unmanaged = state
    unmanaged.displays[0].info.unmanagedReason = "No desktop pair"
    #expect(open(unmanaged) == nil)
}

@Test func arrowsMoveToTheNearestWindowAcrossPagesAndWorkspacesSkippingEmptyPages() throws {
    // W1: [1 2] [] [3], with the empty page shown; W2: [4 | 5 over 6].
    let state = model([[[1, 2], [], [3]], [[4, 5, 6]]], recent: [1], shown: GridCell(workspace: 0, page: 1))
    var selection = try #require(open(state))
    #expect(selection.selected == 1)
    #expect(selection.grid.shown == GridCell(workspace: 0, page: 1))
    var path: [WindowID] = []
    for direction: SwitcherDirection in [.left, .right, .right, .right, .down, .left, .up, .up, .left, .down, .down, .down, .up] {
        selection.move(direction)
        path.append(selection.selected)
    }
    // Nothing left of 1 or right of 3; right from 2 crosses the empty page; up from the large tile 4 reaches 5 on its
    // own page before the workspace above.
    #expect(path == [1, 2, 3, 3, 5, 4, 5, 2, 1, 4, 6, 6, 5])
}

@Test func arrowsReachFloatingWindowsInTheTray() throws {
    let state = model([[[1, 2, 3]], [[4]]], floating: [2, 3], recent: [1])
    var selection = try #require(open(state))
    #expect(selection.selected == 1)
    selection.move(.up)
    #expect([2, 3].contains(selection.selected))
    let tray = selection.selected
    selection.move(tray == 2 ? .right : .left)
    #expect(selection.selected == (tray == 2 ? 3 : 2))
    selection.move(.down)
    #expect(selection.selected == 1)
    selection.move(.down)
    #expect(selection.selected == 4)
}

@Test func switcherKeepsItsOrderAndFollowsClosedWindows() throws {
    var selection = try #require(open(model([[[1, 2, 3, 4], [5, 6]]], focus: 1)))
    for _ in 0..<3 { selection.step(forward: true) }
    #expect(selection.selected == 5)
    // Window 5 closes, 7 opens, and 2 takes focus: the order holds, 7 joins at the end, and 6 follows 5 in it.
    var changed = model([[[1, 2, 3, 4], [6, 7]]], focus: 2)
    let kept = selection.update(state: changed, config: .default)
    #expect(kept)
    #expect(selection.order == [1, 2, 3, 4, 6, 7])
    #expect(selection.selected == 6)
    // The last window in the order closing wraps the selection to the first.
    selection.step(forward: true)
    #expect(selection.selected == 7)
    changed = model([[[1, 2, 3, 4], [6]]], focus: 2, recent: [2, 1])
    let wrapped = selection.update(state: changed, config: .default)
    #expect(wrapped)
    #expect(selection.selected == 1)
    var emptied = selection
    let empty = emptied.update(state: model([[[]]]), config: .default)
    #expect(!empty)
    var unmanaged = changed
    unmanaged.displays[0].info.unmanagedReason = "No desktop pair"
    let gone = selection.update(state: unmanaged, config: .default)
    #expect(!gone)
}

@Test func switcherCropsAroundTheSelectionAndNamesIt() throws {
    // Six workspaces of seven pages, one window each, numbered by cell.
    let grid = (0..<6).map { w in (0..<7).map { p in [WindowID(10 * w + p + 1)] } }
    let far = try #require(open(model(grid, focus: 55, shown: GridCell(workspace: 2, page: 3))))
    let content = SwitcherContent(selection: far, state: model(grid, recent: [56]))
    #expect(content.selected == 56)
    #expect(content.cell == GridCell(workspace: 5, page: 5))
    #expect(content.rows == 2..<6)
    #expect(content.columns == 2..<7)
    #expect(content.cropped)
    #expect(content.shown == GridCell(workspace: 2, page: 3))
    #expect(content.app == "App 56")
    #expect(content.title == "Title 56")
    #expect(content.position == "Workspace 6 / Page 6")
    #expect(content.geometry.rows == 4 && content.geometry.columns == 5 && content.geometry.cropped)
    #expect(content.pids.count == 20)
    #expect(content.pids.contains(56) && !content.pids.contains(1))
    let near = try #require(open(model(grid, focus: 11)))
    let corner = SwitcherContent(selection: near, state: model(grid))
    #expect(corner.rows == 0..<4)
    #expect(corner.columns == 0..<5)
    let small = try #require(open(model([[[1, 2]], [[3]]], floating: [2])))
    let whole = SwitcherContent(selection: small, state: model([[[1, 2]], [[3]]], floating: [2]))
    #expect(!whole.cropped)
    #expect(whole.pids == [1, 2, 3])
}

@Test func switcherOffersNothingOnADisplayWithoutVisibleWindows() {
    #expect(SwitcherSelection.offers(state: model([[[1, 2]]]), config: .default))
    #expect(!SwitcherSelection.offers(state: model([[[1]]], minimized: [1]), config: .default))
    #expect(!SwitcherSelection.offers(state: model([[[]]]), config: .default))
}

/// A centre display with one display of the same size on each side that `grids` names, listed out of arrangement order.
private func plus(_ grids: [DisplayID: [[[WindowID]]]], shown: [DisplayID: GridCell] = [:], unmanaged: Set<DisplayID> = [],
                  floating: Set<WindowID> = [], focus: WindowID? = nil) -> SavedState {
    let frames: [(DisplayID, Double, Double)] = [("centre", 0, 0), ("below", 0, 982), ("right", 1512, 0), ("above", 0, -982), ("left", -1512, 0)]
    let screens = frames.compactMap { id, x, y in
        grids[id].map { Screen(id: id, frame: Rect(x: x, y: y, width: 1512, height: 982), grid: $0,
                               shown: shown[id] ?? GridCell(workspace: 0, page: 0), unmanaged: unmanaged.contains(id)) }
    }
    return model(screens, floating: floating, focus: focus)
}

/// The selection on `id`: opened after it, then stepped back.
private func selecting(_ id: WindowID, in state: SavedState) -> SwitcherSelection? {
    var focused = state
    focused.focus = id
    var selection = open(focused)
    selection?.step(forward: false)
    return selection
}

/// Where an arrow from `id` takes the selection, and the display it lands on.
private func arrow(_ id: WindowID, _ direction: SwitcherDirection, in state: SavedState) -> (WindowID, DisplayID)? {
    guard var selection = selecting(id, in: state), selection.selected == id else { return nil }
    selection.move(direction)
    return (selection.selected, selection.display)
}

@Test func switcherRingRunsThroughTheDisplaysInArrangementOrder() throws {
    let state = plus(["centre": [[[3, 4]]], "below": [[[6]]], "right": [[[5]]], "above": [[[1]]], "left": [[[2]]]], focus: 4)
    var selection = try #require(open(state))
    // By the top edges of their frames, then their left edges, whatever the model's order.
    #expect(selection.grids.map(\.display) == ["above", "left", "centre", "right", "below"])
    #expect(selection.order == [1, 2, 3, 4, 5, 6])
    // After the focused window, the last on its display, comes the first window of the next display.
    #expect(selection.selected == 5 && selection.display == "right")
    #expect(open(state, forward: false)?.selected == 3)
    selection.step(forward: true)
    #expect(selection.selected == 6 && selection.display == "below")
    selection.step(forward: true)
    #expect(selection.selected == 1 && selection.display == "above")
    selection.step(forward: false)
    #expect(selection.selected == 6)
    var last = state
    last.focus = 6
    #expect(open(last)?.selected == 1)
    var none = state
    none.focus = nil
    #expect(open(none)?.selected == 1)
    #expect(open(none, forward: false)?.selected == 6)
    let unmanaged = plus(["centre": [[[3, 4]]], "below": [[[6]]], "right": [[[5]]], "above": [[[1]]], "left": [[[2]]]],
                         unmanaged: ["right"], focus: 4)
    let skipping = try #require(open(unmanaged))
    #expect(skipping.order == [1, 2, 3, 4, 6])
    #expect(skipping.selected == 6)
}

@Test func arrowsCrossToTheDisplayOnThatSideAtTheWindowNearestTheEdgeEntered() {
    // Each side display shows three tiles: a large left one and two stacked on the right.
    let state = plus(["centre": [[[10]], [[11]]], "above": [[[20, 21, 22]]], "below": [[[30, 31, 32]]], "left": [[[40, 41, 42]]],
                      "right": [[[50, 51, 52]]]])
    func expect(_ id: WindowID, _ direction: SwitcherDirection, _ window: WindowID, _ display: DisplayID,
                sourceLocation: SourceLocation = #_sourceLocation) {
        let landed = arrow(id, direction, in: state)
        #expect(landed?.0 == window && landed?.1 == display, "\(id) \(direction)", sourceLocation: sourceLocation)
    }
    // Up enters the display above from below, at its lowest window: the lower right tile.
    expect(10, .up, 22, "above")
    // Down stays on the centre display while a window lies below, then enters from above at the upper right tile.
    expect(10, .down, 11, "centre")
    expect(11, .down, 31, "below")
    // Left enters from the right: the right column's tiles tie, so grid order picks the upper one. The display's shown
    // page is measured, whichever page the arrow leaves.
    expect(10, .left, 41, "left")
    expect(11, .left, 41, "left")
    // Right enters from the left, at the large left tile.
    expect(10, .right, 50, "right")
    // And back, onto the centre display's shown page.
    expect(20, .down, 22, "above")
    expect(22, .down, 10, "centre")
    expect(41, .right, 10, "centre")
    expect(50, .left, 10, "centre")
    expect(31, .up, 10, "centre")
}

@Test func aCrossingWithNoWindowOnTheShownPageSearchesTheWholeGrid() {
    // Above shows an empty page, so Up picks the lowest window of its whole grid, in its second workspace. Left shows
    // an empty page too and has a window on each of two pages: Left picks the rightmost, on the second page.
    let state = plus(["centre": [[[10]]], "above": [[[60, 61], []], [[62]]], "left": [[[], [80], [81]]], "below": [[[70, 71]]],
                      "right": [[[90, 91, 92]]]],
                     shown: ["above": GridCell(workspace: 0, page: 1)], floating: [92])
    #expect(arrow(10, .up, in: state)?.0 == 62)
    #expect(arrow(10, .left, in: state)?.0 == 81)
    // Two tiles side by side tie for the highest centre entering from above; grid order picks the left one.
    #expect(arrow(10, .down, in: state)?.0 == 70)
    // A floating window counts at its tray icon, on the cell's top edge, which nothing on the page is above.
    let tray = plus(["centre": [[[10]]], "below": [[[70, 71, 72]]]], floating: [72])
    #expect(arrow(10, .down, in: tray)?.0 == 72)
}

@Test func arrowsDoNothingWhereNoManagedDisplayWithAWindowLiesOnThatSide() {
    // Nothing lies left or below; the display above has no window to offer and the one on the right is unmanaged.
    let state = plus(["centre": [[[10]]], "above": [[[]]], "right": [[[50]]]], unmanaged: ["right"])
    for direction in SwitcherDirection.allCases {
        let landed = arrow(10, direction, in: state)
        #expect(landed?.0 == 10 && landed?.1 == "centre", "\(direction)")
    }
}

@Test func switcherCrossesBetweenTheUsersLaptopAndTheScreenAboveIt() throws {
    let laptop = Screen(id: "laptop", frame: Rect(x: 0, y: 0, width: 2056, height: 1329), grid: [[[1, 2]]])
    let external = Screen(id: "external", frame: Rect(x: -908, y: -2160, width: 3840, height: 2160), grid: [[[3]], [[4]]])
    let state = model([laptop, external], focus: 2)
    let selection = try #require(open(state))
    #expect(selection.order == [3, 4, 1, 2])
    #expect(selection.selected == 3 && selection.display == "external")
    let up = arrow(1, .up, in: state)
    #expect(up?.0 == 3 && up?.1 == "external")
    #expect(arrow(3, .down, in: state)?.0 == 4)
    #expect(arrow(4, .down, in: state)?.0 == 1)
    #expect(arrow(2, .left, in: state)?.0 == 1)
    #expect(arrow(1, .left, in: state)?.0 == 1)
}

@Test func headerNamesTheSelectionsDisplayOnlyWhenSeveralAreManaged() throws {
    let names = ["centre": "Laptop", "above": "External"]
    let two = plus(["centre": [[[10]]], "above": [[[20]]]], focus: 10)
    let content = SwitcherContent(selection: try #require(open(two)), state: two, names: names)
    #expect(content.selected == 20)
    #expect(content.displayName == "External")
    #expect(content.area == Rect(x: 0, y: -982, width: 1512, height: 982))
    let back = SwitcherContent(selection: try #require(selecting(10, in: two)), state: two, names: names)
    #expect(back.displayName == "Laptop" && back.area == Rect(x: 0, y: 0, width: 1512, height: 982))
    #expect(SwitcherContent(selection: try #require(open(two)), state: two).displayName == "Display")
    // A display that is not managed does not count.
    let one = plus(["centre": [[[10, 11]]], "above": [[[20]]]], unmanaged: ["above"], focus: 10)
    #expect(SwitcherContent(selection: try #require(open(one)), state: one, names: names).displayName == nil)
    // A managed display without windows counts.
    let empty = plus(["centre": [[[10, 11]]], "above": [[[]]]], focus: 10)
    #expect(SwitcherContent(selection: try #require(open(empty)), state: empty, names: names).displayName == "Laptop")
}

@Test func switcherOffersWindowsOfAnyManagedDisplay() throws {
    // The active display, the first one, has nothing to offer, but the one above it does.
    let elsewhere = plus(["centre": [[[]]], "above": [[[20]]]])
    #expect(elsewhere.activeDisplay == "centre")
    #expect(SwitcherSelection.offers(state: elsewhere, config: .default))
    #expect(open(elsewhere)?.selected == 20)
    let unmanaged = plus(["centre": [[[]]], "above": [[[20]]]], unmanaged: ["above"])
    #expect(!SwitcherSelection.offers(state: unmanaged, config: .default))
    #expect(open(unmanaged) == nil)
}

@Test func switcherFollowsADisplayThatGoesAwayWhileItIsOpen() throws {
    let state = plus(["centre": [[[10, 11]]], "above": [[[20, 21]]]], focus: 20)
    let selection = try #require(open(state))
    #expect(selection.order == [20, 21, 10, 11])
    #expect(selection.selected == 21 && selection.display == "above")
    // The core moves a disconnected display's workspaces below the primary's: its windows stay in the order, on the
    // display that now holds them.
    var merged = selection
    let kept = merged.update(state: plus(["centre": [[[10, 11]], [[20, 21]]]]), config: .default)
    #expect(kept)
    #expect(merged.order == [20, 21, 10, 11])
    #expect(merged.selected == 21 && merged.display == "centre")
    // Windows that leave the managed displays drop out, and the next window in the order is selected.
    var unmanaged = selection
    let left = unmanaged.update(state: plus(["centre": [[[10, 11]]], "above": [[[20, 21]]]], unmanaged: ["above"]), config: .default)
    #expect(left)
    #expect(unmanaged.order == [10, 11])
    #expect(unmanaged.selected == 10 && unmanaged.display == "centre")
    #expect(unmanaged.grids.map(\.display) == ["centre"])
    var gone = selection
    let none = gone.update(state: plus(["centre": [[[]]]]), config: .default)
    #expect(!none)
}

@Test @MainActor func switcherHeaderDrawsTheDisplayNameBesideTheTitle() throws {
    let two = plus(["centre": [[[10]]], "above": [[[20]]]], focus: 10)
    let content = SwitcherContent(selection: try #require(open(two)), state: two, names: ["centre": "Laptop", "above": "External"])
    let view = SwitcherView(content: content)
    let s = content.geometry.metrics.scale, margin = content.geometry.margin
    let name = CGRect(x: view.bounds.width - margin - 80 * s, y: 30 * s, width: 80 * s, height: 10 * s)
    #expect(try draws(view, in: name))
    view.content.displayName = nil
    #expect(try !draws(view, in: name))
}
