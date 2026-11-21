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

/// What a pointer hover or click on the switcher hits.
enum SwitcherHit: Equatable {
    case target(SwitcherTarget)
    case marker(SwitcherDirection)
}

/// Where releasing a dragged window in the switcher places or swaps it.
enum SwitcherDrop: Equatable {
    case page(workspace: Int, page: Int)
    case newPage(workspace: Int, index: Int)
    case newWorkspace(index: Int)
    case swap(WindowID)
    case display(DisplayID, side: SwitcherDirection)

    func command(_ id: WindowID, display: DisplayID) -> [String] {
        switch self {
        case .page(let workspace, let page):
            ["window", "move", String(id), "display", display, "workspace", String(workspace + 1), "page", String(page + 1), "stay"]
        case .newPage(let workspace, let index):
            ["window", "move", String(id), "display", display, "workspace", String(workspace + 1), "page", "new", String(index + 1), "stay"]
        case .newWorkspace(let index):
            ["window", "move", String(id), "display", display, "workspace", "new", String(index + 1), "stay"]
        case .swap(let other):
            ["window", "swap", String(id), String(other), "stay"]
        case .display(let target, _):
            ["window", "move", String(id), "display", target, "stay"]
        }
    }
}

/// What switcher drop indices depend on, excluding window titles and selection so live title updates keep drops valid.
struct SwitcherDropLayout: Equatable {
    struct Item: Equatable {
        var window: WindowID
        var active: Bool
    }

    struct Cell: Equatable {
        var slots: [Item]
        var floaters: [Item]

        init(_ miniature: GridMiniature) {
            slots = miniature.slots.map { Item(window: $0.window, active: !$0.dimmed) }
            floaters = miniature.floaters.map { Item(window: $0.window, active: $0.active) }
        }
    }

    var display: DisplayID
    var rows: Range<Int>
    var columns: Range<Int>
    var geometry: GridIndicatorGeometry
    var markers: [MonitorMarker]
    var markerDisplays: [SwitcherDirection: DisplayID]
    var fullscreen: Set<WindowID>
    var pages: [[Cell]]
}

/// Active pointer drag overlay state on `SwitcherContent`.
struct SwitcherDrag: Equatable {
    var window: WindowID
    var pid: Int32
    var floating = false
    var point: CGPoint
    var drop: SwitcherDrop?
    var pagePreview: GridMiniature?
}

/// Where `.newPage` or `.newWorkspace` draws its lit indicator in inner coordinates.
enum SwitcherInsertionVisual: Equatable {
    case ghostCell(CGRect, GridMiniature)
    case bar(from: CGPoint, to: CGPoint)
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
    var gaps: Double
    var padding: Double
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
        gaps = config.gaps
        padding = config.padding
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
    /// The display on view, the selected window's cell, and the anchor cell its crop centers on.
    struct Place: Equatable {
        var display: DisplayID
        var selectionCell: GridCell
        var viewportCell: GridCell

        init(display: DisplayID, selectionCell: GridCell, viewportCell: GridCell? = nil) {
            self.display = display
            self.selectionCell = selectionCell
            self.viewportCell = viewportCell ?? selectionCell
        }
    }

    /// The managed displays' grids in arrangement order: by the top edges of their frames, then their left edges.
    private(set) var grids: [SwitcherGrid]
    /// Every display in the model's order, where crossing arrows look for neighbours as Ctrl+arrows do.
    private(set) var displays: [DisplayInfo]
    /// The apps row, in ring order: the running apps with none of their windows in the ring.
    private(set) var apps: [SwitcherApp]
    private(set) var order: [SwitcherTarget]
    private(set) var selected: SwitcherTarget
    /// The selected window's display and cell, with the crop anchor. An app is on no display, so while one is selected
    /// the view stays where the selection last was.
    private(set) var place: Place
    /// Where a quick Cmd+Tab, released before the panel shows, switches instead of the selection, which starts on the
    /// current window. Nil once a step or an arrow has moved the selection, and while no window is offered.
    private(set) var quick: WindowID?
    /// Opened by next rather than prev, which picks how `quick` is found.
    private let forward: Bool

