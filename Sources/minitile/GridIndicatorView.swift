import AppKit
import MinitileCore

/// The sizes that differ between the position indicator, the window switcher and the drop picker, which draw the same
/// miniatures. Lengths are in points; strokes and their glow are not part of them, so lines stay hairlines at any scale.
struct GridMetrics: Equatable {
    /// Text, margins, labels and corner radii, relative to the drop picker's size.
    var scale: CGFloat = 1
    var cellArea: CGFloat
    var spacing: CGFloat
    /// Room between the column labels and the first row, which the switcher's floating tray reaches into.
    var labelGap: CGFloat
    var minWidth: CGFloat
    var icon: ClosedRange<CGFloat>
    var reservedIcon: CGFloat
    /// Floating windows as a tray of selectable icons on the cell's top edge; nil draws a count badge.
    var trayIcon: CGFloat?

    static let indicator = GridMetrics(scale: 2, cellArea: 128 * 80, spacing: 12, labelGap: 4, minWidth: 440, icon: 20...28,
                                       reservedIcon: 20, trayIcon: nil)
    static let switcher = GridMetrics(scale: 2, cellArea: 256 * 160, spacing: 24, labelGap: 24, minWidth: 600, icon: 32...64,
                                      reservedIcon: 28, trayIcon: 32)
    /// Half the switcher's size, in a single row without labels; its tiles are the drop targets.
    static let picker = GridMetrics(cellArea: 128 * 80, spacing: 12, labelGap: 0, minWidth: 0, icon: 16...32,
                                    reservedIcon: 14, trayIcon: nil)

    /// Every length times `factor`, so the cell area times its square. Icons stay on whole points.
    func scaled(_ factor: CGFloat) -> GridMetrics {
        func whole(_ value: CGFloat) -> CGFloat { (value * factor).rounded(.down) }
        return GridMetrics(scale: scale * factor, cellArea: cellArea * factor * factor, spacing: spacing * factor,
                           labelGap: labelGap * factor, minWidth: minWidth * factor, icon: whole(icon.lowerBound)...whole(icon.upperBound),
                           reservedIcon: whole(reservedIcon), trayIcon: trayIcon.map(whole))
    }

    /// Scaled down uniformly, never up, to about the largest `size` that fits `room`; with no room at all the metrics
    /// stay as they are.
    func fitted(to room: CGSize, size: (GridMetrics) -> CGSize) -> GridMetrics {
        func fits(_ size: CGSize) -> Bool { size.width <= room.width && size.height <= room.height }
        guard room.width > 0, room.height > 0, !fits(size(self)) else { return self }
        // Cells round to whole points, so the size is not quite proportional to the factor: search for it.
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if fits(size(scaled(middle))) { low = middle } else { high = middle }
        }
        return scaled(low)
    }
}

/// Panel layout in flipped view coordinates, sized from the number of drawn cells and scaled down to fit the usable
/// area less `PanelStyle.inset` on each side. The header, labels, cells and footer form the inner layout, which sits at
/// `inset` in the panel, past the bands that hold monitor markers.
struct GridIndicatorGeometry: Equatable {
    var metrics: GridMetrics
    var cell: CGSize
    var rows: Int
    var columns: Int
    var cropped: Bool
    var warning: Bool
    /// Edges with a monitor marker, each in a band the panel adds on that side.
    var markers: Set<SwitcherDirection>

    init(content: GridIndicatorContent) {
        self.init(area: content.area, rows: content.rows.count, columns: content.columns.count, cropped: content.cropped,
                  warning: content.warning != nil, markers: Set(content.markers.map(\.side)), metrics: .indicator)
    }

    init(area: Rect, rows: Int, columns: Int, cropped: Bool, warning: Bool = false, markers: Set<SwitcherDirection> = [],
         metrics: GridMetrics) {
        func layout(_ metrics: GridMetrics) -> GridIndicatorGeometry {
            GridIndicatorGeometry(metrics: metrics, cell: Self.cellSize(area: area, metrics: metrics), rows: rows, columns: columns,
                                  cropped: cropped, warning: warning, markers: markers)
        }
        let room = CGSize(width: area.width - 2 * PanelStyle.inset, height: area.height - 2 * PanelStyle.inset)
        self = layout(metrics.fitted(to: room) { layout($0).size })
    }

