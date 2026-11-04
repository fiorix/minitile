import CoreGraphics
import MinitileCore

enum SwitcherDirection: String, Equatable, Sendable { case left, right, up, down }

/// The windows the switcher offers on one display, placed where the switcher draws them.
struct SwitcherGrid: Equatable {
    struct Entry: Equatable {
        var window: WindowID
        var cell: GridCell
        /// In the uncropped grid of switcher cells, so arrows cross pages and workspaces.
        var center: CGPoint
        var recency: UInt64
    }

    /// The display's usable area: cells take its proportions and tiles are scaled from it.
    var area: Rect
    var pages: [[GridMiniature]]
    /// The page being shown, which holds the focus when a window on this display has it.
    var shown: GridCell?
    /// Tiled and floating windows without minimized and app-hidden ones, in grid order: workspaces, pages, tiles by
    /// slot, then floating windows.
    var entries: [Entry]

    /// Nil when the display is unknown or unmanaged.
    init?(state: SavedState, display id: DisplayID, config: Config) {
        guard let display = state.displays.first(where: { $0.info.id == id }), display.info.unmanagedReason == nil else { return nil }
        let area = display.info.visibleFrame
        let metrics = GridMetrics.switcher
        let size = GridIndicatorGeometry.cellSize(area: area, metrics: metrics)
        self.area = area
        pages = display.workspaces.map { workspace in
            workspace.pages.map { GridMiniature(page: $0, windows: state.windows, focus: nil, area: area, config: config) }
        }
        shown = display.workspaces.firstIndex { $0.id == display.currentWorkspace }.flatMap { w in
            display.workspaces[w].pages.firstIndex { $0.id == display.workspaces[w].currentPage }.map { GridCell(workspace: w, page: $0) }
        }
        entries = []
        for (w, row) in pages.enumerated() {
            for (p, miniature) in row.enumerated() {
                let at = GridCell(workspace: w, page: p)
                let cell = GridIndicatorGeometry.cell(row: w, column: p, size: size, spacing: metrics.spacing)
                func entry(_ window: WindowID, _ rect: CGRect) -> Entry {
                    Entry(window: window, cell: at, center: CGPoint(x: rect.midX, y: rect.midY), recency: state.windows[window]?.lastFocused ?? 0)
                }
                for tile in miniature.tiles {
                    guard let frame = tile.frame else { continue }
                    entries.append(entry(tile.window, GridIndicatorGeometry.tileRect(frame, area: area, cell: cell)))
                }
                let floaters = miniature.floaters.filter(\.active)
                let tray = GridIndicatorGeometry.trayRects(count: floaters.count, cell: cell, side: metrics.trayIcon ?? 16)
                for (floater, rect) in zip(floaters, tray) { entries.append(entry(floater.window, rect)) }
            }
        }
    }

    /// Most recently focused first; grid order breaks ties, such as windows never focused.
    var recent: [WindowID] {
        entries.enumerated().sorted { a, b in
            a.element.recency != b.element.recency ? a.element.recency > b.element.recency : a.offset < b.offset
        }.map(\.element.window)
    }
}

/// The switcher's selection over one display's windows. The order is most recently focused first, led by the focused
/// window, and stays fixed while the switcher is open: windows that appear meanwhile join at the end.
struct SwitcherSelection: Equatable {
    let display: DisplayID
    private(set) var grid: SwitcherGrid
    private(set) var order: [WindowID]
    private(set) var selected: WindowID

    /// Next selects the window focused before the current one, or the most recent one when no window of the display has
    /// focus; prev selects the least recently focused one. Nil when the display has no window to offer.
    init?(state: SavedState, display: DisplayID, config: Config, forward: Bool) {
        guard let grid = SwitcherGrid(state: state, display: display, config: config) else { return nil }
        var order = grid.recent
        if let focus = state.focus, let index = order.firstIndex(of: focus) { order.insert(order.remove(at: index), at: 0) }
        guard let last = order.last else { return nil }
        let focusLeads = state.focus != nil && order.first == state.focus
        self.display = display
        self.grid = grid
        self.order = order
        selected = forward ? order[focusLeads ? 1 % order.count : 0] : last
    }

