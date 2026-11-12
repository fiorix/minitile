import CoreGraphics
import MinitileCore

/// A direction on screen: a switcher arrow, or the side of a panel a monitor marker sits on.
enum SwitcherDirection: String, Equatable, Sendable, CaseIterable {
    case left, right, up, down

    /// The unit step toward this side in global coordinates, where y grows downwards.
    var dx: Int { self == .left ? -1 : self == .right ? 1 : 0 }
    var dy: Int { self == .up ? -1 : self == .down ? 1 : 0 }
}

/// A running app the switcher offers on its own, in the apps row, since none of its windows is in the ring.
struct SwitcherApp: Equatable, Sendable {
    var pid: Int32
    var name: String
}

/// What the switcher selects: a window, or an app in the apps row.
enum SwitcherTarget: Hashable, Sendable {
    case window(WindowID)
    case app(Int32)

    var window: WindowID? { if case .window(let id) = self { id } else { nil } }
    var app: Int32? { if case .app(let pid) = self { pid } else { nil } }
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

    /// Where arrows take an apps row of `count` icons: centered under the uncropped grid, a cell's spacing below it,
    /// at the icons' full size. The panel draws the row centered too, so the nearest icon is the one that looks it.
    func shelf(_ count: Int) -> [CGPoint] {
        let metrics = GridMetrics.switcher
        guard count > 0, let icon = metrics.shelfIcon else { return [] }
        let size = GridIndicatorGeometry.cellSize(area: area, metrics: metrics)
        func span(_ cells: Int, _ length: CGFloat) -> CGFloat { cells == 0 ? 0 : CGFloat(cells) * (length + metrics.spacing) - metrics.spacing }
        let width = span(pages.map(\.count).max() ?? 0, size.width), height = span(pages.count, size.height)
        let pitch = icon + GridIndicatorGeometry.shelfGap(metrics)
        let first = width / 2 - CGFloat(count - 1) * pitch / 2
        return (0..<count).map { CGPoint(x: first + CGFloat($0) * pitch, y: height + metrics.spacing + icon / 2) }
    }
}

/// The switcher's selection over the windows of every managed display and the apps row. The order is the ring and
/// stays fixed while the switcher is open: windows first, then the apps, and those that appear meanwhile join at the end
/// of their part.
struct SwitcherSelection: Equatable {
    /// The display on view and the cell its crop centers on.
    struct Place: Equatable {
        var display: DisplayID
        var cell: GridCell
    }

    /// The managed displays' grids in arrangement order: by the top edges of their frames, then their left edges.
    private(set) var grids: [SwitcherGrid]
    /// Every display in the model's order, where crossing arrows look for neighbours as Ctrl+arrows do.
    private(set) var displays: [DisplayInfo]
    /// The apps row, in ring order: the running apps with none of their windows in the ring.
    private(set) var apps: [SwitcherApp]
    private(set) var order: [SwitcherTarget]
    private(set) var selected: SwitcherTarget
    /// The selected window's display and cell. An app is on no display, so while one is selected the view stays where
    /// the selection last was.
    private(set) var place: Place

    /// Next selects the window after the focused one and prev the one before it, wrapping around the windows alone, so
    /// opening never lands on an app while there is a window; with no managed window focused they start at the first or
    /// last window. `apps` are the running apps in the order the row keeps; `active` is the display on view when an
    /// app is selected first. Nil without a managed display, or with neither a window nor an app to offer.
    init?(state: SavedState, config: Config, apps running: [SwitcherApp] = [], forward: Bool, active: DisplayID? = nil) {
        let grids = Self.grids(state: state, config: config)
        guard let home = grids.first(where: { $0.display == active }) ?? grids.first else { return nil }
        let windows = grids.flatMap { $0.entries.map(\.window) }
        let apps = Self.shelf(running, state: state, windows: windows)
        let order = windows.map(SwitcherTarget.window) + apps.map { .app($0.pid) }
        guard let first = order.first, let last = order.last else { return nil }
        self.grids = grids
        displays = state.displays.map(\.info)
        self.apps = apps
        self.order = order
        if let focus = state.focus, let index = windows.firstIndex(of: focus) {
            selected = .window(windows[(index + (forward ? 1 : windows.count - 1)) % windows.count])
        } else if let first = windows.first, let last = windows.last {
            selected = .window(forward ? first : last)
        } else { selected = forward ? first : last }
        place = Place(display: home.display, cell: home.shown ?? GridCell(workspace: 0, page: 0))
        follow()
    }