    /// Next and prev both select the current window: the focused one, or with no managed window focused, the one
    /// focused last, the first in the ring when none has been; with no window, the first app. `quick` is found from it.
    /// `apps` are the running apps in the order the row keeps; `active` is the display on view when an app is selected
    /// first. Nil without a managed display, or with neither a window nor an app to offer.
    init?(state: SavedState, config: Config, apps running: [SwitcherApp] = [], forward: Bool, active: DisplayID? = nil) {
        let grids = Self.grids(state: state, config: config)
        guard let home = grids.first(where: { $0.display == active }) ?? grids.first else { return nil }
        let windows = grids.flatMap { $0.entries.map(\.window) }
        let apps = Self.shelf(running, state: state, windows: windows)
        let order = windows.map(SwitcherTarget.window) + apps.map { .app($0.pid) }
        guard let first = order.first else { return nil }
        self.grids = grids
        displays = state.displays.map(\.info)
        self.apps = apps
        self.order = order
        self.forward = forward
        let current = state.focus.flatMap { windows.contains($0) ? $0 : nil } ?? Self.latest(windows, state: state)
        selected = current.map(SwitcherTarget.window) ?? first
        quick = Self.quick(windows, from: current, state: state, forward: forward)
        let initial = home.shown ?? GridCell(workspace: 0, page: 0)
        place = Place(display: home.display, selectionCell: initial, viewportCell: initial)
        follow(recenter: true)
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

    /// The window of `windows` focused last, the first in ring order on a tie, as among windows never focused.
    private static func latest(_ windows: [WindowID], state: SavedState) -> WindowID? {
        var best: (window: WindowID, stamp: UInt64)?
        for window in windows {
            let stamp = state.windows[window]?.lastFocused ?? 0
            if best.map({ stamp > $0.stamp }) ?? true { best = (window, stamp) }
        }
        return best?.window
    }

    /// Next goes back to the window focused before `current`: the ring's other window focused last. Without one ever
    /// focused, and always for prev, it goes to the window after `current` in the ring, or before it for prev, which
    /// with a single window is `current` itself.
    private static func quick(_ windows: [WindowID], from current: WindowID?, state: SavedState, forward: Bool) -> WindowID? {
        guard let current, let index = windows.firstIndex(of: current) else { return nil }
        let focused = windows.filter { $0 != current && (state.windows[$0]?.lastFocused ?? 0) > 0 }
        if forward, let back = latest(focused, state: state) { return back }
        return windows[(index + (forward ? 1 : windows.count - 1)) % windows.count]
    }

    private static func cellExists(_ cell: GridCell, in pages: [[GridMiniature]]) -> Bool {
        pages.indices.contains(cell.workspace) && pages[cell.workspace].indices.contains(cell.page)
    }

    private static func anchorCovers(_ cell: GridCell, anchor: GridCell, pages: [[GridMiniature]]) -> Bool {
        guard cellExists(anchor, in: pages) else { return false }
        let rows = GridIndicatorContent.viewport(count: pages.count, selected: anchor.workspace + 1, limit: GridIndicatorContent.rowLimit)
        let pageCount = pages.map(\.count).max() ?? 0
        let columns = GridIndicatorContent.viewport(count: pageCount, selected: anchor.page + 1, limit: GridIndicatorContent.columnLimit)
        return rows.contains(cell.workspace) && columns.contains(cell.page)
    }

    /// The view follows a selected window. With `recenter` false, the crop anchor stays put while it still exists on the
    /// same display and covers the selection. With an app selected the view stays on a display and cell that still exist.
    private mutating func follow(recenter: Bool) {
        let oldDisplay = place.display
        let oldAnchor = place.viewportCell
        if let id = selected.window {
            for grid in grids {
                guard let entry = grid.entries.first(where: { $0.window == id }) else { continue }
                let keepAnchor = !recenter && oldDisplay == grid.display && Self.anchorCovers(entry.cell, anchor: oldAnchor, pages: grid.pages)
                place = Place(display: grid.display, selectionCell: entry.cell, viewportCell: keepAnchor ? oldAnchor : entry.cell)
                return
            }
        }
        guard let grid = grids.first(where: { $0.display == oldDisplay }) ?? grids.first else { return }
        let anchorKnown = grid.display == oldDisplay && Self.cellExists(oldAnchor, in: grid.pages)
        let selectionKnown = grid.display == oldDisplay && Self.cellExists(place.selectionCell, in: grid.pages)
        let fallback = grid.shown ?? GridCell(workspace: 0, page: 0)
        place = Place(display: grid.display,
                      selectionCell: selectionKnown ? place.selectionCell : fallback,
                      viewportCell: !recenter && anchorKnown ? oldAnchor : fallback)
    }

    /// Selects a target on the display on view without shifting its crop anchor, so pointer hover never scrolls or
    /// resizes the panel.
    mutating func select(_ target: SwitcherTarget) {
        switch target {
        case .window(let id):
            guard let entry = grid.entries.first(where: { $0.window == id }) else { return }
            if selected != target { quick = nil }
            selected = target
            place.selectionCell = entry.cell
        case .app(let pid):
            guard apps.contains(where: { $0.pid == pid }) else { return }
            if selected != target { quick = nil }
            selected = target
        }
    }

    /// Crosses the selection to the neighbour display on `side`, matching the crossing arrows.
    mutating func cross(_ side: SwitcherDirection) {
        guard let d = displays.firstIndex(where: { $0.id == grid.display }),
              let e = DisplayInfo.neighbour(of: d, in: displays, dx: side.dx, dy: side.dy),
              let entered = grids.first(where: { $0.display == displays[e].id })?.entered(moving: side) else { return }
        quick = nil
        selected = .window(entered)
        follow(recenter: true)
    }

    /// Steps through the ring, wrapping around.
    mutating func step(forward: Bool) {
        quick = nil
        guard let index = order.firstIndex(of: selected) else { return }
        let count = order.count
        selected = order[((index + (forward ? 1 : -1)) % count + count) % count]
        follow(recenter: true)
    }

    /// The nearest window center in the direction's half-plane on the display on view, as spatial focus picks on a
    /// page; grid order breaks ties. Down from a window with none below it moves to the nearest app in the apps row,
    /// and Up from an app to the nearest window; Left and Right in the row stay in it. With nothing there, the selection
    /// crosses to the managed display on that side, found as for Ctrl+arrows, when it has a window. It does not wrap.
    mutating func move(_ direction: SwitcherDirection) {
        quick = nil
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
        if let best { selected = best; follow(recenter: true); return }
        cross(direction)
    }

    /// Follows model changes and apps starting and quitting while open: a window that goes, with its display or on its
    /// own, and an app that quits or gains a window in the ring leave the order, and when one was the selection, the next
    /// in the order takes its place. With `keeping` set, as after a marker drop, the selection stays on that display's
    /// most recently focused window while one remains there. Returns false when no managed display is left, or nothing to
    /// offer.
    mutating func update(state: SavedState, config: Config, apps running: [SwitcherApp] = [], keeping: DisplayID? = nil) -> Bool {
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
        if let keeping, let id = selected.window,
           grids.first(where: { $0.display == keeping })?.entries.contains(where: { $0.window == id }) != true,
           let keptGrid = grids.first(where: { $0.display == keeping }), !keptGrid.entries.isEmpty,
           let replacement = Self.latest(keptGrid.entries.map(\.window), state: state) {
            selected = .window(replacement)
        }
        if let quick, !present.contains(.window(quick)) {
            self.quick = Self.quick(next.compactMap(\.window), from: selected.window, state: state, forward: forward)
        }
        self.grids = grids
        displays = state.displays.map(\.info)
        apps = next.compactMap { target in shelf.first { $0.pid == target.app } }
        order = next
        follow(recenter: false)
        return true
    }
}

/// What the switcher panel draws: the grid of the display on view, cropped around `viewportCell`, with the header
/// naming `selected` and the apps row under it.
struct SwitcherContent: Equatable {
    var display: DisplayID
    var area: Rect
    var gaps: Double = Config.default.gaps
    var padding: Double = Config.default.padding
    var pages: [[GridMiniature]]
    var shown: GridCell?
    var selected: SwitcherTarget
    var selectionCell: GridCell
    /// The cell the crop centers on.
    var viewportCell: GridCell
    var apps: [SwitcherApp]
    var app: String
    /// The selected window's title, or what keeps the selected app's windows out of the ring.
    var title: String
    /// The display on view, named only when more than one display is managed.
    var displayName: String?
    var markers: [MonitorMarker]
    var markerDisplays: [SwitcherDirection: DisplayID] = [:]
    var fullscreen: Set<WindowID> = []
    var drag: SwitcherDrag? = nil

