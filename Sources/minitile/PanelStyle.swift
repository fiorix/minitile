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

/// A wireframe line. Its width is in points at any panel scale, so lines stay hairlines when a panel grows or shrinks.
struct Stroke: Equatable {
    var paint: Paint
    var width: CGFloat

    /// Strokes just inside `rect`, so a tile's line stays clear of its neighbours and a cell's of the panel around it.
    func draw(inside rect: NSRect, radius: CGFloat) {
        guard rect.width > width, rect.height > width else { return }
        let inset = width / 2, corner = max(0, radius - inset)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: corner, yRadius: corner)
        path.lineWidth = width
        paint.color.setStroke()
        path.stroke()
    }
}

/// The look minitile's panels share with the website's wireframes (BRAND.md): always dark, translucent and drawn with
/// hairlines, whatever the system appearance.
enum PanelStyle {
    static let background = Paint(rgb: 0x0b0d10)
    static let rule = Paint(rgb: 0x292f39)
    static let ice = Paint(rgb: 0xc8ddf8)
    static let steel = Paint(rgb: 0x7489a5)
    static let text = Paint(rgb: 0xeef0f4)
    static let secondary = Paint(rgb: 0x9da6b3)

    /// Laid over the blurred backdrop.
    static let tint = background.opacity(0.8)
    static let border = Stroke(paint: rule, width: 1)
    static let radius: CGFloat = 12
    /// Room kept between a panel and the edges of its display's usable area; a larger panel is scaled down to fit.
    static let inset: CGFloat = 16

    static let page = Stroke(paint: steel.opacity(0.4), width: 1)
    static let emptyPage = Stroke(paint: steel.opacity(0.2), width: 1)
    static let shownPage = Stroke(paint: ice.opacity(0.95), width: 1.5)
    static let tile = Stroke(paint: steel.opacity(0.5), width: 0.7)
    static let tileFill = ice.opacity(0.03)
    /// The focused tile in the indicator, the selection in the switcher and the hovered tile in the drop picker.
    static let highlight = Stroke(paint: ice.opacity(0.95), width: 1.5)
    static let highlightFill = ice.opacity(0.13)
    /// Behind the floating badge and tray and the reserved slots' icons, which sit over tiles.
    static let plate = Stroke(paint: steel.opacity(0.6), width: 0.7)
    static let plateFill = background.opacity(0.95)
    /// Corner radii at a panel scale of 1; they grow and shrink with the panel.
    static let pageRadius: CGFloat = 4
    static let tileRadius: CGFloat = 2

    static let iconOpacity: CGFloat = 0.7
    static let reservedOpacity: CGFloat = 0.4

    static let preview = Stroke(paint: ice.opacity(0.95), width: 1.5)
    static let previewFill = ice.opacity(0.1)
    /// Just outside the preview's ice outline, which alone would vanish over a light window.
    static let keyline = Stroke(paint: background.opacity(0.5), width: 1)
    static let grab = ice.opacity(0.95)

    /// Room after each of a chord's modifier symbols and arrows, which are wider than the monospaced advance.
    static let chordTracking: CGFloat = 1.5

    /// Labels (indices, counts, positions, chords) are monospaced; other text keeps proportional letters with tabular
    /// digits.
    static func font(size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSFont {
        monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .monospacedDigitSystemFont(ofSize: size, weight: weight)
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