    /// The grid on view: that of the display holding the selection, or the one it last was on.
    var grid: SwitcherGrid { grids.first { $0.display == place.display } ?? grids[0] }
    var display: DisplayID { grid.display }
    var entry: SwitcherGrid.Entry? { selected.window.flatMap { id in grid.entries.first { $0.window == id } } }

    /// Whether the switcher has something to offer: a managed display with a window on one, or else an app for the apps
    /// row. Without that, Cmd+Tab goes to the native app switcher. `apps` is read only when no display has a window.
    static func offers(state: SavedState, config: Config, apps: () -> [SwitcherApp] = { [] }) -> Bool {
        let grids = grids(state: state, config: config)
        return grids.contains { !$0.entries.isEmpty } || (!grids.isEmpty && !apps().isEmpty)
    }

    private static func grids(state: SavedState, config: Config) -> [SwitcherGrid] {
        state.displays.map(\.info).sorted { ($0.frame.y, $0.frame.x, $0.id) < ($1.frame.y, $1.frame.x, $1.id) }
            .compactMap { SwitcherGrid(state: state, display: $0.id, config: config) }
    }

    /// The running apps that own none of the ring's windows: those without windows, with only minimized or hidden
    /// ones, or with windows minitile does not manage.
    private static func shelf(_ running: [SwitcherApp], state: SavedState, windows: [WindowID]) -> [SwitcherApp] {
        let owners = Set(windows.compactMap { state.windows[$0]?.info.pid })
        return running.filter { !owners.contains($0.pid) }
    }

    /// The view follows a selected window. With an app selected it stays, on a display and a cell that still exist.
    private mutating func follow() {
        if let id = selected.window {
            for grid in grids {
                guard let entry = grid.entries.first(where: { $0.window == id }) else { continue }
                place = Place(display: grid.display, cell: entry.cell)
                return
            }
        }
        guard let grid = grids.first(where: { $0.display == place.display }) ?? grids.first else { return }
        let known = grid.display == place.display && grid.pages.indices.contains(place.cell.workspace)
            && grid.pages[place.cell.workspace].indices.contains(place.cell.page)
        if !known { place = Place(display: grid.display, cell: grid.shown ?? GridCell(workspace: 0, page: 0)) }
    }

    /// Steps through the ring, wrapping around.
    mutating func step(forward: Bool) {
        guard let index = order.firstIndex(of: selected) else { return }
        let count = order.count
        selected = order[((index + (forward ? 1 : -1)) % count + count) % count]
        follow()
    }

    /// The nearest window center in the direction's half-plane on the display on view, as spatial focus picks on a
    /// page; grid order breaks ties. Down from a window with none below it moves to the nearest app in the apps row,
    /// and Up from an app to the nearest window; Left and Right in the row stay in it. With nothing there, the selection
    /// crosses to the managed display on that side, found as for Ctrl+arrows, when it has a window. It does not wrap.
    mutating func move(_ direction: SwitcherDirection) {
        let grid = grid
        let tiles = grid.entries.map { (target: SwitcherTarget.window($0.window), center: $0.center) }
        let row = zip(apps, grid.shelf(apps.count)).map { (target: SwitcherTarget.app($0.pid), center: $1) }
        guard let origin = (tiles + row).first(where: { $0.target == selected })?.center else { return }
        func nearest(_ candidates: [(target: SwitcherTarget, center: CGPoint)]) -> SwitcherTarget? {
            var best: SwitcherTarget?, distance = CGFloat.infinity
            for other in candidates where other.target != selected {
                let dx = other.center.x - origin.x, dy = other.center.y - origin.y
                let ahead = switch direction {
                case .left: dx < -1
                case .right: dx > 1
                case .up: dy < -1
                case .down: dy > 1
                }
                let candidate = dx * dx + dy * dy
                if ahead, candidate < distance { best = other.target; distance = candidate }
            }
            return best
        }
        let sideways = direction == .left || direction == .right
        var best = nearest(selected.app != nil && sideways ? row : tiles)
        if best == nil, selected.window != nil, direction == .down { best = nearest(row) }
        if let best { selected = best; follow(); return }
        guard let d = displays.firstIndex(where: { $0.id == grid.display }),
              let e = DisplayInfo.neighbour(of: d, in: displays, dx: direction.dx, dy: direction.dy),
              let entered = grids.first(where: { $0.display == displays[e].id })?.entered(moving: direction) else { return }
        selected = .window(entered)
        follow()
    }