    /// `names` are the displays' names by ID, as `DisplayCatalog.names` gives them.
    init(selection: SwitcherSelection, state: SavedState, names: [DisplayID: String] = [:], drag: SwitcherDrag? = nil) {
        let grid = selection.grid
        display = grid.display
        area = grid.area
        gaps = grid.gaps
        padding = grid.padding
        pages = grid.pages
        shown = grid.shown
        selected = selection.selected
        selectionCell = selection.place.selectionCell
        viewportCell = selection.place.viewportCell
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
        let infos = state.displays.map(\.info)
        markers = MonitorMarker.markers(for: grid.display, displays: infos, names: names)
        if let d = infos.firstIndex(where: { $0.id == grid.display }) {
            markerDisplays = Dictionary(uniqueKeysWithValues: SwitcherDirection.allCases.compactMap { side in
                DisplayInfo.neighbour(of: d, in: infos, dx: side.dx, dy: side.dy).map { (side, infos[$0].id) }
            })
        }
        fullscreen = Set(state.windows.values.filter(\.info.fullscreen).map(\.info.id))
        self.drag = drag
    }

    /// Why an app is in the apps row: its windows are all hidden with it or all minimized, or it has none in the grid.
    static func status(of pid: Int32, state: SavedState) -> String {
        let windows = state.windows.values.filter { $0.info.pid == pid }.map(\.info)
        if !windows.isEmpty, windows.allSatisfy(\.appHidden) { return "Hidden" }
        if !windows.isEmpty, windows.allSatisfy({ $0.minimized || $0.appHidden }) { return "Minimized" }
        return "No window in the grid"
    }

