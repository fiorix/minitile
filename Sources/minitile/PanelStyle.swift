import AppKit

/// An sRGB colour of the brand palette at an opacity.
struct Paint: Equatable {
    var rgb: UInt32
    var alpha: CGFloat = 1

    func opacity(_ alpha: CGFloat) -> Paint { Paint(rgb: rgb, alpha: alpha) }

    var red: CGFloat { CGFloat(rgb >> 16 & 0xff) / 255 }
    var green: CGFloat { CGFloat(rgb >> 8 & 0xff) / 255 }
    var blue: CGFloat { CGFloat(rgb & 0xff) / 255 }
    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// The halo of a lit line, a neon tube's light around its pale core. Its radii are in points at any panel scale, like
/// a stroke's width.
struct Glow: Equatable {
    var paint: Paint
    /// Blur radii of the halo's passes, wide to tight. A thin line casts a faint shadow, so one pass is either too dim or
    /// too tight: the wide one gives the soft light around the line and the tight one its coloured edge.
    var radii: [CGFloat]

    /// How far past its line the halo shows. Core Graphics fades a shadow out at about its blur radius, so a panel that
    /// leaves this much room past a lit line does not clip the halo.
    var reach: CGFloat { radii.max() ?? 0 }

    /// Strokes `path` in `core` over the halo, once per pass. The core is opaque, so each pass's halo stays under it.
    func light(_ path: NSBezierPath, core: Paint) {
        for radius in radii {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = radius
            shadow.shadowColor = paint.color
            shadow.set()
            core.color.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Clips that cover the halo of a line drawn just inside `rect`: one band per edge, the two horizontal ones holding
    /// the corners. Core Graphics blurs a shadow only within the clip, so a window-sized outline skips blurring its
    /// middle; a rect too small to leave a middle is lit whole.
    func bands(around rect: NSRect, radius: CGFloat, width: CGFloat) -> [NSRect] {
        let depth = max(radius, width) + reach, outer = rect.insetBy(dx: -reach, dy: -reach)
        guard rect.width > 2 * depth, rect.height > 2 * depth else { return [outer] }
        let edge = depth + reach, side = rect.height - 2 * depth
        return [NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: edge),
                NSRect(x: outer.minX, y: rect.maxY - depth, width: outer.width, height: edge),
                NSRect(x: outer.minX, y: rect.minY + depth, width: edge, height: side),
                NSRect(x: rect.maxX - depth, y: rect.minY + depth, width: edge, height: side)]
    }
}

/// A wireframe line. Its width is in points at any panel scale, so lines stay hairlines when a panel grows or shrinks.
struct Stroke: Equatable {
    var paint: Paint
    var width: CGFloat
    /// Only lines that show state are lit; structure stays plain wire.
    var glow: Glow? = nil

    /// How far the line's halo shows past it, so a panel drawing the line at its edge can leave room.
    var reach: CGFloat { glow?.reach ?? 0 }

    /// Strokes an open path, such as a chevron.
    func draw(_ path: NSBezierPath) {
        path.lineWidth = width
        if let glow { glow.light(path, core: paint) }
        else {
            paint.color.setStroke()
            path.stroke()
        }
    }

