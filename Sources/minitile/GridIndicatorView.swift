import AppKit
import MinitileCore

/// The sizes that differ between the position indicator and the window switcher, which draw the same miniatures.
struct GridMetrics: Equatable {
    var cellArea: CGFloat
    var spacing: CGFloat
    /// Room between the column labels and the first row, which the switcher's floating tray reaches into.
    var labelGap: CGFloat
    var minWidth: CGFloat
    var icon: ClosedRange<CGFloat>
    var reservedIcon: CGFloat
    /// Floating windows as a tray of selectable icons on the cell's top edge; nil draws a count badge.
    var trayIcon: CGFloat?

    static let indicator = GridMetrics(cellArea: 64 * 40, spacing: 6, labelGap: 2, minWidth: 220, icon: 10...14,
                                       reservedIcon: 10, trayIcon: nil)
    static let switcher = GridMetrics(cellArea: 128 * 80, spacing: 12, labelGap: 12, minWidth: 300, icon: 16...32,
                                      reservedIcon: 14, trayIcon: 16)
}

/// Panel layout in flipped view coordinates, sized from the number of drawn cells.
struct GridIndicatorGeometry: Equatable {
    static let margin: CGFloat = 12
    static let labelWidth: CGFloat = 22
    static let gridTop: CGFloat = 50
    static let labelHeight: CGFloat = 14
    static let footerHeight: CGFloat = 14

    var metrics: GridMetrics
    var cell: CGSize
    var rows: Int
    var columns: Int
    var cropped: Bool
    var warning: Bool

    init(content: GridIndicatorContent) {
        self.init(area: content.area, rows: content.rows.count, columns: content.columns.count, cropped: content.cropped,
                  warning: content.warning != nil, metrics: .indicator)
    }

    init(area: Rect, rows: Int, columns: Int, cropped: Bool, warning: Bool = false, metrics: GridMetrics) {
        self.metrics = metrics
        cell = Self.cellSize(area: area, metrics: metrics)
        self.rows = rows
        self.columns = columns
        self.cropped = cropped
        self.warning = warning
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

    var origin: CGPoint { CGPoint(x: Self.margin + Self.labelWidth + 4, y: Self.gridTop + Self.labelHeight + metrics.labelGap) }

    var size: CGSize {
        if warning { return CGSize(width: metrics.minWidth + 28, height: 116) }
        let width = origin.x + span(columns, cell.width) + Self.margin
        let height = origin.y + span(rows, cell.height) + (cropped ? metrics.spacing + Self.footerHeight : 0) + Self.margin
        return CGSize(width: max(metrics.minWidth, width), height: height)
    }

    private func span(_ count: Int, _ length: CGFloat) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * (length + metrics.spacing) - metrics.spacing
    }

    func cellRect(row: Int, column: Int) -> CGRect {
        Self.cell(row: row, column: column, size: cell, spacing: metrics.spacing).offsetBy(dx: origin.x, dy: origin.y)
    }

    func rowLabelRect(row: Int) -> CGRect {
        CGRect(x: Self.margin - 2, y: cellRect(row: row, column: 0).midY - 7, width: Self.labelWidth + 4, height: 14)
    }

    func columnLabelRect(column: Int) -> CGRect {
        let cell = cellRect(row: 0, column: column)
        return CGRect(x: cell.minX, y: Self.gridTop, width: cell.width, height: Self.labelHeight)
    }