    private init(metrics: GridMetrics, cell: CGSize, rows: Int, columns: Int, cropped: Bool, warning: Bool,
                 markers: Set<SwitcherDirection>) {
        self.metrics = metrics
        self.cell = cell
        self.rows = rows
        self.columns = columns
        self.cropped = cropped
        self.warning = warning
        self.markers = markers
    }

    /// Constant area in the display's proportions, so portrait displays get tall cells and wide ones stay legible.
    static func cellSize(area: Rect, metrics: GridMetrics = .indicator) -> CGSize {
        let aspect = area.width > 0 && area.height > 0 ? min(3, max(1.0 / 3, area.width / area.height)) : 1.6
        return CGSize(width: (metrics.cellArea * aspect).squareRoot().rounded(), height: (metrics.cellArea / aspect).squareRoot().rounded())
    }

    /// A cell of a grid whose first cell sits at the origin; `cellRect` shifts it past the labels.
    static func cell(row: Int, column: Int, size: CGSize, spacing: CGFloat) -> CGRect {
        CGRect(x: CGFloat(column) * (size.width + spacing), y: CGFloat(row) * (size.height + spacing), width: size.width, height: size.height)
    }

    var margin: CGFloat { 12 * metrics.scale }
    var labelWidth: CGFloat { 22 * metrics.scale }
    var gridTop: CGFloat { 50 * metrics.scale }
    var labelHeight: CGFloat { 14 * metrics.scale }
    var footerHeight: CGFloat { 14 * metrics.scale }

    var origin: CGPoint { CGPoint(x: margin + labelWidth + 4 * metrics.scale, y: gridTop + labelHeight + metrics.labelGap) }

    /// The inner layout's size, without the marker bands.
    var inner: CGSize {
        if warning { return CGSize(width: metrics.minWidth + 28 * metrics.scale, height: 116 * metrics.scale) }
        let width = origin.x + span(columns, cell.width) + margin
        let height = origin.y + span(rows, cell.height) + (cropped ? metrics.spacing + footerHeight : 0) + margin
        return CGSize(width: max(metrics.minWidth, width), height: height)
    }

    var size: CGSize {
        CGSize(width: inner.width + band(.left) + band(.right), height: inner.height + band(.up) + band(.down))
    }

    /// Where the inner layout's origin sits in the panel.
    var inset: CGPoint { CGPoint(x: band(.left), y: band(.up)) }

    /// How far the panel reaches past the inner layout on `side` to hold a marker there: a marker's row on the top
    /// and bottom edges, and on the sides room for the name under the screen outline.
    func band(_ side: SwitcherDirection) -> CGFloat {
        guard markers.contains(side) else { return 0 }
        return (side == .up || side == .down ? 24 : 56) * metrics.scale
    }

