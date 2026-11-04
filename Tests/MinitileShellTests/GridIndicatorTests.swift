import CoreGraphics
import MinitileCore
import Testing
@testable import minitile

@Test func indicatorExpiresAndOnlyPositionChangesRestartIt() {
    var clock = GridIndicatorTiming()
    let first = GridPosition(workspace: 1, page: 2)
    let initial = clock.update(first, now: 10)
    #expect(initial)
    #expect(clock.visible(now: 11.49))
    #expect(!clock.visible(now: 11.5))
    let same = clock.update(first, now: 11.6)
    #expect(!same)
    #expect(!clock.visible(now: 11.6))
    let changed = clock.update(GridPosition(workspace: 1, page: 3), now: 12)
    #expect(changed)
    _ = clock.update(GridPosition(workspace: 4, page: 5), now: 13)
    #expect(clock.visible(now: 14.49))
    #expect(!clock.visible(now: 14.5))
    _ = clock.update(nil, now: 14)
    #expect(!clock.visible(now: 14))
}

@Test func aCrossingShowsTheIndicatorAgainAtTheSamePosition() {
    var clock = GridIndicatorTiming()
    let none = clock.restart(now: 1)
    #expect(!none && !clock.visible(now: 1))
    _ = clock.update(GridPosition(workspace: 1, page: 2), now: 10)
    #expect(!clock.visible(now: 12))
    let restarted = clock.restart(now: 12)
    #expect(restarted)
    #expect(clock.visible(now: 13.49))
    #expect(!clock.visible(now: 13.5))
    let same = clock.update(GridPosition(workspace: 1, page: 2), now: 13)
    #expect(!same && clock.visible(now: 13))
}

@Test func indicatorPositionUsesIdentityInsteadOfRenumberedIndicesOrCounts() {
    var display = DisplayState(info: DisplayInfo(id: "a", frame: .init(x: 0, y: 0, width: 1000, height: 800)),
                               workspaces: [WorkspaceState(id: 4, home: "a", pages: [PageState(id: 1), PageState(id: 2)], currentPage: 2)],
                               currentWorkspace: 4)
    let original = GridPosition(display: display)
    display.workspaces[0].pages.removeFirst()
    display.workspaces[0].pages[0].windows = [42]
    #expect(GridPosition(display: display) == original)
    display.info.unmanagedReason = "No desktop pair"
    #expect(GridPosition(display: display) == nil)
}

@Test func displayIndicatorsHaveIndependentExpiryTimes() {
    var first = GridIndicatorTiming(), second = GridIndicatorTiming()
    _ = first.update(GridPosition(workspace: 1, page: 2), now: 1)
    _ = second.update(GridPosition(workspace: 3, page: 4), now: 2)
    #expect(!first.visible(now: 2.5))
    #expect(second.visible(now: 2.5))
}

@Test func gridIndicatorUsesVisibleIndicesAndIncludesEmptyPages() {
    var first = PageState(id: 70)
    first.windows = [1, 2]
    let empty = PageState(id: 12)
    let workspaces = [WorkspaceState(id: 42, home: "screen", pages: [first], currentPage: 70),
                      WorkspaceState(id: 9, home: "disconnected", pages: [first, empty], currentPage: 12)]
    let display = DisplayState(info: DisplayInfo(id: "screen", frame: .init(x: 0, y: 0, width: 1200, height: 900)),
                               workspaces: workspaces, currentWorkspace: 9)
    var state = SavedState()
    state.windows = [1: WindowState(info: WindowInfo(id: 1, pid: 10), display: "screen", floating: false),
                     2: WindowState(info: WindowInfo(id: 2, pid: 20, tileable: false), display: "screen", floating: true)]
    state.activeDisplay = "screen"
    state.focus = 1
    let content = GridIndicatorContent(display: display, state: state, config: .default, name: "Laptop")
    #expect(content.active)
    #expect(content.pages.flatMap { $0.flatMap(\.slots) }.filter { $0.focused }.isEmpty)
    #expect(content.workspace == 2)
    #expect(content.page == 2)
    #expect(content.pages.map { $0.map(\.empty) } == [[false], [false, true]])
    #expect(content.pages[0][0].slots.map(\.window) == [1])
    #expect(content.pages[0][0].floating == 1)
    #expect(content.pids == [10])
    #expect(content.position == "Workspace 2 / Page 2")
    #expect(content.rows == 0..<2)
    #expect(content.columns == 0..<2)
    #expect(!content.cropped)
    #expect(content.miniature(workspace: 0, page: 1) == nil)
}