    var footerRect: CGRect {
        CGRect(x: Self.margin, y: size.height - Self.margin - Self.footerHeight, width: size.width - 2 * Self.margin, height: Self.footerHeight)
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

    /// Within `range` (10-14 pt in the indicator), never larger than the tile.
    static func iconRect(tile: CGRect, range: ClosedRange<CGFloat> = GridMetrics.indicator.icon) -> CGRect {
        let short = min(tile.width, tile.height)
        let side = max(0, min(range.upperBound, max(range.lowerBound, (short * 0.75).rounded(.down)), short.rounded(.down)))
        return CGRect(x: ((tile.midX - side / 2) * 2).rounded() / 2, y: ((tile.midY - side / 2) * 2).rounded() / 2, width: side, height: side)
    }

    /// Reserved slots have no tile, so their icons sit in a row along the cell's bottom-left corner.
    static func reservedRects(count: Int, cell: CGRect, side: CGFloat = GridMetrics.indicator.reservedIcon) -> [CGRect] {
        let screen = screenRect(cell: cell)
        return (0..<count).map { CGRect(x: screen.minX + 1 + CGFloat($0) * (side + 1), y: screen.maxY - 1 - side, width: side, height: side) }
    }

    /// Straddles the cell's top-right corner, so it covers as little of the tiles as possible.
    static func badgeRect(count: Int, cell: CGRect) -> CGRect {
        let width = max(12, 6 + 6 * CGFloat(String(count).count))
        return CGRect(x: cell.maxX - width + 3, y: cell.minY - 3, width: width, height: 12)
    }

    /// Centered on the cell's top edge and right-aligned, where the indicator's badge sits, so it covers little of the
    /// tiles. Icons shrink when the row would not fit the cell.
    static func trayRects(count: Int, cell: CGRect, side: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let gap: CGFloat = 2, room = cell.width - 8
        let size = max(4, min(side, ((room - CGFloat(count - 1) * gap) / CGFloat(count)).rounded(.down)))
        let first = cell.maxX - 4 - CGFloat(count) * size - CGFloat(count - 1) * gap
        return (0..<count).map { CGRect(x: first + CGFloat($0) * (size + gap), y: cell.minY - size / 2, width: size, height: size) }
    }
}

/// Draws labels and page miniatures, for the position indicator and the window switcher alike.
@MainActor
struct GridPainter {
    var area: Rect
    var metrics: GridMetrics
    var icons: [Int32: NSImage]

    /// `labeled` picks the row and column labels to emphasize, `current` the cell outlined as the shown page.
    func grid(_ pages: [[GridMiniature]], rows: Range<Int>, columns: Range<Int>, geometry: GridIndicatorGeometry,
              labeled: GridCell?, current: GridCell?, selected: WindowID? = nil) {
        for (column, page) in columns.enumerated() {
            Self.label("P\(page + 1)", rect: geometry.columnLabelRect(column: column), current: labeled?.page == page)
        }
        for (row, workspace) in rows.enumerated() {
            Self.label("W\(workspace + 1)", rect: geometry.rowLabelRect(row: row), current: labeled?.workspace == workspace)
            for (column, page) in columns.enumerated() {
                guard pages.indices.contains(workspace), pages[workspace].indices.contains(page) else { continue }
                draw(pages[workspace][page], in: geometry.cellRect(row: row, column: column),
                     current: current == GridCell(workspace: workspace, page: page), selected: selected)
            }
        }
    }

    func draw(_ miniature: GridMiniature, in cell: NSRect, current: Bool, selected: WindowID? = nil) {
        let accent = NSColor.controlAccentColor
        let outline = NSBezierPath(roundedRect: cell.insetBy(dx: current ? 1 : 0.5, dy: current ? 1 : 0.5), xRadius: 4, yRadius: 4)
        if !miniature.empty {
            NSColor.quinaryLabelColor.setFill()
            outline.fill()
        }
        for tile in miniature.tiles {
            guard let frame = tile.frame else { continue }
            let rect = GridIndicatorGeometry.tileRect(frame, area: area, cell: cell)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            let chosen = tile.window == selected
            (chosen ? accent.withAlphaComponent(0.6) : tile.focused ? accent.withAlphaComponent(0.55)
                : current ? accent.withAlphaComponent(0.2) : NSColor.labelColor.withAlphaComponent(0.13)).setFill()
            path.fill()
            if chosen {
                // Stroked inside the tile, so the mark stays clear of its neighbours.
                let mark = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
                accent.setStroke()
                mark.lineWidth = 2
                mark.stroke()
            } else if tile.focused {
                accent.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            icon(tile.pid, in: GridIndicatorGeometry.iconRect(tile: rect, range: metrics.icon), fraction: 1)
        }
        let reserved = GridIndicatorGeometry.reservedRects(count: miniature.reserved.count, cell: cell, side: metrics.reservedIcon)
        if let first = reserved.first, let last = reserved.last {
            NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: first.union(last).insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
            for (slot, rect) in zip(miniature.reserved, reserved) { icon(slot.pid, in: rect, fraction: 0.4) }
        }
        (current ? accent : NSColor.tertiaryLabelColor).setStroke()
        outline.lineWidth = current ? 2 : 1
        outline.stroke()
        if let side = metrics.trayIcon { tray(miniature.floaters.filter(\.active), cell: cell, side: side, selected: selected) }
        else if miniature.floating > 0 { badge(miniature.floating, cell: cell) }
    }

    private func badge(_ count: Int, cell: NSRect) {
        let badge = GridIndicatorGeometry.badgeRect(count: count, cell: cell)
        let path = NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2)
        NSColor.windowBackgroundColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        NSColor.systemGray.setFill()
        path.fill()
        Self.text(String(count), rect: badge.offsetBy(dx: 0, dy: -0.5), size: 9, weight: .bold, color: .white, alignment: .center)
    }

