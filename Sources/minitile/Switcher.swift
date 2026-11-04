import CoreGraphics
import MinitileCore

/// A direction on screen: a switcher arrow, or the side of a panel a monitor marker sits on.
enum SwitcherDirection: String, Equatable, Sendable, CaseIterable {
    case left, right, up, down

    /// The unit step toward this side in global coordinates, where y grows downwards.
    var dx: Int { self == .left ? -1 : self == .right ? 1 : 0 }
    var dy: Int { self == .up ? -1 : self == .down ? 1 : 0 }
}

/// The windows the switcher offers on one display, placed where the switcher draws them.
struct SwitcherGrid: Equatable {
    struct Entry: Equatable {
        var window: WindowID
        var cell: GridCell
        /// In the uncropped grid of switcher cells, so arrows cross pages and workspaces.
        var center: CGPoint
    }

    var display: DisplayID
    /// The display's usable area: cells take its proportions and tiles are scaled from it.
    var area: Rect
    var pages: [[GridMiniature]]
    /// The page being shown, which holds the focus when a window on this display has it.
    var shown: GridCell?
    /// Tiled and floating windows without minimized and app-hidden ones, in ring order: workspaces top to bottom, pages
    /// left to right, each page's tiles in reading order (top to bottom, then left to right), then its floating windows.
    var entries: [Entry]

    /// Nil when the display is unknown or unmanaged.
    init?(state: SavedState, display id: DisplayID, config: Config) {
        guard let display = state.displays.first(where: { $0.info.id == id }), display.info.unmanagedReason == nil else { return nil }
        let area = display.info.visibleFrame
        let metrics = GridMetrics.switcher
        let size = GridIndicatorGeometry.cellSize(area: area, metrics: metrics)
        self.display = id
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
                    Entry(window: window, cell: at, center: CGPoint(x: rect.midX, y: rect.midY))
                }
                let placed = miniature.tiles.compactMap { tile in tile.frame.map { (tile.window, $0) } }
                for (window, frame) in placed.sorted(by: { $0.1.y != $1.1.y ? $0.1.y < $1.1.y : $0.1.x < $1.1.x }) {
                    entries.append(entry(window, GridIndicatorGeometry.tileRect(frame, area: area, cell: cell)))
                }
                let floaters = miniature.floaters.filter(\.active)
                let tray = GridIndicatorGeometry.trayRects(count: floaters.count, cell: cell, metrics: metrics)
                for (floater, rect) in zip(floaters, tray) { entries.append(entry(floater.window, rect)) }
            }
        }
    }

    /// The window an arrow moving `direction` from another display selects here: the one nearest the edge it enters
    /// through, as the lowest centre for Up, on the shown page, or with no window there on the whole grid. Grid order
    /// breaks ties.
    func entered(moving direction: SwitcherDirection) -> WindowID? {
        let page = entries.filter { $0.cell == shown }
        var best: Entry?
        for candidate in page.isEmpty ? entries : page {
            guard let current = best else { best = candidate; continue }
            let nearer = switch direction {
            case .up: candidate.center.y > current.center.y
            case .down: candidate.center.y < current.center.y
            case .left: candidate.center.x > current.center.x
            case .right: candidate.center.x < current.center.x
            }
            if nearer { best = candidate }
        }
        return best?.window
    }
}

/// The switcher's selection over the windows of every managed display. The order is the ring and stays fixed while the
/// switcher is open: windows that appear meanwhile join at the end.
struct SwitcherSelection: Equatable {
    /// The managed displays' grids in arrangement order: by the top edges of their frames, then their left edges.
    private(set) var grids: [SwitcherGrid]
    /// Every display in the model's order, where crossing arrows look for neighbours as Ctrl+arrows do.
    private(set) var displays: [DisplayInfo]
    private(set) var order: [WindowID]
    private(set) var selected: WindowID

