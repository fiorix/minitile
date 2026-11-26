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

/// Continuous-corner ("squircle") rounded rectangles and concentric corner-arc hugs, using the same three-cubic-segment
/// Apple corner spline as `scripts/branding/packaging.mjs`.
enum Squircle {
    /// How far along each straight edge, in units of `radius`, a continuous corner begins.
    static let limit: CGFloat = 1.52866483

    private static func point(_ corner: Int, in rect: CGRect, radius r: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGPoint {
        switch corner {
        case 0: CGPoint(x: rect.maxX - a * r, y: rect.minY + b * r)
        case 1: CGPoint(x: rect.maxX - b * r, y: rect.maxY - a * r)
        case 2: CGPoint(x: rect.minX + a * r, y: rect.maxY - b * r)
        default: CGPoint(x: rect.minX + b * r, y: rect.minY + a * r)
        }
    }

    private static func appendCorner(_ path: NSBezierPath, _ corner: Int, in rect: CGRect, radius r: CGFloat) {
        func at(_ a: CGFloat, _ b: CGFloat) -> CGPoint { point(corner, in: rect, radius: r, a, b) }
        path.curve(to: at(0.66993427, 0.06549600), controlPoint1: at(1.08849323, 0), controlPoint2: at(0.86840689, 0))
        path.line(to: at(0.63149399, 0.07491100))
        path.curve(to: at(0.07491176, 0.63149399), controlPoint1: at(0.37282392, 0.16905899), controlPoint2: at(0.16906013, 0.37282401))
        path.curve(to: at(0, 1.52866483), controlPoint1: at(0, 0.86840701), controlPoint2: at(0, 1.08849299))
    }

    /// A continuous-corner path in `rect`, becoming a semicircular stadium capsule once `radius` reaches the half-short-side.
    static func path(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        let short = min(rect.width, rect.height)
        guard short > 0, radius > 0 else { return NSBezierPath(rect: rect) }
        if radius >= short * 0.45 {
            let pill = short / 2
            let path = NSBezierPath(roundedRect: rect, xRadius: pill, yRadius: pill)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            return path
        }
        let r = min(radius, short / (2 * limit))
        let path = NSBezierPath()
        path.move(to: point(3, in: rect, radius: r, 0, limit))
        for corner in 0..<4 {
            path.line(to: point(corner, in: rect, radius: r, limit, 0))
            appendCorner(path, corner, in: rect, radius: r)
        }
        path.close()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    /// One concentric continuous-corner arc around `corner` (0 top-right, 1 bottom-right, 2 bottom-left, 3 top-left),
    /// extending `arm` points past the curve onto both adjacent straight edges.
    static func cornerArc(_ rect: CGRect, corner: Int, radius: CGFloat, arm: CGFloat) -> NSBezierPath {
        let short = min(rect.width, rect.height)
        let r = min(max(0, radius), short / (2 * limit))
        let reach = limit * r + max(1, arm)
        let spanX = min(rect.width * 0.44, reach), spanY = min(rect.height * 0.44, reach)
        let first = (corner == 0 || corner == 2) ? spanX : spanY
        let second = (corner == 0 || corner == 2) ? spanY : spanX
        let path = NSBezierPath()
        path.move(to: point(corner, in: rect, radius: 1, first, 0))
        path.line(to: point(corner, in: rect, radius: r, limit, 0))
        appendCorner(path, corner, in: rect, radius: r)
        path.line(to: point(corner, in: rect, radius: 1, 0, second))
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    static func capsule(_ rect: CGRect) -> NSBezierPath {
        let r = max(0, min(rect.width, rect.height) / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }
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

    /// Clips that cover the halo of a continuous-corner line drawn just inside `rect`: one band per edge, the two
    /// horizontal ones holding the full continuous corners. Core Graphics blurs a shadow only within the clip, so a
    /// window-sized outline skips blurring its middle; a rect too small to leave a middle is lit whole.
    func bands(around rect: NSRect, radius: CGFloat, width: CGFloat) -> [NSRect] {
        let cornerSpan = ceil(Squircle.limit * radius)
        let depth = max(cornerSpan, width) + reach, outer = rect.insetBy(dx: -reach, dy: -reach)
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

    /// Strokes an open path, such as a chevron or corner-arc hug.
    func draw(_ path: NSBezierPath) {
        path.lineWidth = width
        if let glow { glow.light(path, core: paint) }
        else {
            paint.color.setStroke()
            path.stroke()
        }
    }

    /// Strokes a continuous-corner squircle just inside `rect`, so a tile's line stays clear of its neighbours and a
    /// cell's of the panel around it.
    func draw(inside rect: NSRect, radius: CGFloat) {
        guard rect.width > width, rect.height > width else { return }
        let inset = width / 2, corner = max(0, radius - inset)
        let path = Squircle.path(rect.insetBy(dx: inset, dy: inset), radius: corner)
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

/// Shared visual tokens for minitile's panels: dark navy + cool steel-blue wireframes (`void` + `wire`), concentric
/// Apple continuous-corner ("squircle") platters, 2.5D milled page basins and Z-lifted window slabs, and the two-state
/// P1 neon system (`neon` cyan for resting spatial context, `amber` for active focus, selection, drop targets and grab).
enum PanelStyle {
    static let void = Paint(rgb: 0x05070c)
    static let well = Paint(rgb: 0x04060b)
    static let wire = Paint(rgb: 0x7d9cc9)
    static let ink = Paint(rgb: 0xe8f0fc)
    static let dim = Paint(rgb: 0x8e9cb4)
    static let skyBloom = Paint(rgb: 0x2d5cff)

    /// Resting spatial context (the shown page on view, active display badge, and the framed mark's top bar).
    static let neon = Paint(rgb: 0x53e9ff)
    static let neonCore = Paint(rgb: 0xdcfbff)

    /// Active focal target (focused/selected window slab, hovered drop target, preview tunnel, grab clamp).
    static let amber = Paint(rgb: 0xffb038)
    static let amberCore = Paint(rgb: 0xfff3d6)
    static let amberBloom = Paint(rgb: 0xd95b00)

    static let glow = Glow(paint: neon.opacity(0.85), radii: [6, 2])
    static let amberGlow = Glow(paint: amber.opacity(0.88), radii: [6, 2])

    static func lit(width: CGFloat) -> Stroke { Stroke(paint: neonCore, width: width, glow: glow) }
    static func focal(width: CGFloat) -> Stroke { Stroke(paint: amberCore, width: width, glow: amberGlow) }

    /// Laid over the blurred backdrop.
    static let tint = void.opacity(0.68)
    static let border = Stroke(paint: wire.opacity(0.36), width: 0.75)
    static let radius: CGFloat = 24
    /// Room kept between a panel and the edges of its display's usable area; a larger panel is scaled down to fit.
    static let inset: CGFloat = 16

    static let page = Stroke(paint: wire.opacity(0.48), width: 0.8)
    static let emptyPage = Stroke(paint: wire.opacity(0.22), width: 0.8)
    static let shownPage = lit(width: 1.1)
    static let tile = Stroke(paint: wire.opacity(0.55), width: 0.75)
    static let tileFill = wire.opacity(0.08)
    /// The focused tile in the indicator, the selection in the switcher and the hovered tile in the drop picker.
    static let highlight = focal(width: 1.2)
    static let highlightFill = amber.opacity(0.20)
    /// Behind the floating badge and tray, the reserved slots' icons, and the switcher's Dock capsule.
    static let plate = Stroke(paint: wire.opacity(0.52), width: 0.75)
    static let plateFill = void.opacity(0.94)
    /// Concentric corner radii at a panel scale of 1 (15 pt page well and 10 pt tile slab at scale 2).
    static let pageRadius: CGFloat = 7.5
    static let tileRadius: CGFloat = 5

    /// The monitor markers' screen outlines and chevrons, drawn in unlit wire unless hovered as a drop target.
    static let marker = Stroke(paint: wire.opacity(0.6), width: 1)

    static let iconOpacity: CGFloat = 0.75
    static let reservedOpacity: CGFloat = 0.42

    static let preview = focal(width: 1.5)
    static let previewFill = amber.opacity(0.08)
    /// Just outside the preview's pale outline, which alone would vanish over a light window.
    static let keyline = Stroke(paint: void.opacity(0.55), width: 1)
    /// Wider than the preview's line, since it has no fill to carry it.
    static let grab = focal(width: 2)

    /// Labels (indices, counts, positions, chords) are monospaced; other text keeps proportional letters with tabular
    /// digits.
    static func font(size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSFont {
        monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func keycapSize(_ name: String, scale: CGFloat = 1) -> CGSize {
        let text = (name as NSString).size(withAttributes: [.font: font(size: 11 * scale, monospaced: true)])
        return CGSize(width: max(26 * scale, ceil(text.width) + 14 * scale), height: 26 * scale)
    }

    /// A sculpted 3D continuous-squircle keycap: curved lower skirt, concentric raised dish, and optional lit accent.
    static func keycap(_ name: String, at origin: CGPoint, scale: CGFloat = 1, accent: Stroke? = nil) {
        let size = keycapSize(name, scale: scale), rect = CGRect(origin: origin, size: size)
        let skirtInset = 2.2 * scale
        let base = CGRect(x: rect.minX, y: rect.minY + skirtInset, width: rect.width, height: max(2, rect.height - skirtInset))
        let dish = CGRect(x: rect.minX + 1.2 * scale, y: rect.minY, width: max(2, rect.width - 2.4 * scale),
                          height: max(2, rect.height - 3.2 * scale))
        let baseRadius = 6.5 * scale, dishRadius = 5.2 * scale

        let basePath = Squircle.path(base, radius: baseRadius)
        if let accent {
            let tint = accent.paint == amberCore ? amber : neon
            let bloom = accent.paint == amberCore ? amberBloom : skyBloom
            NSGradient(starting: tint.opacity(0.32).color, ending: bloom.opacity(0.42).color)?.draw(in: basePath, angle: 90)
            accent.draw(inside: base, radius: baseRadius)
        } else {
            NSGradient(starting: wire.opacity(0.22).color, ending: void.opacity(0.95).color)?.draw(in: basePath, angle: 90)
            Stroke(paint: wire.opacity(0.50), width: 0.75).draw(inside: base, radius: baseRadius)
        }

        let dishPath = Squircle.path(dish, radius: dishRadius)
        void.opacity(0.88).color.setFill()
        dishPath.fill()
        if let accent {
            let tint = accent.paint == amberCore ? amber : neon
            let bloom = accent.paint == amberCore ? amberBloom : skyBloom
            NSGradient(starting: tint.opacity(0.22).color, ending: bloom.opacity(0.08).color)?.draw(in: dishPath, angle: 95)
            Stroke(paint: accent.paint.opacity(0.82), width: 0.65).draw(inside: dish, radius: dishRadius)
        } else {
            NSGradient(starting: wire.opacity(0.14).color, ending: wire.opacity(0.03).color)?.draw(in: dishPath, angle: 95)
            Stroke(paint: wire.opacity(0.40), width: 0.65).draw(inside: dish, radius: dishRadius)
        }

        let fg = accent?.paint ?? ink
        let text = NSAttributedString(string: name, attributes: [
            .font: font(size: 10.5 * scale, weight: .medium, monospaced: true), .foregroundColor: fg.color,
        ])
        text.draw(at: CGPoint(x: dish.midX - text.size().width / 2, y: dish.midY - text.size().height / 2))
    }

    /// Four concentric continuous-corner arc hugs around `rect` (`outerRadius = radius + offset`).
    static func cornerHugs(around rect: CGRect, radius: CGFloat, offset: CGFloat = 6, arm: CGFloat = 20, stroke: Stroke) {
        let outer = rect.insetBy(dx: -offset, dy: -offset), outerRadius = radius + offset
        for corner in 0..<4 {
            stroke.draw(Squircle.cornerArc(outer, corner: corner, radius: outerRadius, arm: arm))
        }
    }

    /// The mark (BRAND.md) in `rect` of a flipped view, on its 40-unit grid: continuous-squircle frame and 2.5D wire
    /// lower tiles, with the wide cyan top bar Z-lifted over a soft cylindrical glow skirt.
    static func mark(in rect: CGRect) {
        let unit = rect.width / 40
        func tileRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * unit, y: rect.minY + y * unit, width: width * unit, height: height * unit)
        }
        let outline = Stroke(paint: wire.opacity(0.62), width: max(0.75, 1.5 * unit))
        outline.draw(Squircle.path(tileRect(3, 3, 34, 34), radius: 7.2 * unit))
        for leg in [tileRect(9, 22, 9, 9), tileRect(22, 22, 9, 9)] {
            let depth = Squircle.path(leg.offsetBy(dx: 0.8 * unit, dy: 1.1 * unit), radius: 1.8 * unit)
            Stroke(paint: wire.opacity(0.28), width: max(0.5, 1.0 * unit)).draw(depth)
            wire.opacity(0.08).color.setFill()
            let face = Squircle.path(leg, radius: 1.8 * unit)
            face.fill()
            outline.draw(face)
        }
        let baseTop = tileRect(9, 9, 22, 9)
        let liftedTop = baseTop.offsetBy(dx: -0.7 * unit, dy: -1.0 * unit)
        let skirt = Squircle.path(baseTop, radius: 2.0 * unit)
        skyBloom.opacity(0.35).color.setFill()
        skirt.fill()
        Stroke(paint: neon.opacity(0.55), width: max(0.6, 1.1 * unit)).draw(skirt)

        NSGraphicsContext.saveGraphicsState()
        let halo = NSShadow()
        halo.shadowOffset = .zero
        halo.shadowBlurRadius = 2.4 * unit
        halo.shadowColor = neon.opacity(0.85).color
        halo.set()
        neon.color.setFill()
        Squircle.path(liftedTop, radius: 2.0 * unit).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The blurred backdrop behind a panel's drawing, dark whatever the system appearance, masked to the panel's exact
/// continuous-corner squircle or stadium capsule.
@MainActor
final class PanelBackdrop: NSVisualEffectView {
    let content: NSView
    let cornerRadius: CGFloat
    private var maskedSize: NSSize = .zero

    init(content: NSView, radius: CGFloat = PanelStyle.radius) {
        self.content = content
        self.cornerRadius = radius
        super.init(frame: NSRect(origin: .zero, size: content.frame.size))
        appearance = NSAppearance(named: .darkAqua)
        material = .hudWindow
        blendingMode = .behindWindow
        // The panels never become key, so a backdrop following the window's state would never blur.
        state = .active
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        refreshMask()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        refreshMask()
    }

    private func refreshMask() {
        guard bounds.width > 0, bounds.height > 0, bounds.size != maskedSize else { return }
        maskedSize = bounds.size
        let r = cornerRadius
        maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            Squircle.path(rect, radius: r).fill()
            return true
        }
    }
}

extension NSWindow {
    /// Puts `view` over the shared continuous-squircle backdrop and keeps the window dark whatever the system appearance.
    func setStyledContent(_ view: NSView, radius: CGFloat = PanelStyle.radius) {
        appearance = NSAppearance(named: .darkAqua)
        contentView = PanelBackdrop(content: view, radius: radius)
    }

    /// The view a styled panel draws, over its backdrop.
    var styledContent: NSView? { (contentView as? PanelBackdrop)?.content }
}