    /// A monitor marker's parts in panel coordinates: the screen outline with its stand, centered on the edge; the
    /// chevron between it and the edge; and the name, right of the outline on the top and bottom edges and centered
    /// under it on the sides, where the band is narrow.
    func marker(_ side: SwitcherDirection) -> (screen: CGRect, chevron: CGRect, name: CGRect) {
        let s = metrics.scale, size = size, glyph = CGSize(width: 16 * s, height: 12 * s)
        func whole(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
        }
        let screen: CGRect, chevron: CGRect, name: CGRect
        switch side {
        case .up, .down:
            let top = side == .up ? 10 * s : size.height - band(.down) + 2 * s
            screen = whole(CGRect(x: (size.width - glyph.width) / 2, y: top, width: glyph.width, height: glyph.height))
            // Below, the stand's base is nearest the chevron, so it keeps a little more room.
            chevron = whole(CGRect(x: screen.midX - 4 * s, y: side == .up ? screen.minY - 6 * s : screen.maxY + 3 * s, width: 8 * s,
                                   height: 4 * s))
            name = CGRect(x: screen.maxX + 4 * s, y: screen.minY - 1.5 * s, width: max(0, size.width - margin - screen.maxX - 4 * s),
                          height: 12 * s)
        case .left, .right:
            // The chevron, a 2 pt gap and the outline, 22 pt at scale 1, centered in the band.
            let edge = side == .left ? 0 : size.width - band(.right)
            screen = whole(CGRect(x: edge + (side == .left ? 23 : 17) * s, y: size.height / 2 - 6 * s, width: glyph.width,
                                  height: glyph.height))
            chevron = whole(CGRect(x: side == .left ? screen.minX - 6 * s : screen.maxX + 2 * s, y: screen.minY + 0.5 * s,
                                   width: 4 * s, height: 8 * s))
            name = CGRect(x: edge + 2 * s, y: screen.maxY + 3 * s, width: 52 * s, height: 12 * s)
        }
        return (screen, chevron, name)
    }

    private func span(_ count: Int, _ length: CGFloat) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * (length + metrics.spacing) - metrics.spacing
    }

    func cellRect(row: Int, column: Int) -> CGRect {
        Self.cell(row: row, column: column, size: cell, spacing: metrics.spacing).offsetBy(dx: origin.x, dy: origin.y)
    }

    func rowLabelRect(row: Int) -> CGRect {
        let s = metrics.scale
        return CGRect(x: margin - 2 * s, y: cellRect(row: row, column: 0).midY - 7 * s, width: labelWidth + 4 * s, height: 14 * s)
    }

    func columnLabelRect(column: Int) -> CGRect {
        let cell = cellRect(row: 0, column: column)
        return CGRect(x: cell.minX, y: gridTop, width: cell.width, height: labelHeight)
    }

    var footerRect: CGRect {
        CGRect(x: margin, y: inner.height - margin - footerHeight, width: inner.width - 2 * margin, height: footerHeight)
    }

    /// The page's usable area inside a cell, inset so tiles clear the cell outline.
    static func screenRect(cell: CGRect) -> CGRect { cell.insetBy(dx: 2, dy: 2) }

    /// Scales a core frame into the cell on half-point edges. The inset keeps tiles apart where scaled gaps vanish.
    static func tileRect(_ frame: Rect, area: Rect, cell: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return .zero }
        let screen = screenRect(cell: cell)
        let sx = screen.width / area.width, sy = screen.height / area.height
        func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
        let x0 = half(screen.minX + (frame.x - area.x) * sx), x1 = half(screen.minX + (frame.maxX - area.x) * sx)
        let y0 = half(screen.minY + (frame.y - area.y) * sy), y1 = half(screen.minY + (frame.maxY - area.y) * sy)
        let rect = CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
        return rect.insetBy(dx: min(0.5, rect.width / 2), dy: min(0.5, rect.height / 2))
    }

    /// Within `range` (20-28 pt in the indicator), never larger than the tile.
    static func iconRect(tile: CGRect, range: ClosedRange<CGFloat> = GridMetrics.indicator.icon) -> CGRect {
        let short = min(tile.width, tile.height)
        let side = max(0, min(range.upperBound, max(range.lowerBound, (short * 0.75).rounded(.down)), short.rounded(.down)))
        return CGRect(x: ((tile.midX - side / 2) * 2).rounded() / 2, y: ((tile.midY - side / 2) * 2).rounded() / 2, width: side, height: side)
    }

    /// Reserved slots have no tile, so their icons sit in a row along the cell's bottom-left corner.
    static func reservedRects(count: Int, cell: CGRect, metrics: GridMetrics) -> [CGRect] {
        let screen = screenRect(cell: cell), side = metrics.reservedIcon, s = metrics.scale
        return (0..<count).map { CGRect(x: screen.minX + s + CGFloat($0) * (side + s), y: screen.maxY - s - side, width: side, height: side) }
    }

    /// Straddles the cell's top-right corner, so it covers as little of the tiles as possible.
    static func badgeRect(count: Int, cell: CGRect, metrics: GridMetrics) -> CGRect {
        let s = metrics.scale, width = max(12, 6 + 6 * CGFloat(String(count).count)) * s
        return CGRect(x: cell.maxX - width + 3 * s, y: cell.minY - 3 * s, width: width, height: 12 * s)
    }

    /// Centered on the cell's top edge and right-aligned, where the indicator's badge sits, so it covers little of the
    /// tiles. Icons shrink when the row would not fit the cell.
    static func trayRects(count: Int, cell: CGRect, metrics: GridMetrics) -> [CGRect] {
        guard count > 0, let side = metrics.trayIcon else { return [] }
        let s = metrics.scale, gap = 2 * s, room = cell.width - 8 * s
        let size = max(4 * s, min(side, ((room - CGFloat(count - 1) * gap) / CGFloat(count)).rounded(.down)))
        let first = cell.maxX - 4 * s - CGFloat(count) * size - CGFloat(count - 1) * gap
        return (0..<count).map { CGRect(x: first + CGFloat($0) * (size + gap), y: cell.minY - size / 2, width: size, height: size) }
    }
}