@Test(arguments: [false, true])
func miniaturesMirrorTheCoreLayoutOnShownAndStashedPages(portrait: Bool) {
    let display = DisplayInfo(id: "d", frame: Rect(x: 0, y: 0, width: portrait ? 982 : 1512, height: portrait ? 1512 : 982),
                              visibleFrame: Rect(x: 0, y: 33, width: portrait ? 949 : 1512, height: portrait ? 1479 : 900), isPrimary: true)
    func info(_ id: WindowID, minimized: Bool = false, appHidden: Bool = false) -> WindowInfo {
        WindowInfo(id: id, pid: Int32(100 + id), bundleID: "app.\(id)", tileable: id != 3, minimized: minimized, appHidden: appHidden, display: "d")
    }
    var engine = Engine(config: Config(gaps: 10, padding: 6))
    _ = engine.handle(.started(saved: nil, windows: (1...7).map { info($0) }, displays: [display], focus: 1))
    _ = engine.handle(.windowUpdated(info(2, minimized: true)))
    _ = engine.handle(.windowUpdated(info(7, appHidden: true)))
    // Three active tiles on the shown page: every three-window variant, each at moved ratios.
    for variant in [Variant.mirrored, .alternate, .stacked, .standard] {
        _ = engine.handle(.command(["page", "variant"]))
        let output = engine.handle(.command(["page", "ratio", "0.3", "0.6"]))
        let state = engine.savedState()
        #expect(state.displays[0].workspaces[0].pages[0].variant == variant)
        let content = GridIndicatorContent(display: state.displays[0], state: state, config: engine.config, name: "Laptop")
        let pages = content.pages[0]
        #expect(pages.count == 2)
        #expect(pages[0].slots.map(\.window) == [1, 2, 4, 5])
        #expect(pages[0].reserved.map(\.window) == [2])
        #expect(pages[0].tiles.filter(\.focused).map(\.window) == [1])
        #expect(pages[0].floating == 1)
        #expect(pages[1].slots.map(\.window) == [6, 7])
        #expect(pages[1].reserved.map(\.window) == [7])
        #expect(pages[1].reserved.map(\.dimmed) == [true])
        #expect(pages[1].tiles.map(\.dimmed) == [false])
        let frames = output.scene.displays["d"]?.frames ?? [:]
        let tiles = pages.flatMap(\.tiles)
        #expect(Set(tiles.map(\.window)) == Set(frames.keys))
        for tile in tiles { #expect(tile.frame == frames[tile.window], "\(variant) window \(tile.window)") }
        #expect(tiles.map(\.pid) == [101, 104, 105, 106])
    }
}

@Test func gridIndicatorCropsToFourRowsAndFiveColumnsAroundTheCurrentCell() {
    let pages = Array(repeating: Array(repeating: GridMiniature(), count: 30), count: 25)
    let content = GridIndicatorContent(displayName: "External", active: false, workspace: 25, page: 17,
                                       area: Rect(x: 0, y: 0, width: 2560, height: 1440), pages: pages, warning: nil)
    #expect(content.rows == 21..<25)
    #expect(content.columns == 14..<19)
    #expect(content.cropped)
    let middle = GridIndicatorContent(displayName: "External", active: false, workspace: 2, page: 1,
                                      area: Rect(x: 0, y: 0, width: 2560, height: 1440), pages: pages, warning: nil)
    #expect(middle.rows == 0..<4)
    #expect(middle.columns == 0..<5)
    #expect(GridIndicatorContent.viewport(count: 0, selected: nil, limit: 4).isEmpty)
    #expect(GridIndicatorContent.viewport(count: 3, selected: 1, limit: 4) == 0..<3)
    #expect(GridIndicatorContent.viewport(count: 9, selected: 5, limit: 5) == 2..<7)
}

@Test func indicatorPidsCoverOnlyDrawnCells() {
    func page(_ pid: Int32) -> GridMiniature { GridMiniature(slots: [.init(window: WindowID(pid), pid: pid, frame: nil)]) }
    let pages = [(1...7).map { page(Int32($0)) }]
    let content = GridIndicatorContent(displayName: "Laptop", active: true, workspace: 1, page: 1,
                                       area: Rect(x: 0, y: 0, width: 1512, height: 945), pages: pages, warning: nil)
    #expect(content.pids == [1, 2, 3, 4, 5])
}

@Test func cellsTakeTheUsableAreaProportions() {
    #expect(GridIndicatorGeometry.cellSize(area: Rect(x: 0, y: 33, width: 1512, height: 945)) == CGSize(width: 128, height: 80))
    #expect(GridIndicatorGeometry.cellSize(area: Rect(x: 0, y: 0, width: 945, height: 1512)) == CGSize(width: 80, height: 128))
    #expect(GridIndicatorGeometry.cellSize(area: Rect(x: 0, y: 0, width: 2560, height: 1440)) == CGSize(width: 135, height: 76))
    #expect(GridIndicatorGeometry.cellSize(area: Rect(x: 0, y: 0, width: 5120, height: 1440)) == CGSize(width: 175, height: 58))
    #expect(GridIndicatorGeometry.cellSize(area: Rect(x: 0, y: 0, width: 0, height: 0)) == CGSize(width: 128, height: 80))
}

@Test func panelSizeFollowsTheDrawnCellCount() {
    let area = Rect(x: 0, y: 33, width: 1512, height: 945)
    let single = GridIndicatorContent(displayName: "Laptop", active: true, workspace: 1, page: 1, area: area,
                                      pages: [[GridMiniature()]], warning: nil)
    #expect(GridIndicatorGeometry(content: single).size == CGSize(width: 440, height: 236))
    let full = GridIndicatorContent(displayName: "Laptop", active: true, workspace: 3, page: 4, area: area,
                                    pages: Array(repeating: Array(repeating: GridMiniature(), count: 9), count: 7), warning: nil)
    let geometry = GridIndicatorGeometry(content: full)
    #expect(geometry.metrics == .indicator)
    #expect(geometry.size == CGSize(width: 788, height: 552))
    #expect(geometry.cellRect(row: 1, column: 2) == CGRect(x: 356, y: 224, width: 128, height: 80))
    #expect(geometry.columnLabelRect(column: 2).midX == geometry.cellRect(row: 0, column: 2).midX)
    #expect(geometry.rowLabelRect(row: 3).midY == geometry.cellRect(row: 3, column: 0).midY)
    #expect(geometry.footerRect.minY >= geometry.cellRect(row: 3, column: 0).maxY)
    let unmanaged = GridIndicatorContent(displayName: "External", active: false, workspace: nil, page: nil, area: area,
                                         pages: [], warning: "Create two desktops")
    #expect(GridIndicatorGeometry(content: unmanaged).size == CGSize(width: 496, height: 232))
}

@Test func tilesKeepTheirProportionsAndStaySeparated() {
    let area = Rect(x: 0, y: 33, width: 1512, height: 945)
    let cell = CGRect(x: 0, y: 0, width: 64, height: 40)
    let full = Layout.frames(frame: area, count: 1)[0]
    #expect(GridIndicatorGeometry.tileRect(full, area: area, cell: cell) == CGRect(x: 3, y: 3, width: 58, height: 34))
    let halves = Layout.frames(frame: area, count: 2, r1: 0.3).map { GridIndicatorGeometry.tileRect($0, area: area, cell: cell) }
    #expect(halves[0].maxX < halves[1].minX)
    #expect(abs(halves[0].width / (halves[0].width + halves[1].width) - 0.3) < 0.03)
    let portraitArea = Rect(x: 0, y: 0, width: 945, height: 1512)
    let portraitCell = CGRect(x: 10, y: 20, width: 40, height: 64)
    let stacked = Layout.frames(frame: portraitArea, count: 2).map { GridIndicatorGeometry.tileRect($0, area: portraitArea, cell: portraitCell) }
    #expect(stacked[0].maxY < stacked[1].minY)
    #expect(stacked.allSatisfy { portraitCell.insetBy(dx: 2, dy: 2).contains($0) })
    #expect(GridIndicatorGeometry.tileRect(full, area: Rect(x: 0, y: 0, width: 0, height: 0), cell: cell) == .zero)
}

@Test func iconsBadgesAndReservedSlotsFitTheirCell() {
    #expect(GridIndicatorGeometry.iconRect(tile: CGRect(x: 6, y: 6, width: 116, height: 68)) == CGRect(x: 50, y: 26, width: 28, height: 28))
    #expect(GridIndicatorGeometry.iconRect(tile: CGRect(x: 0, y: 0, width: 26, height: 68)).width == 20)
    #expect(GridIndicatorGeometry.iconRect(tile: CGRect(x: 0, y: 0, width: 128, height: 14)).width == 14)
    let cell = CGRect(x: 0, y: 0, width: 128, height: 80)
    #expect(GridIndicatorGeometry.reservedRects(count: 2, cell: cell, metrics: .indicator)
            == [CGRect(x: 4, y: 56, width: 20, height: 20), CGRect(x: 26, y: 56, width: 20, height: 20)])
    #expect(GridIndicatorGeometry.badgeRect(count: 3, cell: cell, metrics: .indicator) == CGRect(x: 110, y: -6, width: 24, height: 24))
    #expect(GridIndicatorGeometry.badgeRect(count: 12, cell: cell, metrics: .indicator) == CGRect(x: 98, y: -6, width: 36, height: 24))
}

