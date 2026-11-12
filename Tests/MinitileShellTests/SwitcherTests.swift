import AppKit
import MinitileCore
import Testing
@testable import minitile

private let area = Rect(x: 0, y: 33, width: 1512, height: 945)

/// Lets expectations name a selected window by its ID alone.
extension SwitcherTarget: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: WindowID) { self = .window(value) }
}

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

private func open(_ state: SavedState, apps: [SwitcherApp] = [], forward: Bool = true, active: DisplayID? = nil) -> SwitcherSelection? {
    SwitcherSelection(state: state, config: .default, apps: apps, forward: forward, active: active)
}

/// Running apps named after their pids. A window's pid is its ID, so app 3 owns window 3.
private func apps(_ pids: Int32...) -> [SwitcherApp] { pids.map { SwitcherApp(pid: $0, name: "App \($0)") } }

@Test func switcherRingRunsInGridOrderFromTheFocusedWindow() throws {
    let state = model([[[1, 2, 3, 4], [5, 6]]], focus: 1, recent: [1, 5, 2])
    var selection = try #require(open(state))
    #expect(selection.order == [1, 2, 3, 4, 5, 6])
    #expect(selection.selected == 2)
    #expect(open(state, forward: false)?.selected == 6)
    var visited: [SwitcherTarget] = []
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
    var path: [SwitcherTarget] = []
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
    let tray = try #require(selection.selected.window)
    #expect([2, 3].contains(tray))
    selection.move(tray == 2 ? .right : .left)
    #expect(selection.selected == .window(tray == 2 ? 3 : 2))
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
private func arrow(_ id: WindowID, _ direction: SwitcherDirection, in state: SavedState) -> (SwitcherTarget, DisplayID)? {
    guard var selection = selecting(id, in: state), selection.selected == .window(id) else { return nil }
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
        #expect(landed?.0 == .window(window) && landed?.1 == display, "\(id) \(direction)", sourceLocation: sourceLocation)
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

@Test func appsWithoutAWindowInTheRingFollowTheWindows() throws {
    // App 2's only window is minimized and app 4's is hidden; apps 8 and 9 have none; app 1 owns a window in the ring.
    let state = model([[[1, 2, 3]], [[4]]], minimized: [2], appHidden: [4], focus: 3)
    var selection = try #require(open(state, apps: apps(9, 1, 2, 4, 8)))
    #expect(selection.order == [1, 3, .app(9), .app(2), .app(4), .app(8)])
    #expect(selection.apps.map(\.pid) == [9, 2, 4, 8])
    // Opening wraps around the windows alone, either way.
    #expect(selection.selected == 1)
    #expect(open(state, apps: apps(9, 8), forward: false)?.selected == 1)
    var unfocused = state
    unfocused.focus = nil
    #expect(open(unfocused, apps: apps(9, 8))?.selected == 1)
    #expect(open(unfocused, apps: apps(9, 8), forward: false)?.selected == 3)
    // Tab walks on from the last window through the apps and back to the first window.
    var visited: [SwitcherTarget] = []
    for _ in 0..<6 { selection.step(forward: true); visited.append(selection.selected) }
    #expect(visited == [3, .app(9), .app(2), .app(4), .app(8), 1])
    selection.step(forward: false)
    #expect(selection.selected == .app(8))
}

@Test func theViewStaysWhereTheSelectionWasWhileAnAppIsSelected() throws {
    let state = plus(["centre": [[[10]], [[11]]], "above": [[[20]]]], focus: 10)
    var selection = try #require(open(state, apps: apps(7)))
    #expect(selection.order == [20, 10, 11, .app(7)])
    #expect(selection.selected == 11 && selection.place == .init(display: "centre", cell: GridCell(workspace: 1, page: 0)))
    selection.step(forward: true)
    #expect(selection.selected == .app(7) && selection.display == "centre")
    #expect(selection.place.cell == GridCell(workspace: 1, page: 0) && selection.entry == nil)
    selection.step(forward: true)
    #expect(selection.selected == 20 && selection.display == "above")
    selection.step(forward: false)
    #expect(selection.selected == .app(7) && selection.display == "above")
}

@Test func appsAloneOpenOnTheActiveDisplay() throws {
    let state = plus(["centre": [[[]]], "above": [[[]]]])
    #expect(open(state) == nil)
    #expect(!SwitcherSelection.offers(state: state, config: .default))
    #expect(SwitcherSelection.offers(state: state, config: .default) { apps(7) })
    let selection = try #require(open(state, apps: apps(7, 8), active: "centre"))
    #expect(selection.order == [.app(7), .app(8)])
    #expect(selection.selected == .app(7) && selection.display == "centre")
    #expect(selection.place.cell == GridCell(workspace: 0, page: 0))
    #expect(open(state, apps: apps(7, 8), forward: false, active: "centre")?.selected == .app(8))
    // Without a known active display the first one in arrangement order is on view.
    #expect(open(state, apps: apps(7))?.display == "above")
    // Apps need a managed display to be shown on, and are asked for only when no window is on offer.
    let unmanaged = plus(["centre": [[[]]]], unmanaged: ["centre"])
    #expect(!SwitcherSelection.offers(state: unmanaged, config: .default) { apps(7) })
    #expect(open(unmanaged, apps: apps(7)) == nil)
    var asked = false
    #expect(SwitcherSelection.offers(state: model([[[1]]]), config: .default) { asked = true; return [] })
    #expect(!asked)
}

@Test func arrowsMoveBetweenTheGridAndTheAppsRow() throws {
    // W1: [1 | 2], W2: [3] on the first of two pages, and three apps in the row under them.
    let state = model([[[1, 2], []], [[3]]], focus: 3)
    var selection = try #require(open(state, apps: apps(7, 8, 9)))
    #expect(selection.selected == 1)
    var path: [SwitcherTarget] = []
    for direction: SwitcherDirection in [.down, .down, .down, .left, .right, .right, .right, .up, .up, .right, .down, .down] {
        selection.move(direction)
        path.append(selection.selected)
    }
    // Down from 1 reaches 3 before the row, then the app nearest 3, on the left, and stops there. Left and Right stay
    // in the row and stop at its ends, with no other display to cross to. Up returns to the nearest window, 3, and on
    // to 1. Down from 2 takes 3, the only window in the half-plane below, before the row.
    #expect(path == [3, .app(7), .app(7), .app(7), .app(8), .app(9), .app(9), 3, 1, 2, 3, .app(7)])
    // Right from a window does not drop into the row, though the row reaches further right.
    let wide = model([[[1]]], focus: 1)
    var single = try #require(open(wide, apps: apps(5, 6, 7, 8, 9)))
    single.move(.right)
    #expect(single.selected == 1)
    single.move(.down)
    #expect(single.selected == .app(7))
}

@Test func arrowsCrossDisplaysPastTheAppsRow() throws {
    let state = plus(["centre": [[[10]]], "below": [[[30]]], "left": [[[40]]]], focus: 30)
    var selection = try #require(open(state, apps: apps(7, 8)))
    #expect(selection.selected == 40)
    selection.step(forward: true)
    #expect(selection.selected == 10)
    // Down stops at the row before it crosses to the display below: at the first of the two apps, which tie.
    selection.move(.down)
    #expect(selection.selected == .app(7) && selection.display == "centre")
    selection.move(.right)
    #expect(selection.selected == .app(8) && selection.display == "centre")
    selection.move(.left)
    #expect(selection.selected == .app(7))
    // Left from the row's end crosses like Left from a window.
    selection.move(.left)
    #expect(selection.selected == 40 && selection.display == "left")
    selection.move(.right)
    #expect(selection.selected == 10 && selection.display == "centre")
    selection.move(.down)
    selection.move(.down)
    #expect(selection.selected == 30 && selection.display == "below")
    // Up from the display below enters at the window, not the row.
    selection.move(.up)
    #expect(selection.selected == 10 && selection.display == "centre")
}

@Test func theAppsRowFollowsAppsAndWindowsComingAndGoing() throws {
    let state = model([[[1, 2]]], focus: 1)
    var selection = try #require(open(state, apps: apps(1, 2, 7, 8, 9)))
    #expect(selection.order == [1, 2, .app(7), .app(8), .app(9)])
    selection.step(forward: true)
    selection.step(forward: true)
    #expect(selection.selected == .app(8))
    // App 8 quits and app 6 starts: 9 follows 8 in the order, and 6 joins at the end.
    var kept = selection.update(state: state, config: .default, apps: apps(6, 1, 2, 7, 9))
    #expect(kept && selection.order == [1, 2, .app(7), .app(9), .app(6)])
    #expect(selection.selected == .app(9) && selection.apps.map(\.pid) == [7, 9, 6])
    // Window 2 closes, leaving its app without one, and app 9 opens window 9: windows stay ahead of the apps, and the
    // selection moves on from the app that left the row.
    kept = selection.update(state: model([[[1, 9]]], focus: 1), config: .default, apps: apps(6, 1, 2, 7, 9))
    #expect(kept && selection.order == [1, 9, .app(7), .app(6), .app(2)])
    #expect(selection.selected == .app(6))
    // The app of a selected window quits: its windows go, and the next entry is selected.
    selection.step(forward: true)
    selection.step(forward: true)
    selection.step(forward: true)
    #expect(selection.selected == 9)
    kept = selection.update(state: model([[[1]]], focus: 1), config: .default, apps: apps(6, 1, 2, 7))
    #expect(kept && selection.selected == .app(7))
    // With every window gone the apps keep the switcher open on the same display; with nothing left it closes.
    kept = selection.update(state: model([[[]]]), config: .default, apps: apps(6, 7))
    #expect(kept && selection.order == [.app(7), .app(6)] && selection.display == "d")
    kept = selection.update(state: model([[[]]]), config: .default)
    #expect(!kept)
}

@Test func headerSaysWhyASelectedAppHasNoWindowToShow() throws {
    let state = model([[[1, 2, 3, 4]]], minimized: [2], appHidden: [4], focus: 3)
    var selection = try #require(open(state, apps: apps(2, 4, 8)))
    var content = SwitcherContent(selection: selection, state: state)
    #expect(content.selected == 1 && content.labeled == GridCell(workspace: 0, page: 0))
    #expect(content.apps.map(\.pid) == [2, 4, 8])
    #expect(content.pids == [1, 2, 3, 4, 8])
    var seen: [[String]] = []
    selection.step(forward: true)
    #expect(selection.selected == 3)
    for _ in 0..<3 {
        selection.step(forward: true)
        content = SwitcherContent(selection: selection, state: state)
        seen.append([content.app, content.title, content.position])
        #expect(content.labeled == nil && content.cell == GridCell(workspace: 0, page: 0))
    }
    #expect(seen == [["App 2", "Minimized", ""], ["App 4", "Hidden", ""], ["App 8", "No window in the grid", ""]])
}

@Test func appsRowSitsCenteredUnderTheGridAndShrinksToFit() {
    let laptop = Rect(x: 0, y: 0, width: 1512, height: 945)
    let bare = GridIndicatorGeometry(area: laptop, rows: 2, columns: 3, cropped: false, metrics: .switcher)
    let geometry = GridIndicatorGeometry(area: laptop, rows: 2, columns: 3, cropped: false, shelf: 4, metrics: .switcher)
    #expect(bare.shelfRects.isEmpty && bare.shelfPlate == nil)
    #expect(geometry.metrics == .switcher)
    // The row adds a cell's spacing and its plate, 40 pt icons with 6 pt around them, under the grid.
    #expect(geometry.size == CGSize(width: bare.size.width, height: bare.size.height + 24 + 52))
    let rects = geometry.shelfRects
    #expect(rects.count == 4 && rects.allSatisfy { $0.size == CGSize(width: 40, height: 40) })
    #expect(zip(rects, rects.dropFirst()).allSatisfy { $1.minX - $0.maxX == 8 })
    let plate = geometry.shelfPlate ?? .zero
    #expect(abs(plate.midX - geometry.inner.width / 2) <= 0.5)
    #expect(plate.minY == geometry.cellRect(row: 1, column: 0).maxY + 24 && plate.maxY == geometry.inner.height - geometry.margin)
    // The cropped note keeps its place under the grid, and the row follows it.
    let cropped = GridIndicatorGeometry(area: laptop, rows: 2, columns: 3, cropped: true, shelf: 4, metrics: .switcher)
    #expect(cropped.footerRect.minY == cropped.cellRect(row: 1, column: 0).maxY + 24)
    #expect(cropped.shelfPlate?.minY == cropped.footerRect.maxY + 24)
    // Many apps shrink their icons instead of widening the panel.
    let crowded = GridIndicatorGeometry(area: laptop, rows: 1, columns: 1, cropped: false, shelf: 30, metrics: .switcher)
    let small = crowded.shelfRects
    #expect(crowded.size.width == 600 && small.count == 30)
    #expect(small[0].width < 40 && small[0].width >= 8 && (crowded.shelfPlate?.minX ?? 0) >= crowded.margin)
    #expect((crowded.shelfPlate?.maxX ?? .infinity) <= crowded.inner.width - crowded.margin)
    // Other panels have no row, whatever they are asked for.
    #expect(GridIndicatorGeometry(area: laptop, rows: 2, columns: 3, cropped: false, shelf: 4, metrics: .indicator).shelf == 0)
    // A full grid with a row still fits the laptop, scaled down a little further.
    let full = GridIndicatorGeometry(area: laptop, rows: 4, columns: 5, cropped: true, shelf: 6, metrics: .switcher)
    #expect(full.size.width <= laptop.width - 32 && full.size.height <= laptop.height - 32)
    #expect(full.metrics.scale < GridIndicatorGeometry(area: laptop, rows: 4, columns: 5, cropped: true, metrics: .switcher).metrics.scale)
    #expect(abs(full.metrics.scale - 1.8) < 0.01)
}

@Test @MainActor func switcherDrawsTheAppsRowAndHighlightsTheSelectedApp() throws {
    let state = model([[[1, 2], [3]], [[4]]], focus: 4)
    var selection = try #require(open(state, apps: apps(7, 8, 9)))
    let view = SwitcherView(content: SwitcherContent(selection: selection, state: state))
    let rects = view.content.geometry.shelfRects
    #expect(rects.count == 3)
    // Each app's icon is drawn in its place in the row.
    let white = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { NSColor.white.setFill(); $0.fill(); return true }
    #expect(try !draws(view, in: rects[0].insetBy(dx: 8, dy: 8)))
    view.icons = [7: white]
    #expect(try draws(view, in: rects[0].insetBy(dx: 8, dy: 8)))
    #expect(try !draws(view, in: rects[1].insetBy(dx: 8, dy: 8)))
    // The selected app gets the lit line around its icon.
    let around = rects[1].insetBy(dx: -3, dy: -3)
    let unlit = try drawn(view, in: around).count
    while selection.selected != .app(8) { selection.step(forward: true) }
    view.content = SwitcherContent(selection: selection, state: state)
    #expect(try drawn(view, in: around).count > unlit)
    let apps = ["Utilities/Terminal", "TextEdit", "Notes", "Preview", "", "", "Mail", "Calendar", "Music"]
    view.icons = Dictionary(uniqueKeysWithValues: apps.enumerated().filter { !$1.isEmpty }.map {
        (Int32($0 + 1), NSWorkspace.shared.icon(forFile: "/System/Applications/\($1).app"))
    })
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try saveRender(bitmap, name: "switcher-apps-row")
    view.content.apps = []
    #expect(view.content.geometry.shelfRects.isEmpty)
}