/// Draws labels and page miniatures in the wireframe style, for the position indicator, the window switcher and the
/// drop picker alike.
@MainActor
struct GridPainter {
    var area: Rect
    var metrics: GridMetrics
    var icons: [Int32: NSImage]

    /// `labeled` picks the row and column labels to emphasize, `current` the cell outlined as the shown page.
    func grid(_ pages: [[GridMiniature]], rows: Range<Int>, columns: Range<Int>, geometry: GridIndicatorGeometry,
              labeled: GridCell?, current: GridCell?, selected: WindowID? = nil) {
        let size = 10 * metrics.scale
        for (column, page) in columns.enumerated() {
            Self.label("P\(page + 1)", rect: geometry.columnLabelRect(column: column), size: size, current: labeled?.page == page)
        }
        for (row, workspace) in rows.enumerated() {
            Self.label("W\(workspace + 1)", rect: geometry.rowLabelRect(row: row), size: size, current: labeled?.workspace == workspace)
            for (column, page) in columns.enumerated() {
                guard pages.indices.contains(workspace), pages[workspace].indices.contains(page) else { continue }
                draw(pages[workspace][page], in: geometry.cellRect(row: row, column: column),
                     current: current == GridCell(workspace: workspace, page: page), selected: selected)
            }
        }
    }

    /// The focused tile and the selected one are highlighted; their icons alone are drawn at full opacity.
    func draw(_ miniature: GridMiniature, in cell: NSRect, current: Bool, selected: WindowID? = nil) {
        let s = metrics.scale
        for tile in miniature.tiles {
            guard let frame = tile.frame else { continue }
            let rect = GridIndicatorGeometry.tileRect(frame, area: area, cell: cell)
            let highlighted = tile.focused || tile.window == selected
            Self.plate(rect, radius: PanelStyle.tileRadius * s, fill: highlighted ? PanelStyle.highlightFill : PanelStyle.tileFill,
                       stroke: highlighted ? PanelStyle.highlight : PanelStyle.tile)
            if !tile.placeholder {
                icon(tile.pid, in: GridIndicatorGeometry.iconRect(tile: rect, range: metrics.icon),
                     fraction: highlighted ? 1 : PanelStyle.iconOpacity)
            }
        }
        let reserved = GridIndicatorGeometry.reservedRects(count: miniature.reserved.count, cell: cell, metrics: metrics)
        if let first = reserved.first, let last = reserved.last {
            Self.plate(first.union(last).insetBy(dx: -s, dy: -s), radius: 2 * s, fill: PanelStyle.plateFill, stroke: PanelStyle.plate)
            for (slot, rect) in zip(miniature.reserved, reserved) { icon(slot.pid, in: rect, fraction: PanelStyle.reservedOpacity) }
        }
        let outline = current ? PanelStyle.shownPage : miniature.empty ? PanelStyle.emptyPage : PanelStyle.page
        outline.draw(inside: cell, radius: PanelStyle.pageRadius * s)
        if metrics.trayIcon != nil { tray(miniature.floaters.filter(\.active), cell: cell, selected: selected) }
        else if miniature.floating > 0 { badge(miniature.floating, cell: cell) }
    }