@Test func appIconsLoadOncePerPidAndArePrunedWithTheirApps() {
    var cache = AppIconCache<String>()
    var loads: [Int32] = []
    let load: (Int32) -> String? = { loads.append($0); return $0 == 2 ? nil : "icon \($0)" }
    #expect(cache.icon(1, load: load) == "icon 1")
    #expect(cache.icon(1, load: load) == "icon 1")
    #expect(cache.icon(2, load: load) == nil)
    #expect(cache.icon(2, load: load) == nil)
    #expect(loads == [1, 2])
    cache.prune(keeping: [2, 3])
    #expect(cache.icons.keys.sorted() == [2])
    #expect(cache.icon(1, load: load) == "icon 1")
    #expect(loads == [1, 2, 1])
}

@Test func gridIndicatorExplainsUnmanagedDisplay() {
    let display = DisplayState(info: DisplayInfo(id: "external", frame: .init(x: 0, y: 0, width: 1200, height: 900),
                                                unmanagedReason: DisplayNeed.secondDesktop.reason))
    let content = GridIndicatorContent(display: display, state: SavedState(), config: .default, name: "External")
    #expect(content.position == "Display not managed")
    #expect(content.warning == DisplayNeed.secondDesktop.reason)
    #expect(content.workspace == nil)
    #expect(content.page == nil)
    #expect(content.rows.isEmpty)
    #expect(content.shown == nil)
    #expect(!content.active)
}

