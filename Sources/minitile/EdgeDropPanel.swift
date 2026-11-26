import AppKit
import MinitileCore

@MainActor
final class EdgeDropPanels {
    static let capsuleRadius: CGFloat = 22
    private var panels: [DropEdge: NSPanel] = [:]

    func show(owner: EdgeDropOwner, hovered: DropEdge?) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        for edge in DropEdge.allCases {
            let panel = panels[edge] ?? DropPickerPanels.makePanel(level: DropPickerPanels.pickerLevel, shadow: true,
                                                                  view: EdgeDropView(edge: edge), styled: true,
                                                                  radius: Self.capsuleRadius)
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
        let pillRadius = min(bounds.width, bounds.height) / 2
        GridPainter.background(bounds, radius: pillRadius)

        let inner = bounds.insetBy(dx: 4, dy: 4)
        let lip = NSRect(x: inner.minX, y: inner.minY + 2, width: inner.width, height: max(2, inner.height - 2))
        PanelStyle.void.opacity(0.95).color.setFill()
        Squircle.capsule(lip).fill()

        let top = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(2, inner.height - 1.5))
        if hovered {
            GridPainter.capsulePlate(top, fill: PanelStyle.plateFill, stroke: PanelStyle.highlight,
                                     gradientTop: PanelStyle.amber.opacity(0.28), gradientBottom: PanelStyle.amberBloom.opacity(0.16))
        } else {
            GridPainter.capsulePlate(top, fill: PanelStyle.plateFill, stroke: PanelStyle.plate,
                                     gradientTop: PanelStyle.wire.opacity(0.12), gradientBottom: PanelStyle.void.opacity(0.90))
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: PanelStyle.font(size: 12.5, weight: hovered ? .semibold : .medium),
            .foregroundColor: (hovered ? PanelStyle.amberCore : PanelStyle.dim).color,
        ]
        let label = edge.title as NSString, size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2 + 9, y: (top.height - size.height) / 2 + top.minY),
                   withAttributes: attributes)

        let center = CGPoint(x: (bounds.width - size.width) / 2 - 8, y: top.midY)
        let offsets: [CGPoint] = switch edge {
        case .left: [CGPoint(x: 2.5, y: 0), CGPoint(x: -2.5, y: 0)]
        case .right: [CGPoint(x: -2.5, y: 0), CGPoint(x: 2.5, y: 0)]
        case .top: [CGPoint(x: 0, y: 2.2), CGPoint(x: 0, y: -2.2)]
        case .bottom: [CGPoint(x: 0, y: -2.2), CGPoint(x: 0, y: 2.2)]
        }
        let points: [CGPoint] = switch edge {
        case .left: [CGPoint(x: 2, y: -4), CGPoint(x: -2, y: 0), CGPoint(x: 2, y: 4)]
        case .right: [CGPoint(x: -2, y: -4), CGPoint(x: 2, y: 0), CGPoint(x: -2, y: 4)]
        case .top: [CGPoint(x: -4, y: 2), CGPoint(x: 0, y: -2), CGPoint(x: 4, y: 2)]
        case .bottom: [CGPoint(x: -4, y: -2), CGPoint(x: 0, y: 2), CGPoint(x: 4, y: -2)]
        }
        for (idx, shift) in offsets.enumerated() {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: center.x + shift.x + points[0].x, y: center.y + shift.y + points[0].y))
            for point in points.dropFirst() {
                path.line(to: CGPoint(x: center.x + shift.x + point.x, y: center.y + shift.y + point.y))
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if hovered {
                (idx == 1 ? PanelStyle.highlight : Stroke(paint: PanelStyle.amber.opacity(0.65), width: 1.0)).draw(path)
            } else {
                Stroke(paint: PanelStyle.wire.opacity(idx == 1 ? 0.65 : 0.35), width: 1.0).draw(path)
            }
        }
    }
}