    private func badge(_ count: Int, cell: NSRect) {
        let badge = GridIndicatorGeometry.badgeRect(count: count, cell: cell, metrics: metrics)
        Self.plate(badge, radius: badge.height / 2, fill: PanelStyle.plateFill, stroke: PanelStyle.plate)
        // Digits are as tall as capitals, so the baseline sits half a cap height below the badge's middle.
        let size = 9 * metrics.scale, font = PanelStyle.font(size: size, weight: .medium, monospaced: true)
        let line = NSRect(x: badge.minX, y: badge.midY + font.capHeight / 2 - font.ascender, width: badge.width,
                          height: font.ascender - font.descender)
        Self.text(String(count), rect: line, size: size, weight: .medium, color: PanelStyle.dim, alignment: .center, monospaced: true)
    }

    private func tray(_ floaters: [GridMiniature.Floater], cell: NSRect, selected: WindowID?) {
        let s = metrics.scale
        let rects = GridIndicatorGeometry.trayRects(count: floaters.count, cell: cell, metrics: metrics)
        guard let first = rects.first, let last = rects.last else { return }
        Self.plate(first.union(last).insetBy(dx: -2 * s, dy: -2 * s), radius: 4 * s, fill: PanelStyle.plateFill, stroke: PanelStyle.plate)
        for (floater, rect) in zip(floaters, rects) {
            let chosen = floater.window == selected
            if chosen {
                Self.plate(rect.insetBy(dx: -1.5 * s, dy: -1.5 * s), radius: 3 * s, fill: PanelStyle.highlightFill, stroke: PanelStyle.highlight)
            }
            icon(floater.pid, in: rect, fraction: chosen ? 1 : PanelStyle.iconOpacity)
        }
    }

    private func icon(_ pid: Int32, in rect: NSRect, fraction: CGFloat) {
        guard rect.width > 0 else { return }
        if let image = icons[pid] {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true,
                       hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        } else {
            PanelStyle.wire.opacity(0.5 * fraction).color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
        }
    }

    static func plate(_ rect: NSRect, radius: CGFloat, fill: Paint, stroke: Stroke) {
        fill.color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        stroke.draw(inside: rect, radius: radius)
    }

    /// The tint and border over a panel's blurred backdrop.
    static func background(_ bounds: NSRect) {
        plate(bounds, radius: PanelStyle.radius, fill: PanelStyle.tint, stroke: PanelStyle.border)
    }

    /// A monitor marker in unlit wire, since it shows where Ctrl+arrows cross rather than state: a small screen on a
    /// stand, a chevron pointing out of the panel, and the display's name in dim monospace.
    static func marker(_ marker: MonitorMarker, geometry: GridIndicatorGeometry) {
        let s = geometry.metrics.scale, parts = geometry.marker(marker.side), stroke = PanelStyle.marker
        let glyph = parts.screen, screen = NSRect(x: glyph.minX, y: glyph.minY, width: glyph.width, height: (9 * s).rounded())
        stroke.draw(inside: screen, radius: 1.5 * s)
        let base = glyph.maxY - stroke.width / 2, stand = NSBezierPath()
        stand.move(to: NSPoint(x: glyph.midX, y: screen.maxY))
        stand.line(to: NSPoint(x: glyph.midX, y: base))
        stand.move(to: NSPoint(x: glyph.midX - 3.5 * s, y: base))
        stand.line(to: NSPoint(x: glyph.midX + 3.5 * s, y: base))
        stroke.draw(stand)
        let c = parts.chevron
        let points = switch marker.side {
        case .up: [NSPoint(x: c.minX, y: c.maxY), NSPoint(x: c.midX, y: c.minY), NSPoint(x: c.maxX, y: c.maxY)]
        case .down: [NSPoint(x: c.minX, y: c.minY), NSPoint(x: c.midX, y: c.maxY), NSPoint(x: c.maxX, y: c.minY)]
        case .left: [NSPoint(x: c.maxX, y: c.minY), NSPoint(x: c.minX, y: c.midY), NSPoint(x: c.maxX, y: c.maxY)]
        case .right: [NSPoint(x: c.minX, y: c.minY), NSPoint(x: c.maxX, y: c.midY), NSPoint(x: c.minX, y: c.maxY)]
        }
        let chevron = NSBezierPath()
        chevron.move(to: points[0])
        points.dropFirst().forEach(chevron.line(to:))
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        stroke.draw(chevron)
        let sideways = marker.side == .left || marker.side == .right
        text(marker.name, rect: parts.name, size: 9 * s, color: PanelStyle.dim, alignment: sideways ? .center : .left, monospaced: true)
    }