    var rows: Range<Int> {
        GridIndicatorContent.viewport(count: pages.count, selected: viewportCell.workspace + 1, limit: GridIndicatorContent.rowLimit)
    }
    var columns: Range<Int> {
        GridIndicatorContent.viewport(count: pageCount, selected: viewportCell.page + 1, limit: GridIndicatorContent.columnLimit)
    }
    var cropped: Bool { rows.count < pages.count || columns.count < pageCount }
    /// The row and column labels to emphasize: the selected window's. An app is on no page.
    var labeled: GridCell? { selected.window == nil ? nil : selectionCell }
    var position: String { selected.window == nil ? "" : "Workspace \(selectionCell.workspace + 1) / Page \(selectionCell.page + 1)" }
    var geometry: GridIndicatorGeometry {
        GridIndicatorGeometry(area: area, rows: rows.count, columns: columns.count, cropped: cropped,
                              markers: Set(markers.map(\.side)), shelf: apps.count, metrics: .switcher)
    }
    var dropLayout: SwitcherDropLayout {
        SwitcherDropLayout(display: display, rows: rows, columns: columns, geometry: geometry, markers: markers,
                           markerDisplays: markerDisplays, fullscreen: fullscreen, pages: pages.map { $0.map(SwitcherDropLayout.Cell.init) })
    }

    private var pageCount: Int { pages.map(\.count).max() ?? 0 }

