import AppKit

struct GridIndicatorContent: Equatable {
    var displayName: String
    var active: Bool
    var workspace: Int?
    var page: Int?
    var windowCounts: [[Int]]
    var warning: String?

    var rows: Range<Int> { Self.viewport(count: windowCounts.count, selected: workspace, limit: 6) }
    var columns: Range<Int> { Self.viewport(count: windowCounts.map(\.count).max() ?? 0, selected: page, limit: 8) }
    var size: NSSize { NSSize(width: max(248, 52 + columns.count * 32), height: warning == nil ? 106 + rows.count * 28 : 116) }
    var position: String {
        if warning != nil { return "Display not managed" }
        guard let workspace, let page else { return "No active workspace" }
        return "Workspace \(workspace) / Page \(page)"
    }

    static func viewport(count: Int, selected: Int?, limit: Int) -> Range<Int> {
        let length = min(count, limit)
        let first = max(0, min((selected ?? 1) - 1 - length / 2, count - length))
        return first..<(first + length)
    }
}

@MainActor
final class GridIndicatorView: NSView {
    var content: GridIndicatorContent {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    init(content: GridIndicatorContent) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: content.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(content.displayName), \(content.position)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        text(content.displayName, rect: NSRect(x: 14, y: 11, width: bounds.width - 28, height: 18), size: 12, weight: .semibold)
        text(content.position, rect: NSRect(x: 14, y: 34, width: bounds.width - 77, height: 17), size: 11)
        if content.active {
            text("Active", rect: NSRect(x: bounds.width - 53, y: 34, width: 42, height: 17), size: 10, color: .controlAccentColor)
        }
        if let warning = content.warning {
            text(warning, rect: NSRect(x: 14, y: 61, width: bounds.width - 28, height: 42), size: 11, color: .secondaryLabelColor, wrap: true)
            return
        }
        for (column, page) in content.columns.enumerated() {
            text("P\(page + 1)", rect: NSRect(x: 40 + column * 32, y: 59, width: 28, height: 17), size: 10, color: .secondaryLabelColor, centered: true)
        }
        for (row, workspace) in content.rows.enumerated() {
            let y = 79 + row * 28
            text("W\(workspace + 1)", rect: NSRect(x: 9, y: y + 4, width: 28, height: 18), size: 10, color: .secondaryLabelColor, centered: true)
            for (column, page) in content.columns.enumerated() where content.windowCounts[workspace].indices.contains(page) {
                let selected = content.workspace == workspace + 1 && content.page == page + 1
                let rect = NSRect(x: 40 + column * 32, y: y, width: 28, height: 24)
                let cell = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                (selected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
                cell.fill()
                text(String(content.windowCounts[workspace][page]), rect: rect.insetBy(dx: 0, dy: 4), size: 11,
                     color: selected ? .white : .labelColor, centered: true)
            }
        }
        let clipped = content.rows.count < content.windowCounts.count || content.columns.count < (content.windowCounts.map(\.count).max() ?? 0)
        let footer = clipped ? "Grid cropped around current position" : "Cells show window counts"
        text(footer, rect: NSRect(x: 14, y: bounds.height - 20, width: bounds.width - 28, height: 15), size: 9, color: .secondaryLabelColor)
    }

    private func text(_ string: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, centered: Bool = false, wrap: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .left
        paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                                                          .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