    /// Draws `inner` with the inner layout's origin at `inset`, past the marker bands on the left and top.
    static func inner(at inset: CGPoint, _ inner: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.translateBy(x: inset.x, y: inset.y)
        inner()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func label(_ string: String, rect: NSRect, size: CGFloat, current: Bool) {
        text(string, rect: rect, size: size, weight: current ? .semibold : .regular, color: current ? PanelStyle.ink : PanelStyle.dim,
             alignment: .center, monospaced: true)
    }

    static func text(_ string: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: Paint = PanelStyle.ink,
                     alignment: NSTextAlignment = .left, wrap: Bool = false, monospaced: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        let text = NSAttributedString(string: string, attributes: [
            .font: PanelStyle.font(size: size, weight: weight, monospaced: monospaced), .foregroundColor: color.color, .paragraphStyle: paragraph,
        ])
        text.draw(in: rect)
    }
}

@MainActor
final class GridIndicatorView: NSView {
    var icons: [Int32: NSImage] = [:] {
        didSet { if icons != oldValue { needsDisplay = true } }
    }
    var content: GridIndicatorContent {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    init(content: GridIndicatorContent) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: GridIndicatorGeometry(content: content).size))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(content.displayName), \(content.position)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let geometry = GridIndicatorGeometry(content: content)
        GridPainter.background(bounds)
        for marker in content.markers { GridPainter.marker(marker, geometry: geometry) }
        GridPainter.inner(at: geometry.inset) { drawInner(geometry) }
    }

    private func drawInner(_ geometry: GridIndicatorGeometry) {
        let s = geometry.metrics.scale, margin = geometry.margin, bounds = NSRect(origin: .zero, size: geometry.inner)
        let width = bounds.width - 2 * margin
        GridPainter.text(content.displayName, rect: NSRect(x: margin, y: 10 * s, width: width, height: 17 * s), size: 12 * s,
                         weight: .semibold)
        GridPainter.text(content.position, rect: NSRect(x: margin, y: 28 * s, width: width - 46 * s, height: 16 * s), size: 11 * s,
                         color: PanelStyle.dim, monospaced: true)
        if content.active {
            GridPainter.text("Active", rect: NSRect(x: bounds.width - margin - 42 * s, y: 28 * s, width: 42 * s, height: 16 * s),
                             size: 10 * s, color: PanelStyle.neon, alignment: .right, monospaced: true)
        }
        if let warning = content.warning {
            GridPainter.text(warning, rect: NSRect(x: margin, y: 52 * s, width: width, height: 52 * s), size: 11 * s,
                             color: PanelStyle.dim, wrap: true)
            return
        }
        GridPainter(area: content.area, metrics: geometry.metrics, icons: icons)
            .grid(content.pages, rows: content.rows, columns: content.columns, geometry: geometry, labeled: content.shown, current: content.shown)
        if content.cropped {
            GridPainter.text("Grid cropped around current position", rect: geometry.footerRect, size: 9 * s, color: PanelStyle.dim,
                             monospaced: true)
        }
    }
}
