import CoreGraphics
import MinitileCore

/// A tile of one of the picker's layouts.
struct DropTarget: Equatable, Hashable {
    var variant: Variant
    var slot: Int

    func command(_ window: WindowID) -> [String] { ["window", "place", String(window), variant.rawValue, String(slot)] }
}

/// Tells a move from an edge drag the way the core does at release, against the window's tile when the drag began, so
/// a Ctrl+arrow during the drag, which changes the tile, does not turn a move into a resize.
enum DragMove {
    static let tolerance = 3.0

    static func isMove(_ frame: Rect, from tile: Rect) -> Bool {
        abs(frame.width - tile.width) <= tolerance && abs(frame.height - tile.height) <= tolerance
            && (abs(frame.x - tile.x) > tolerance || abs(frame.y - tile.y) > tolerance)
    }
}

/// The layouts a dragged window's page can take, laid out in a row at the bottom centre of the page's usable area.
/// `frame` is in CG global points and `cell` and `tiles` in the panel's flipped view, so the cursor needs no conversion
/// beyond the panel's origin.
struct DropPicker: Equatable {
    static let margin: CGFloat = 12
    /// Room between the panel and the bottom of the usable area.
    static let inset: CGFloat = 12

    struct Option: Equatable {
        var variant: Variant
        /// The page's layout now, outlined as the indicator outlines the shown page.
        var current: Bool
        /// What `window place` lays out, by slot: the page's ratios for its current layout, the defaults otherwise.
        var frames: [Rect]
        var cell: CGRect
        var tiles: [CGRect]
    }

    var window: WindowID
    var pid: Int32
    var display: DisplayID
    var area: Rect
    var frame: CGRect
    var options: [Option]

    /// Nil unless the window holds an active tile on a page of two to four active tiles on a managed display.
    init?(state: SavedState, config: Config, window id: WindowID) {
        guard let window = state.windows[id], !window.floating, !window.hidden, !window.info.minimized, !window.info.appHidden,
              let display = state.displays.first(where: { $0.info.id == window.display }), display.info.unmanagedReason == nil,
              let page = display.workspaces.lazy.flatMap(\.pages).first(where: { $0.windows.contains(id) }) else { return nil }
        // Mirrors `Engine.tiled(_:activeOnly:)`.
        let count = page.windows.filter { other in
            state.windows[other].map { !$0.floating && !$0.info.minimized && !$0.info.appHidden } ?? false
        }.count
        guard (2...4).contains(count) else { return nil }
        let area = display.info.visibleFrame
        let metrics = GridMetrics.picker
        let cell = GridIndicatorGeometry.cellSize(area: area, metrics: metrics)
        let variants = Layout.variants(count: count)
        let current = Layout.effective(page.variant, count: count)
        options = variants.enumerated().map { index, variant in
            let kept = variant == current
            let frames = Layout.frames(frame: area, count: count, variant: variant, r1: kept ? page.r1 : nil, r2: kept ? page.r2 : nil,
                                       gaps: config.gaps, padding: config.padding)
            let rect = GridIndicatorGeometry.cell(row: 0, column: index, size: cell, spacing: metrics.spacing)
                .offsetBy(dx: Self.margin, dy: Self.margin)
            return Option(variant: variant, current: kept, frames: frames, cell: rect,
                          tiles: frames.map { GridIndicatorGeometry.tileRect($0, area: area, cell: rect) })
        }
        let width = 2 * Self.margin + CGFloat(variants.count) * (cell.width + metrics.spacing) - metrics.spacing
        let height = 2 * Self.margin + cell.height
        frame = CGRect(x: (area.center.x - width / 2).rounded(), y: (area.maxY - Self.inset - height).rounded(), width: width, height: height)
        self.window = id
        pid = window.info.pid
        self.display = display.info.id
        self.area = area
    }

    /// The tile under a point in CG global coordinates. Anywhere in a cell counts, the nearest tile taking the gaps
    /// between tiles, so the target does not flicker off while the cursor crosses from one tile to the next.
    func target(at point: CGPoint) -> DropTarget? {
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard let option = options.first(where: { $0.cell.contains(local) }) else { return nil }
        func distance(_ rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - local.x, 0, local.x - rect.maxX), max(rect.minY - local.y, 0, local.y - rect.maxY))
        }
        return option.tiles.indices.min { distance(option.tiles[$0]) < distance(option.tiles[$1]) }
            .map { DropTarget(variant: option.variant, slot: $0) }
    }

    /// The frame the window would get on the page.
    func preview(_ target: DropTarget) -> Rect? {
        options.first { $0.variant == target.variant }.flatMap { $0.frames.indices.contains(target.slot) ? $0.frames[target.slot] : nil }
    }
}

/// What the picker shows: its layouts with empty tiles, and the hovered tile holding the dragged window's app icon.
struct DropPickerContent: Equatable {
    var picker: DropPicker
    var hovered: DropTarget?

    /// Slot numbers stand in for window IDs, so the painter's selection marks the hovered tile.
    func miniature(_ option: DropPicker.Option) -> GridMiniature {
        GridMiniature(slots: option.frames.indices.map { slot in
            GridMiniature.Slot(window: WindowID(slot), pid: picker.pid, frame: option.frames[slot],
                               placeholder: hovered != DropTarget(variant: option.variant, slot: slot))
        })
    }

    func selected(_ option: DropPicker.Option) -> WindowID? {
        hovered.flatMap { $0.variant == option.variant ? WindowID($0.slot) : nil }
    }
}

/// What a released drag does.
enum DropRoute: Equatable {
    /// Over a picker tile: `window place` through the command path.
    case place(DropTarget)
    /// Elsewhere: the core swaps with the tile under the cursor, resizes or snaps back.
    case dragEnded(frame: Rect, cursor: Point)
    /// The window went away before the release, as a browser window dropped into another window's tab strip does.
    case ignore

    /// `frame` is nil when the window can no longer be read; `picker` and `tile` come from the drag, as the poll had them.
    static func route(frame: Rect?, cursor: Point?, picker: DropPicker?, tile: Rect?) -> DropRoute {
        guard let frame, let cursor else { return .ignore }
        if let picker, let tile, DragMove.isMove(frame, from: tile), let target = picker.target(at: CGPoint(x: cursor.x, y: cursor.y)) {
            return .place(target)
        }
        return .dragEnded(frame: frame, cursor: cursor)
    }
}