@Test func floatersKeepEveryFloatingWindowAndMarkInactiveOnes() {
    let display = DisplayInfo(id: "d", frame: Rect(x: 0, y: 0, width: 1512, height: 982), isPrimary: true)
    var engine = Engine()
    _ = engine.handle(.started(saved: nil, windows: [WindowInfo(id: 1, pid: 10, display: "d"), WindowInfo(id: 2, pid: 20, tileable: false, display: "d"),
                                                     WindowInfo(id: 3, pid: 30, tileable: false, display: "d")], displays: [display], focus: 1))
    _ = engine.handle(.windowUpdated(WindowInfo(id: 3, pid: 30, tileable: false, minimized: true, display: "d")))
    let state = engine.savedState()
    let miniature = GridMiniature(page: state.displays[0].workspaces[0].pages[0], windows: state.windows, focus: nil,
                                  area: display.visibleFrame, config: .default)
    #expect(miniature.floaters == [.init(window: 2, pid: 20), .init(window: 3, pid: 30, active: false)])
    #expect(miniature.floating == 2)
    #expect(miniature.slots.map(\.window) == [1])
}

@Test func switcherMetricsDoubleTheCellAndFitTheTrayOnTheTopEdge() {
    let area = Rect(x: 0, y: 33, width: 1512, height: 945)
    #expect(GridIndicatorGeometry.cellSize(area: area, metrics: .switcher) == CGSize(width: 256, height: 160))
    #expect(GridIndicatorGeometry.iconRect(tile: CGRect(x: 0, y: 0, width: 248, height: 152), range: GridMetrics.switcher.icon).width == 64)
    #expect(GridIndicatorGeometry.iconRect(tile: CGRect(x: 0, y: 0, width: 120, height: 40), range: GridMetrics.switcher.icon).width == 32)
    let cell = CGRect(x: 0, y: 200, width: 256, height: 160)
    #expect(GridIndicatorGeometry.trayRects(count: 2, cell: cell, metrics: .switcher)
            == [CGRect(x: 180, y: 184, width: 32, height: 32), CGRect(x: 216, y: 184, width: 32, height: 32)])
    let crowded = GridIndicatorGeometry.trayRects(count: 10, cell: cell, metrics: .switcher)
    #expect(crowded.allSatisfy { $0.width == 20 && $0.midY == cell.minY })
    #expect(crowded.first.map { $0.minX >= cell.minX + 8 } == true)
    #expect(GridIndicatorGeometry.trayRects(count: 0, cell: cell, metrics: .switcher).isEmpty)
    #expect(GridIndicatorGeometry.trayRects(count: 2, cell: cell, metrics: .indicator).isEmpty)
    // A display with room for the whole 4 by 5 grid draws it at full size.
    let geometry = GridIndicatorGeometry(area: Rect(x: 0, y: 0, width: 1600, height: 1000), rows: 4, columns: 5, cropped: true,
                                         metrics: .switcher)
    #expect(geometry.metrics == .switcher)
    #expect(geometry.size == CGSize(width: 1476, height: 940))
    // The tray and its background reach 20 pt above a cell, clear of the column labels and the row above.
    let first = geometry.cellRect(row: 0, column: 0), below = geometry.cellRect(row: 1, column: 0)
    #expect(first.minY - 20 >= geometry.gridTop + geometry.labelHeight)
    #expect(below.minY - 20 > first.maxY)
    #expect(GridIndicatorGeometry.cell(row: 1, column: 2, size: geometry.cell, spacing: 24) == CGRect(x: 560, y: 184, width: 256, height: 160))
}