    /// Follows model changes and apps starting and quitting while open: a window that goes, with its display or on its
    /// own, and an app that quits or gains a window in the ring leave the order, and when one was the selection, the next
    /// in the order takes its place. Returns false when no managed display is left, or nothing to offer.
    mutating func update(state: SavedState, config: Config, apps running: [SwitcherApp] = []) -> Bool {
        let grids = Self.grids(state: state, config: config)
        let windows = grids.flatMap { $0.entries.map(\.window) }
        let shelf = Self.shelf(running, state: state, windows: windows)
        let targets = windows.map(SwitcherTarget.window) + shelf.map { .app($0.pid) }
        let present = Set(targets), old = order, known = Set(old)
        let kept = old.filter(present.contains) + targets.filter { !known.contains($0) }
        // Windows stay ahead of the apps row.
        let next = kept.filter { $0.window != nil } + kept.filter { $0.app != nil }
        guard !grids.isEmpty, let first = next.first else { return false }
        if !present.contains(selected) {
            let start = old.firstIndex(of: selected) ?? 0
            selected = (1..<old.count).lazy.map { old[(start + $0) % old.count] }.first(where: present.contains) ?? first
        }
        self.grids = grids
        displays = state.displays.map(\.info)
        apps = next.compactMap { target in shelf.first { $0.pid == target.app } }
        order = next
        follow()
        return true
    }
}

/// What the switcher panel draws: the grid of the display on view, cropped around the selection, which the header
/// names, and the apps row under it.
struct SwitcherContent: Equatable {
    var area: Rect
    var pages: [[GridMiniature]]
    var shown: GridCell?
    var selected: SwitcherTarget
    /// The cell the crop centers on: the selected window's, or with an app selected, the one the selection last had.
    var cell: GridCell
    var apps: [SwitcherApp]
    var app: String
    /// The selected window's title, or what keeps the selected app's windows out of the ring.
    var title: String
    /// The display on view, named only when more than one display is managed.
    var displayName: String?
    var markers: [MonitorMarker]

    /// `names` are the displays' names by ID, as `DisplayCatalog.names` gives them.
    init(selection: SwitcherSelection, state: SavedState, names: [DisplayID: String] = [:]) {
        let grid = selection.grid
        area = grid.area
        pages = grid.pages
        shown = grid.shown
        selected = selection.selected
        cell = selection.place.cell
        apps = selection.apps
        switch selected {
        case .window(let id):
            app = state.windows[id]?.info.appName ?? ""
            title = state.windows[id]?.info.title ?? ""
        case .app(let pid):
            app = apps.first { $0.pid == pid }?.name ?? ""
            title = Self.status(of: pid, state: state)
        }
        let managed = state.displays.filter { $0.info.unmanagedReason == nil }.count
        displayName = managed > 1 ? names[grid.display] ?? "Display" : nil
        markers = MonitorMarker.markers(for: grid.display, displays: state.displays.map(\.info), names: names)
    }

    /// Why an app is in the apps row: its windows are all hidden with it or all minimized, or it has none in the grid.
    static func status(of pid: Int32, state: SavedState) -> String {
        let windows = state.windows.values.filter { $0.info.pid == pid }.map(\.info)
        if !windows.isEmpty, windows.allSatisfy(\.appHidden) { return "Hidden" }
        if !windows.isEmpty, windows.allSatisfy({ $0.minimized || $0.appHidden }) { return "Minimized" }
        return "No window in the grid"
    }

    var rows: Range<Int> {
        GridIndicatorContent.viewport(count: pages.count, selected: cell.workspace + 1, limit: GridIndicatorContent.rowLimit)
    }
    var columns: Range<Int> {
        GridIndicatorContent.viewport(count: pageCount, selected: cell.page + 1, limit: GridIndicatorContent.columnLimit)
    }
    var cropped: Bool { rows.count < pages.count || columns.count < pageCount }
    /// The row and column labels to emphasize: the selected window's. An app is on no page.
    var labeled: GridCell? { selected.window == nil ? nil : cell }
    var position: String { selected.window == nil ? "" : "Workspace \(cell.workspace + 1) / Page \(cell.page + 1)" }
    var geometry: GridIndicatorGeometry {
        GridIndicatorGeometry(area: area, rows: rows.count, columns: columns.count, cropped: cropped,
                              markers: Set(markers.map(\.side)), shelf: apps.count, metrics: .switcher)
    }

    private var pageCount: Int { pages.map(\.count).max() ?? 0 }

    /// Apps whose icons the panel needs: tiles, reserved slots and the floating tray of the drawn cells, and the apps
    /// row.
    var pids: Set<Int32> {
        let drawn = rows.flatMap { w in columns.compactMap { pages[w].indices.contains($0) ? pages[w][$0] : nil } }
        return Set(drawn.flatMap { $0.slots.map(\.pid) + $0.floaters.filter(\.active).map(\.pid) } + apps.map(\.pid))
    }
}