    /// Next selects the window after the focused one in the ring and prev the one before it, wrapping around; with no
    /// managed window focused they start at the first or last window. Nil when no managed display has a window to
    /// offer.
    init?(state: SavedState, config: Config, forward: Bool) {
        let grids = Self.grids(state: state, config: config)
        let order = grids.flatMap { $0.entries.map(\.window) }
        guard let first = order.first, let last = order.last else { return nil }
        self.grids = grids
        displays = state.displays.map(\.info)
        self.order = order
        if let focus = state.focus, let index = order.firstIndex(of: focus) {
            selected = order[(index + (forward ? 1 : order.count - 1)) % order.count]
        } else { selected = forward ? first : last }
    }

    /// The grid of the display holding the selection.
    var grid: SwitcherGrid { grids.first { $0.entries.contains { $0.window == selected } } ?? grids[0] }
    var display: DisplayID { grid.display }
    var entry: SwitcherGrid.Entry? { grid.entries.first { $0.window == selected } }

    /// Whether some managed display has a window to offer; without one, Cmd+Tab goes to the native app switcher.
    static func offers(state: SavedState, config: Config) -> Bool {
        grids(state: state, config: config).contains { !$0.entries.isEmpty }
    }

    private static func grids(state: SavedState, config: Config) -> [SwitcherGrid] {
        state.displays.map(\.info).sorted { ($0.frame.y, $0.frame.x, $0.id) < ($1.frame.y, $1.frame.x, $1.id) }
            .compactMap { SwitcherGrid(state: state, display: $0.id, config: config) }
    }

    /// Steps through the ring, wrapping around.
    mutating func step(forward: Bool) {
        guard let index = order.firstIndex(of: selected) else { return }
        let count = order.count
        selected = order[((index + (forward ? 1 : -1)) % count + count) % count]
    }

    /// The nearest window center in the direction's half-plane on the selection's display, as spatial focus picks on a
    /// page; grid order breaks ties. With none there, the selection crosses to the managed display on that side, found
    /// as for Ctrl+arrows, when it has a window. It does not wrap.
    mutating func move(_ direction: SwitcherDirection) {
        let grid = grid
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
        if let best { selected = best; return }
        guard let d = displays.firstIndex(where: { $0.id == grid.display }),
              let e = DisplayInfo.neighbour(of: d, in: displays, dx: direction.dx, dy: direction.dy),
              let entered = grids.first(where: { $0.display == displays[e].id })?.entered(moving: direction) else { return }
        selected = entered
    }

    /// Follows model changes while open: a window that goes, with its display or on its own, leaves the order, and when
    /// it was the selection, the next window in the order takes its place. Returns false when every window is gone.
    mutating func update(state: SavedState, config: Config) -> Bool {
        let grids = Self.grids(state: state, config: config)
        let windows = grids.flatMap { $0.entries.map(\.window) }
        let present = Set(windows), old = order, known = Set(old)
        let next = old.filter(present.contains) + windows.filter { !known.contains($0) }
        guard let first = next.first else { return false }
        if !present.contains(selected) {
            let start = old.firstIndex(of: selected) ?? 0
            selected = (1..<old.count).lazy.map { old[(start + $0) % old.count] }.first(where: present.contains) ?? first
        }
        self.grids = grids
        displays = state.displays.map(\.info)
        order = next
        return true
    }
}

/// What the switcher panel draws: the grid of the selection's display, cropped around the selection, which the header
/// names.
struct SwitcherContent: Equatable {
    var area: Rect
    var pages: [[GridMiniature]]
    var shown: GridCell?
    var selected: WindowID
    /// The selection's cell, which the crop centers on and the labels emphasize.
    var cell: GridCell
    var app: String
    var title: String
    /// The selection's display, named only when more than one display is managed.
    var displayName: String?

    /// `names` are the displays' names by ID, as `DisplayCatalog.names` gives them.
    init(selection: SwitcherSelection, state: SavedState, names: [DisplayID: String] = [:]) {
        let grid = selection.grid
        area = grid.area
        pages = grid.pages
        shown = grid.shown
        selected = selection.selected
        cell = selection.entry?.cell ?? GridCell(workspace: 0, page: 0)
        app = state.windows[selected]?.info.appName ?? ""
        title = state.windows[selected]?.info.title ?? ""
        let managed = state.displays.filter { $0.info.unmanagedReason == nil }.count
        displayName = managed > 1 ? names[grid.display] ?? "Display" : nil
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