    var entry: SwitcherGrid.Entry? { grid.entries.first { $0.window == selected } }

    /// Steps through the recent order, wrapping around.
    mutating func step(forward: Bool) {
        guard let index = order.firstIndex(of: selected) else { return }
        let count = order.count
        selected = order[((index + (forward ? 1 : -1)) % count + count) % count]
    }

    /// The nearest window center in the direction's half-plane, as spatial focus picks on a page; grid order breaks
    /// ties. It does not wrap.
    mutating func move(_ direction: SwitcherDirection) {
        guard let origin = entry?.center else { return }
        var best: WindowID?, distance = CGFloat.infinity
        for other in grid.entries where other.window != selected {
            let dx = other.center.x - origin.x, dy = other.center.y - origin.y
            let ahead = switch direction {
            case .left: dx < -1
            case .right: dx > 1
            case .up: dy < -1
            case .down: dy > 1
            }
            let candidate = dx * dx + dy * dy
            if ahead, candidate < distance { best = other.window; distance = candidate }
        }
        if let best { selected = best }
    }

    /// Follows model changes while open: a window that goes leaves the order, and when it was the selection, the next
    /// window in the order takes its place. Returns false when the display or every window is gone.
    mutating func update(state: SavedState, config: Config) -> Bool {
        guard let grid = SwitcherGrid(state: state, display: display, config: config) else { return false }
        let present = Set(grid.entries.map(\.window)), old = order
        let next = old.filter(present.contains) + grid.recent.filter { !old.contains($0) }
        guard let first = next.first else { return false }
        if !present.contains(selected) {
            let start = old.firstIndex(of: selected) ?? 0
            selected = (1..<old.count).lazy.map { old[(start + $0) % old.count] }.first(where: present.contains) ?? first
        }
        self.grid = grid
        order = next
        return true
    }
}

/// What the switcher panel draws: the display's grid cropped around the selection, which the header names.
struct SwitcherContent: Equatable {
    var area: Rect
    var pages: [[GridMiniature]]
    var shown: GridCell?
    var selected: WindowID
    /// The selection's cell, which the crop centers on and the labels emphasize.
    var cell: GridCell
    var app: String
    var title: String

    init(selection: SwitcherSelection, state: SavedState) {
        area = selection.grid.area
        pages = selection.grid.pages
        shown = selection.grid.shown
        selected = selection.selected
        cell = selection.entry?.cell ?? GridCell(workspace: 0, page: 0)
        app = state.windows[selected]?.info.appName ?? ""
        title = state.windows[selected]?.info.title ?? ""
    }

    var rows: Range<Int> {
        GridIndicatorContent.viewport(count: pages.count, selected: cell.workspace + 1, limit: GridIndicatorContent.rowLimit)
    }
    var columns: Range<Int> {
        GridIndicatorContent.viewport(count: pageCount, selected: cell.page + 1, limit: GridIndicatorContent.columnLimit)
    }
    var cropped: Bool { rows.count < pages.count || columns.count < pageCount }
    var position: String { "Workspace \(cell.workspace + 1) / Page \(cell.page + 1)" }
    var geometry: GridIndicatorGeometry {
        GridIndicatorGeometry(area: area, rows: rows.count, columns: columns.count, cropped: cropped, metrics: .switcher)
    }

    private var pageCount: Int { pages.map(\.count).max() ?? 0 }

    /// Apps whose icons the drawn cells need: tiles, reserved slots and the floating tray.
    var pids: Set<Int32> {
        let drawn = rows.flatMap { w in columns.compactMap { pages[w].indices.contains($0) ? pages[w][$0] : nil } }
        return Set(drawn.flatMap { $0.slots.map(\.pid) + $0.floaters.filter(\.active).map(\.pid) })
    }
}
