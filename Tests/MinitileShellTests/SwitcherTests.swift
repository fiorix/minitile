import CoreGraphics
import MinitileCore
import Testing
@testable import minitile

private let area = Rect(x: 0, y: 33, width: 1512, height: 945)

/// A display "d" whose workspaces hold pages of window IDs. `recent` lists windows most recently focused first.
private func model(_ grid: [[[WindowID]]], floating: Set<WindowID> = [], minimized: Set<WindowID> = [], appHidden: Set<WindowID> = [],
                   focus: WindowID? = nil, recent: [WindowID] = [], shown: GridCell = GridCell(workspace: 0, page: 0)) -> SavedState {
    var state = SavedState()
    let workspaces = grid.enumerated().map { w, pages in
        let states = pages.enumerated().map { p, ids in
            var page = PageState(id: UInt64(100 * (w + 1) + p))
            page.windows = ids
            return page
        }
        return WorkspaceState(id: UInt64(w + 1), home: "d", pages: states, currentPage: states[w == shown.workspace ? shown.page : 0].id)
    }
    state.displays = [DisplayState(info: DisplayInfo(id: "d", frame: Rect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: area, isPrimary: true),
                                   workspaces: workspaces, currentWorkspace: workspaces[shown.workspace].id)]
    for id in grid.flatMap({ $0.flatMap { $0 } }) {
        let info = WindowInfo(id: id, pid: Int32(id), appName: "App \(id)", title: "Title \(id)", tileable: !floating.contains(id),
                              minimized: minimized.contains(id), appHidden: appHidden.contains(id), display: "d")
        state.windows[id] = WindowState(info: info, display: "d", floating: floating.contains(id))
    }
    for (index, id) in recent.enumerated() { state.windows[id]?.lastFocused = UInt64(recent.count - index) }
    state.focus = focus
    state.activeDisplay = "d"
    return state
}

private func open(_ state: SavedState, forward: Bool = true) -> SwitcherSelection? {
    SwitcherSelection(state: state, display: "d", config: .default, forward: forward)
}

@Test func switcherOpensOnTheWindowFocusedBeforeTheCurrentOne() throws {
    let state = model([[[1, 2, 3, 4], [5, 6]]], focus: 1, recent: [1, 5, 2])
    var selection = try #require(open(state))
    #expect(selection.order == [1, 5, 2, 3, 4, 6])
    #expect(selection.selected == 5)
    #expect(open(state, forward: false)?.selected == 6)
    var visited: [WindowID] = []
    for _ in 0..<6 { selection.step(forward: true); visited.append(selection.selected) }
    #expect(visited == [2, 3, 4, 6, 1, 5])
    selection.step(forward: false)
    #expect(selection.selected == 1)
    selection.step(forward: false)
    #expect(selection.selected == 6)
}

@Test func focusedWindowLeadsEvenWhenItsRecencyLags() throws {
    let selection = try #require(open(model([[[1, 2, 3]]], focus: 3, recent: [1, 2])))
    #expect(selection.order == [3, 1, 2])
    #expect(selection.selected == 1)
}

@Test func switcherWithoutManagedFocusStartsAtTheMostRecentWindow() throws {
    let state = model([[[1, 2, 3, 4], [5, 6]]], recent: [5, 2])
    let selection = try #require(open(state))
    #expect(selection.order == [5, 2, 1, 3, 4, 6])
    #expect(selection.selected == 5)
    #expect(open(state, forward: false)?.selected == 6)
    var elsewhere = state
    elsewhere.focus = 99
    #expect(open(elsewhere)?.selected == 5)
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
    #expect(SwitcherSelection(state: state, display: "other", config: .default, forward: true) == nil)
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
    var selection = try #require(open(model([[[1, 2, 3, 4], [5, 6]]], focus: 1, recent: [1, 5, 2])))
    #expect(selection.selected == 5)
    // Window 5 closes, 7 opens, and 2 takes focus: the order holds, 7 joins at the end, and 2 follows 5 in it.
    var changed = model([[[1, 2, 3, 4], [6, 7]]], focus: 2, recent: [2, 1])
    let kept = selection.update(state: changed, config: .default)
    #expect(kept)
    #expect(selection.order == [1, 2, 3, 4, 6, 7])
    #expect(selection.selected == 2)
    selection.step(forward: false)
    #expect(selection.selected == 1)
    // The last window in the order closing wraps the selection to the first.
    selection.step(forward: false)
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
    let far = try #require(open(model(grid, recent: [56], shown: GridCell(workspace: 2, page: 3))))
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
    let near = try #require(open(model(grid, recent: [12])))
    let corner = SwitcherContent(selection: near, state: model(grid))
    #expect(corner.rows == 0..<4)
    #expect(corner.columns == 0..<5)
    let small = try #require(open(model([[[1, 2]], [[3]]], floating: [2], recent: [1])))
    let whole = SwitcherContent(selection: small, state: model([[[1, 2]], [[3]]], floating: [2]))
    #expect(!whole.cropped)
    #expect(whole.pids == [1, 2, 3])
}

@Test func switcherOffersNothingOnADisplayWithoutVisibleWindows() {
    #expect(SwitcherSelection.offers(state: model([[[1, 2]]]), display: "d", config: .default))
    #expect(!SwitcherSelection.offers(state: model([[[1]]], minimized: [1]), display: "d", config: .default))
    #expect(!SwitcherSelection.offers(state: model([[[1, 2]]]), display: nil, config: .default))
    #expect(!SwitcherSelection.offers(state: model([[[1, 2]]]), display: "elsewhere", config: .default))
}
