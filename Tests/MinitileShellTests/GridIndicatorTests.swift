import MinitileCore
import Testing
@testable import minitile

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
