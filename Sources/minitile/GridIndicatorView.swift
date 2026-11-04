import AppKit
import MinitileCore

/// Panel layout in flipped view coordinates, sized from the number of drawn cells.
struct GridIndicatorGeometry: Equatable {
    static let margin: CGFloat = 12
    static let spacing: CGFloat = 6
    static let labelWidth: CGFloat = 22
    static let gridTop: CGFloat = 50
    static let labelHeight: CGFloat = 14
    static let footerHeight: CGFloat = 14
    static let minWidth: CGFloat = 220
    static let cellArea: CGFloat = 64 * 40
    static let reservedIcon: CGFloat = 10

    var cell: CGSize
    var rows: Int
    var columns: Int
    var cropped: Bool
    var warning: Bool

    init(content: GridIndicatorContent) {
        cell = Self.cellSize(area: content.area)
        rows = content.rows.count
        columns = content.columns.count
        cropped = content.cropped
        warning = content.warning != nil
    }

    /// Constant area in the display's proportions, so portrait displays get tall cells and wide ones stay legible.
    static func cellSize(area: Rect) -> CGSize {
        let aspect = area.width > 0 && area.height > 0 ? min(3, max(1.0 / 3, area.width / area.height)) : 1.6
        return CGSize(width: (cellArea * aspect).squareRoot().rounded(), height: (cellArea / aspect).squareRoot().rounded())
    }

    var origin: CGPoint { CGPoint(x: Self.margin + Self.labelWidth + 4, y: Self.gridTop + Self.labelHeight + 2) }

    var size: CGSize {
        if warning { return CGSize(width: Self.minWidth + 28, height: 116) }
        let width = origin.x + span(columns, cell.width) + Self.margin
        let height = origin.y + span(rows, cell.height) + (cropped ? Self.spacing + Self.footerHeight : 0) + Self.margin
        return CGSize(width: max(Self.minWidth, width), height: height)
    }

    private func span(_ count: Int, _ length: CGFloat) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * (length + Self.spacing) - Self.spacing
    }

    func cellRect(row: Int, column: Int) -> CGRect {
        CGRect(x: origin.x + CGFloat(column) * (cell.width + Self.spacing), y: origin.y + CGFloat(row) * (cell.height + Self.spacing),
               width: cell.width, height: cell.height)
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

    /// 10-14 pt, never larger than the tile.
    static func iconRect(tile: CGRect) -> CGRect {
        let short = min(tile.width, tile.height)
        let side = max(0, min(14, max(10, (short * 0.75).rounded(.down)), short.rounded(.down)))
        return CGRect(x: ((tile.midX - side / 2) * 2).rounded() / 2, y: ((tile.midY - side / 2) * 2).rounded() / 2, width: side, height: side)
    }

    /// Reserved slots have no tile, so their icons sit in a row along the cell's bottom-left corner.
    static func reservedRects(count: Int, cell: CGRect) -> [CGRect] {
        let screen = screenRect(cell: cell), side = reservedIcon
        return (0..<count).map { CGRect(x: screen.minX + 1 + CGFloat($0) * (side + 1), y: screen.maxY - 1 - side, width: side, height: side) }
    }

    /// Straddles the cell's top-right corner, so it covers as little of the tiles as possible.
    static func badgeRect(count: Int, cell: CGRect) -> CGRect {
        let width = max(12, 6 + 6 * CGFloat(String(count).count))
        return CGRect(x: cell.maxX - width + 3, y: cell.minY - 3, width: width, height: 12)
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
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        text(content.displayName, rect: NSRect(x: margin, y: 10, width: bounds.width - 2 * margin, height: 17), size: 12, weight: .semibold)
        text(content.position, rect: NSRect(x: margin, y: 28, width: bounds.width - 2 * margin - 46, height: 16), size: 11)
        if content.active {
            text("Active", rect: NSRect(x: bounds.width - margin - 42, y: 28, width: 42, height: 16), size: 10,
                 color: .controlAccentColor, alignment: .right)
        }
        if let warning = content.warning {
            text(warning, rect: NSRect(x: margin, y: 52, width: bounds.width - 2 * margin, height: 52), size: 11,
                 color: .secondaryLabelColor, wrap: true)
            return
        }
        let geometry = GridIndicatorGeometry(content: content)
        for (column, page) in content.columns.enumerated() {
            label("P\(page + 1)", rect: geometry.columnLabelRect(column: column), current: content.page == page + 1)
        }
        for (row, workspace) in content.rows.enumerated() {
            label("W\(workspace + 1)", rect: geometry.rowLabelRect(row: row), current: content.workspace == workspace + 1)
            for (column, page) in content.columns.enumerated() {
                guard let miniature = content.miniature(workspace: workspace, page: page) else { continue }
                draw(miniature, in: geometry.cellRect(row: row, column: column),
                     shown: content.workspace == workspace + 1 && content.page == page + 1)
            }
        }
        if content.cropped {
            text("Grid cropped around current position", rect: geometry.footerRect, size: 9, color: .secondaryLabelColor)
        }
    }

    private func draw(_ miniature: GridMiniature, in cell: NSRect, shown: Bool) {
        let accent = NSColor.controlAccentColor
        let outline = NSBezierPath(roundedRect: cell.insetBy(dx: shown ? 1 : 0.5, dy: shown ? 1 : 0.5), xRadius: 4, yRadius: 4)
        if !miniature.empty {
            NSColor.quinaryLabelColor.setFill()
            outline.fill()
        }
        for tile in miniature.tiles {
            guard let frame = tile.frame else { continue }
            let rect = GridIndicatorGeometry.tileRect(frame, area: content.area, cell: cell)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            (tile.focused ? accent.withAlphaComponent(0.55) : shown ? accent.withAlphaComponent(0.2) : NSColor.labelColor.withAlphaComponent(0.13)).setFill()
            path.fill()
            if tile.focused {
                accent.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            icon(tile.pid, in: GridIndicatorGeometry.iconRect(tile: rect), fraction: 1)
        }
        let reserved = GridIndicatorGeometry.reservedRects(count: miniature.reserved.count, cell: cell)
        if let first = reserved.first, let last = reserved.last {
            NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: first.union(last).insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
            for (slot, rect) in zip(miniature.reserved, reserved) { icon(slot.pid, in: rect, fraction: 0.4) }
        }
        (shown ? accent : NSColor.tertiaryLabelColor).setStroke()
        outline.lineWidth = shown ? 2 : 1
        outline.stroke()
        if miniature.floating > 0 {
            let badge = GridIndicatorGeometry.badgeRect(count: miniature.floating, cell: cell)
            let path = NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2)
            NSColor.windowBackgroundColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            NSColor.systemGray.setFill()
            path.fill()
            text(String(miniature.floating), rect: badge.offsetBy(dx: 0, dy: -0.5), size: 9, weight: .bold, color: .white, alignment: .center)
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

    private func label(_ string: String, rect: NSRect, current: Bool) {
        text(string, rect: rect, size: 10, weight: current ? .semibold : .regular,
             color: current ? .labelColor : .secondaryLabelColor, alignment: .center)
    }

    private func text(_ string: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, alignment: NSTextAlignment = .left, wrap: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                                                          .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