    /// Strokes just inside `rect`, so a tile's line stays clear of its neighbours and a cell's of the panel around it.
    func draw(inside rect: NSRect, radius: CGFloat) {
        guard rect.width > width, rect.height > width else { return }
        let inset = width / 2, corner = max(0, radius - inset)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: corner, yRadius: corner)
        path.lineWidth = width
        guard let glow else {
            paint.color.setStroke()
            path.stroke()
            return
        }
        for band in glow.bands(around: rect, radius: radius, width: width) {
            NSGraphicsContext.saveGraphicsState()
            band.clip()
            glow.light(path, core: paint)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The look minitile's panels share with the website's wireframes (BRAND.md): always dark, translucent and drawn with
/// fine lines, whatever the system appearance. Light comes from lines: structure is unlit wire, and only state is a
/// lit neon line.
enum PanelStyle {
    static let void = Paint(rgb: 0x05070c)
    static let wire = Paint(rgb: 0x7d9cc9)
    static let ink = Paint(rgb: 0xe8f0fc)
    static let dim = Paint(rgb: 0x8e9cb4)
    static let neon = Paint(rgb: 0x53e9ff)
    /// The stroke of a lit line, inside its neon halo.
    static let neonCore = Paint(rgb: 0xdcfbff)

    static let glow = Glow(paint: neon.opacity(0.85), radii: [6, 2])
    static func lit(width: CGFloat) -> Stroke { Stroke(paint: neonCore, width: width, glow: glow) }

    /// Laid over the blurred backdrop.
    static let tint = void.opacity(0.6)
    static let border = Stroke(paint: wire.opacity(0.28), width: 0.5)
    static let radius: CGFloat = 12
    /// Room kept between a panel and the edges of its display's usable area; a larger panel is scaled down to fit.
    static let inset: CGFloat = 16

    static let page = Stroke(paint: wire.opacity(0.45), width: 0.75)
    static let emptyPage = Stroke(paint: wire.opacity(0.2), width: 0.75)
    static let shownPage = lit(width: 1)
    static let tile = Stroke(paint: wire.opacity(0.5), width: 0.5)
    static let tileFill = wire.opacity(0.05)
    /// The focused tile in the indicator, the selection in the switcher and the hovered tile in the drop picker.
    static let highlight = lit(width: 1)
    static let highlightFill = neon.opacity(0.12)
    /// Behind the floating badge and tray and the reserved slots' icons, which sit over tiles.
    static let plate = Stroke(paint: wire.opacity(0.5), width: 0.5)
    static let plateFill = void.opacity(0.92)
    /// Corner radii at a panel scale of 1; they grow and shrink with the panel.
    static let pageRadius: CGFloat = 4
    static let tileRadius: CGFloat = 2

    /// The monitor markers' screen outlines and chevrons, a little brighter than pages since they are small.
    static let marker = Stroke(paint: wire.opacity(0.6), width: 1)

    static let iconOpacity: CGFloat = 0.7
    static let reservedOpacity: CGFloat = 0.4

    static let preview = lit(width: 1.5)
    static let previewFill = neon.opacity(0.08)
    /// Just outside the preview's pale outline, which alone would vanish over a light window.
    static let keyline = Stroke(paint: void.opacity(0.5), width: 1)
    /// Wider than the preview's line, since it has no fill to carry it.
    static let grab = lit(width: 2)

    /// Labels (indices, counts, positions, chords) are monospaced; other text keeps proportional letters with tabular
    /// digits.
    static func font(size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSFont {
        monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func keycapSize(_ name: String, scale: CGFloat = 1) -> CGSize {
        let text = (name as NSString).size(withAttributes: [.font: font(size: 11 * scale, monospaced: true)])
        return CGSize(width: max(26 * scale, ceil(text.width) + 14 * scale), height: 26 * scale)
    }

    /// A named key over glass, with the website's wire edge and faint inner bottom edge.
    static func keycap(_ name: String, at origin: CGPoint, scale: CGFloat = 1) {
        let rect = CGRect(origin: origin, size: keycapSize(name, scale: scale)), radius = 6 * scale
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGradient(starting: wire.opacity(0.07).color, ending: wire.opacity(0.02).color)?.draw(in: path, angle: 90)
        Stroke(paint: wire.opacity(0.5), width: 0.75).draw(inside: rect, radius: radius)
        let edge = NSBezierPath()
        edge.move(to: CGPoint(x: rect.minX + radius, y: rect.maxY - 1.5 * scale))
        edge.line(to: CGPoint(x: rect.maxX - radius, y: rect.maxY - 1.5 * scale))
        Stroke(paint: wire.opacity(0.25), width: 0.75).draw(edge)
        let text = NSAttributedString(string: name, attributes: [.font: font(size: 11 * scale, monospaced: true), .foregroundColor: ink.color])
        text.draw(at: CGPoint(x: rect.midX - text.size().width / 2, y: rect.midY - text.size().height / 2))
    }
}

/// The blurred backdrop behind a panel's drawing, dark whatever the system appearance. The drawing view on top lays
/// the tint and the border over it.
@MainActor
final class PanelBackdrop: NSVisualEffectView {
    let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: content.frame.size))
        appearance = NSAppearance(named: .darkAqua)
        material = .hudWindow
        blendingMode = .behindWindow
        // The panels never become key, so a backdrop following the window's state would never blur.
        state = .active
        maskImage = Self.mask
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let mask: NSImage = {
        let radius = PanelStyle.radius, side = 2 * radius + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()
}

extension NSWindow {
    /// Puts `view` over the shared backdrop and keeps the window dark whatever the system appearance.
    func setStyledContent(_ view: NSView) {
        appearance = NSAppearance(named: .darkAqua)
        contentView = PanelBackdrop(content: view)
    }

    /// The view a styled panel draws, over its backdrop.
    var styledContent: NSView? { (contentView as? PanelBackdrop)?.content }
}
