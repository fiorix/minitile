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
    let content = GridIndicatorContent(display: display, name: "Laptop", active: true)
    #expect(content.workspace == 2)
    #expect(content.page == 2)
    #expect(content.windowCounts == [[2], [2, 0]])
    #expect(content.position == "Workspace 2 / Page 2")
    #expect(content.rows == 0..<2)
    #expect(content.columns == 0..<2)
}

@Test func gridIndicatorKeepsCurrentCellInBoundedViewport() {
    let content = GridIndicatorContent(displayName: "External", active: false, workspace: 25, page: 17,
                                       windowCounts: Array(repeating: Array(repeating: 1, count: 30), count: 25), warning: nil)
    #expect(content.rows == 19..<25)
    #expect(content.columns == 12..<20)
    #expect(content.rows.contains(24))
    #expect(content.columns.contains(16))
    #expect(content.size.width == 308)
    #expect(content.size.height == 274)
    #expect(GridIndicatorContent.viewport(count: 0, selected: nil, limit: 6).isEmpty)
    #expect(GridIndicatorContent.viewport(count: 3, selected: 1, limit: 6) == 0..<3)
}

@Test func gridIndicatorExplainsUnmanagedDisplay() {
    let display = DisplayState(info: DisplayInfo(id: "external", frame: .init(x: 0, y: 0, width: 1200, height: 900),
                                                unmanagedReason: "Create two desktops in Mission Control"))
    let content = GridIndicatorContent(display: display, name: "External", active: false)
    #expect(content.position == "Display not managed")
    #expect(content.warning == "Create two desktops in Mission Control")
    #expect(content.workspace == nil)
    #expect(content.page == nil)
    #expect(content.rows.isEmpty)
}