    private func tray(_ floaters: [GridMiniature.Floater], cell: NSRect, side: CGFloat, selected: WindowID?) {
        let rects = GridIndicatorGeometry.trayRects(count: floaters.count, cell: cell, side: side)
        guard let first = rects.first, let last = rects.last else { return }
        let background = NSBezierPath(roundedRect: first.union(last).insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
        NSColor.windowBackgroundColor.setFill()
        background.fill()
        NSColor.tertiaryLabelColor.setStroke()
        background.lineWidth = 1
        background.stroke()
        for (floater, rect) in zip(floaters, rects) {
            if floater.window == selected {
                let mark = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3)
                NSColor.controlAccentColor.withAlphaComponent(0.6).setFill()
                mark.fill()
                NSColor.controlAccentColor.setStroke()
                mark.lineWidth = 2
                mark.stroke()
            }
            icon(floater.pid, in: rect, fraction: 1)
        }
    }

    private func icon(_ pid: Int32, in rect: NSRect, fraction: CGFloat) {
        guard rect.width > 0 else { return }
        if let image = icons[pid] {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true,
                       hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        } else {
            NSColor.secondaryLabelColor.withAlphaComponent(0.5 * fraction).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
        }
    }

    static func background(_ bounds: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    static func label(_ string: String, rect: NSRect, current: Bool) {
        text(string, rect: rect, size: 10, weight: current ? .semibold : .regular,
             color: current ? .labelColor : .secondaryLabelColor, alignment: .center)
    }

    static func text(_ string: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor = .labelColor, alignment: NSTextAlignment = .left, wrap: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                                                          .foregroundColor: color, .paragraphStyle: paragraph])
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
        let margin = GridIndicatorGeometry.margin
        GridPainter.background(bounds)
        GridPainter.text(content.displayName, rect: NSRect(x: margin, y: 10, width: bounds.width - 2 * margin, height: 17), size: 12,
                         weight: .semibold)
        GridPainter.text(content.position, rect: NSRect(x: margin, y: 28, width: bounds.width - 2 * margin - 46, height: 16), size: 11)
        if content.active {
            GridPainter.text("Active", rect: NSRect(x: bounds.width - margin - 42, y: 28, width: 42, height: 16), size: 10,
                             color: .controlAccentColor, alignment: .right)
        }
        if let warning = content.warning {
            GridPainter.text(warning, rect: NSRect(x: margin, y: 52, width: bounds.width - 2 * margin, height: 52), size: 11,
                             color: .secondaryLabelColor, wrap: true)
            return
        }
        let geometry = GridIndicatorGeometry(content: content)
        GridPainter(area: content.area, metrics: .indicator, icons: icons)
            .grid(content.pages, rows: content.rows, columns: content.columns, geometry: geometry, labeled: content.shown, current: content.shown)
        if content.cropped {
            GridPainter.text("Grid cropped around current position", rect: geometry.footerRect, size: 9, color: .secondaryLabelColor)
        }
    }
}
