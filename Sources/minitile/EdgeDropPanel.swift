import AppKit
import MinitileCore

@MainActor
final class EdgeDropPanels {
    private var panels: [DropEdge: NSPanel] = [:]

    func show(owner: EdgeDropOwner, hovered: DropEdge?) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        for edge in DropEdge.allCases {
            let panel = panels[edge] ?? DropPickerPanels.makePanel(level: DropPickerPanels.pickerLevel, shadow: true,
                                                                  view: EdgeDropView(edge: edge), styled: true)
            panels[edge] = panel
            (panel.styledContent as? EdgeDropView)?.hovered = edge == hovered
            let frame = Geometry.cocoaFrame(edge.target(in: owner.area), primaryHeight: height)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    func hide() { for panel in panels.values { panel.orderOut(nil) } }
    func stop() { for panel in panels.values { panel.close() }; panels.removeAll() }
}

@MainActor
final class EdgeDropView: NSView {
    let edge: DropEdge
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(edge: DropEdge) {
        self.edge = edge
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(edge.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        GridPainter.background(bounds)
        GridPainter.plate(bounds.insetBy(dx: 5, dy: 5), radius: 7,
                          fill: hovered ? PanelStyle.highlightFill : PanelStyle.plateFill,
                          stroke: hovered ? PanelStyle.highlight : PanelStyle.plate)
        let attributes: [NSAttributedString.Key: Any] = [.font: PanelStyle.font(size: 13, weight: .medium),
                                                       .foregroundColor: (hovered ? PanelStyle.ink : PanelStyle.dim).color]
        let label = edge.title as NSString, size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2 + 8, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        let center = CGPoint(x: (bounds.width - size.width) / 2 - 7, y: bounds.midY)
        let points: [CGPoint]
        switch edge {
        case .left: points = [CGPoint(x: 2, y: -4), CGPoint(x: -2, y: 0), CGPoint(x: 2, y: 4)]
        case .right: points = [CGPoint(x: -2, y: -4), CGPoint(x: 2, y: 0), CGPoint(x: -2, y: 4)]
        case .top: points = [CGPoint(x: -4, y: 2), CGPoint(x: 0, y: -2), CGPoint(x: 4, y: 2)]
        case .bottom: points = [CGPoint(x: -4, y: -2), CGPoint(x: 0, y: 2), CGPoint(x: 4, y: -2)]
        }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: center.x + points[0].x, y: center.y + points[0].y))
        for point in points.dropFirst() { path.line(to: CGPoint(x: center.x + point.x, y: center.y + point.y)) }
        (hovered ? PanelStyle.highlight : PanelStyle.plate).draw(path)
    }
}