    /// Apps whose icons the panel needs: tiles, reserved slots and the floating tray of the drawn cells, the apps row,
    /// and a dragged window.
    var pids: Set<Int32> {
        let drawn = rows.flatMap { w in columns.compactMap { pages[w].indices.contains($0) ? pages[w][$0] : nil } }
        let dragPids = (drag.map { [$0.pid] } ?? []) + (drag?.pagePreview?.slots.map(\.pid) ?? []) + (drag?.pagePreview?.floaters.map(\.pid) ?? [])
        return Set(drawn.flatMap { $0.slots.map(\.pid) + $0.floaters.filter(\.active).map(\.pid) } + apps.map(\.pid) + dragPids)
    }

    /// A monitor marker's band in flipped panel coordinates. Top and bottom span the full width; left and right span
    /// between them so corners resolve to top or bottom.
    func markerBandRect(_ side: SwitcherDirection) -> CGRect? {
        let g = geometry, size = g.size
        guard g.markers.contains(side) else { return nil }
        let top = g.band(.up), bottom = g.band(.down)
        return switch side {
        case .up: CGRect(x: 0, y: 0, width: size.width, height: top)
        case .down: CGRect(x: 0, y: size.height - bottom, width: size.width, height: bottom)
        case .left: CGRect(x: 0, y: top, width: g.band(.left), height: max(0, size.height - top - bottom))
        case .right: CGRect(x: size.width - g.band(.right), y: top, width: g.band(.right), height: max(0, size.height - top - bottom))
        }
    }

    /// Hit-tests a point in flipped panel coordinates for hover and click.
    func target(at point: CGPoint) -> SwitcherHit? {
        let g = geometry
        guard CGRect(origin: .zero, size: g.size).contains(point) else { return nil }
        for side in SwitcherDirection.allCases {
            if let rect = markerBandRect(side), rect.contains(point) { return .marker(side) }
        }
        let inner = CGPoint(x: point.x - g.inset.x, y: point.y - g.inset.y)
        let s = g.metrics.scale
        for (r, workspace) in rows.enumerated() where pages.indices.contains(workspace) {
            for (c, page) in columns.enumerated() where pages[workspace].indices.contains(page) {
                let miniature = pages[workspace][page]
                let cell = g.cellRect(row: r, column: c)
                let floaters = miniature.floaters.filter(\.active)
                let tray = GridIndicatorGeometry.trayRects(count: floaters.count, cell: cell, metrics: g.metrics)
                for (floater, rect) in zip(floaters, tray) where rect.insetBy(dx: -1.5 * s, dy: -1.5 * s).contains(inner) {
                    return .target(.window(floater.window))
                }
                if cell.contains(inner) {
                    for tile in miniature.tiles {
                        if let frame = tile.frame, GridIndicatorGeometry.tileRect(frame, area: area, cell: cell).contains(inner) {
                            return .target(.window(tile.window))
                        }
                    }
                }
            }
        }
        for (app, rect) in zip(apps, g.shelfRects) where rect.contains(inner) {
            return .target(.app(app.pid))
        }
        return nil
    }

    /// Hit-tests a point in flipped panel coordinates for dropping `id` during a drag.
    func dropTarget(at point: CGPoint, dragging id: WindowID, floating: Bool) -> SwitcherDrop? {
        let g = geometry
        let panelBounds = CGRect(origin: .zero, size: g.size)
        guard !rows.isEmpty, !fullscreen.contains(id), panelBounds.insetBy(dx: -60, dy: -60).contains(point),
              let source = sourceCell(of: id) else { return nil }
        let clamped = CGPoint(x: min(max(point.x, 0), max(0, g.size.width - 0.001)),
                              y: min(max(point.y, 0), max(0, g.size.height - 0.001)))
        for side in SwitcherDirection.allCases {
            if let rect = markerBandRect(side), rect.contains(clamped), let targetDisplay = markerDisplays[side] {
                return .display(targetDisplay, side: side)
            }
        }
        let inner = CGPoint(x: point.x - g.inset.x, y: point.y - g.inset.y)
        let s = g.metrics.scale
        let edgeBandX = 6 * s, edgeBandY = 6 * s
        guard inner.y >= g.gridTop - 12 * s else { return nil }

        let candidate: SwitcherDrop?
        let lastR = rows.count - 1
        if inner.y < g.cellRect(row: 0, column: 0).minY + edgeBandY {
            candidate = .newWorkspace(index: rows.lowerBound)
        } else if inner.y > g.cellRect(row: lastR, column: 0).maxY - edgeBandY {
            candidate = .newWorkspace(index: min(pages.count, rows.upperBound))
        } else if let gapRow = (1..<rows.count).first(where: { r in
            inner.y > g.cellRect(row: r - 1, column: 0).maxY - edgeBandY && inner.y < g.cellRect(row: r, column: 0).minY + edgeBandY
        }) {
            candidate = .newWorkspace(index: rows.lowerBound + gapRow)
        } else if let r = (0..<rows.count).first(where: { r in
            let rect = g.cellRect(row: r, column: 0)
            return inner.y >= rect.minY + edgeBandY && inner.y <= rect.maxY - edgeBandY
        }) {
            let workspace = rows.lowerBound + r
            guard pages.indices.contains(workspace) else { return nil }
            let rowPageCount = pages[workspace].count
            let drawnCount = columns.filter { pages[workspace].indices.contains($0) }.count
            if drawnCount == 0 {
                candidate = .newPage(workspace: workspace, index: rowPageCount)
            } else {
                let lastC = drawnCount - 1
                if inner.x < g.cellRect(row: r, column: 0).minX + edgeBandX {
                    candidate = .newPage(workspace: workspace, index: min(columns.lowerBound, rowPageCount))
                } else if let gapCol = (1..<drawnCount).first(where: { c in
                    inner.x > g.cellRect(row: r, column: c - 1).maxX - edgeBandX && inner.x < g.cellRect(row: r, column: c).minX + edgeBandX
                }) {
                    candidate = .newPage(workspace: workspace, index: min(columns.lowerBound + gapCol, rowPageCount))
                } else if inner.x > g.cellRect(row: r, column: lastC).maxX - edgeBandX {
                    candidate = .newPage(workspace: workspace, index: min(columns.lowerBound + lastC + 1, rowPageCount))
                } else if let c = (0..<drawnCount).first(where: { c in
                    let rect = g.cellRect(row: r, column: c)
                    return inner.x >= rect.minX + edgeBandX && inner.x <= rect.maxX - edgeBandX
                }) {
                    let page = columns.lowerBound + c
                    let miniature = pages[workspace][page]
                    let cell = g.cellRect(row: r, column: c)
                    let picked = nearestTile(at: inner, miniature: miniature, cell: cell)
                    if GridCell(workspace: workspace, page: page) == source {
                        if !floating, let other = picked, other != id, !fullscreen.contains(other) {
                            candidate = .swap(other)
                        } else {
                            candidate = nil
                        }
                    } else if miniatureContainsFullscreen(miniature) {
                        candidate = nil
                    } else if floating || miniature.slots.count < 4 {
                        candidate = .page(workspace: workspace, page: page)
                    } else if !floating, let other = picked, !fullscreen.contains(other) {
                        candidate = .swap(other)
                    } else {
                        candidate = nil
                    }
                } else {
                    candidate = nil
                }
            }
        } else {
            candidate = nil
        }

        guard let candidate else { return nil }
        if isLoneNoOp(candidate, id: id, source: source) { return nil }
        return candidate
    }

    /// Geometry in inner coordinates for `.newPage` and `.newWorkspace` drop indicators.
    func insertionVisual(for drop: SwitcherDrop, drag: SwitcherDrag, geometry g: GridIndicatorGeometry) -> SwitcherInsertionVisual? {
        let s = g.metrics.scale
        switch drop {
        case .newPage(let workspace, let index):
            guard rows.contains(workspace), pages.indices.contains(workspace) else { return nil }
            let r = workspace - rows.lowerBound
            let drawnCount = columns.filter { pages[workspace].indices.contains($0) }.count
            if drawnCount > 0 {
                let lastC = drawnCount - 1
                if lastC + 1 < columns.count, index == pages[workspace].count {
                    let ghost = g.cellRect(row: r, column: lastC + 1)
                    let miniature: GridMiniature
                    if drag.floating {
                        miniature = GridMiniature(floaters: [GridMiniature.Floater(window: drag.window, pid: drag.pid, active: true)])
                    } else {
                        let frame = Layout.frames(frame: area, count: 1, gaps: gaps, padding: padding).first
                        miniature = GridMiniature(slots: [GridMiniature.Slot(window: drag.window, pid: drag.pid, frame: frame)])
                    }
                    return .ghostCell(ghost, miniature)
                }
            }
            let rowCell = g.cellRect(row: r, column: 0)
            let x: CGFloat
            if drawnCount == 0 || index <= columns.lowerBound {
                x = rowCell.minX - 4 * s
            } else if index - columns.lowerBound < drawnCount {
                let c = index - columns.lowerBound
                x = (g.cellRect(row: r, column: c - 1).maxX + g.cellRect(row: r, column: c).minX) / 2
            } else {
                x = g.cellRect(row: r, column: drawnCount - 1).maxX + min(g.metrics.spacing / 2, g.margin / 2)
            }
            return .bar(from: CGPoint(x: x, y: rowCell.minY), to: CGPoint(x: x, y: rowCell.maxY))
        case .newWorkspace(let index):
            guard !rows.isEmpty, !columns.isEmpty else { return nil }
            let firstCell = g.cellRect(row: 0, column: 0)
            let lastColCell = g.cellRect(row: 0, column: columns.count - 1)
            let y: CGFloat
            if index <= rows.lowerBound {
                y = firstCell.minY - g.metrics.labelGap / 2
            } else if index - rows.lowerBound < rows.count {
                let r = index - rows.lowerBound
                y = (g.cellRect(row: r - 1, column: 0).maxY + g.cellRect(row: r, column: 0).minY) / 2
            } else {
                let lastRowCell = g.cellRect(row: rows.count - 1, column: 0)
                y = lastRowCell.maxY + min(g.metrics.spacing / 2, g.margin / 2)
            }
            return .bar(from: CGPoint(x: firstCell.minX, y: y), to: CGPoint(x: lastColCell.maxX, y: y))
        default:
            return nil
        }
    }

    private func sourceCell(of id: WindowID) -> GridCell? {
        for (w, row) in pages.enumerated() {
            for (p, miniature) in row.enumerated() {
                if miniature.slots.contains(where: { $0.window == id }) || miniature.floaters.contains(where: { $0.window == id }) {
                    return GridCell(workspace: w, page: p)
                }
            }
        }
        return nil
    }

    private func miniatureContainsFullscreen(_ miniature: GridMiniature) -> Bool {
        miniature.slots.contains { fullscreen.contains($0.window) } || miniature.floaters.contains { fullscreen.contains($0.window) }
    }

    private func nearestTile(at inner: CGPoint, miniature: GridMiniature, cell: CGRect) -> WindowID? {
        func distance(_ rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - inner.x, 0, inner.x - rect.maxX), max(rect.minY - inner.y, 0, inner.y - rect.maxY))
        }
        let placed = miniature.tiles.compactMap { slot in
            slot.frame.map { (window: slot.window, rect: GridIndicatorGeometry.tileRect($0, area: area, cell: cell)) }
        }
        return placed.min { distance($0.rect) < distance($1.rect) }?.window
    }

    private func isLoneNoOp(_ drop: SwitcherDrop, id: WindowID, source: GridCell) -> Bool {
        let pageMiniature = pages[source.workspace][source.page]
        let pageWindows = pageMiniature.slots.map(\.window) + pageMiniature.floaters.map(\.window)
        guard pageWindows == [id] else { return false }
        switch drop {
        case .newPage(let w, let index):
            return w == source.workspace && (index == source.page || index == source.page + 1)
        case .newWorkspace(let index):
            let workspaceWindows = pages[source.workspace].flatMap { $0.slots.map(\.window) + $0.floaters.map(\.window) }
            return workspaceWindows == [id] && (index == source.workspace || index == source.workspace + 1)
        default:
            return false
        }
    }
}
