import AppKit
import MinitileCore

/// The drop picker and its preview: click-through panels that never take focus, so a drag, browser tab drags
/// included, carries on underneath them.
@MainActor
final class DropPickerPanels {
    /// Above the dragged window and the page-transition overlays, so a Ctrl+arrow slide during the drag leaves it shown.
    static let pickerLevel = NSWindow.Level.floating
    /// Below the picker, at the transition overlays' level.
    static let previewLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    private var picker: NSPanel?
    private var preview: NSPanel?
    private var icons = AppIconCache<NSImage>()

    var visible: Bool { picker?.isVisible == true }

    /// `preview` is the hovered tile's frame on the page, in CG global points.
    func show(_ content: DropPickerContent, preview target: Rect?) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let panel = picker ?? Self.makePanel(level: Self.pickerLevel, shadow: true, view: DropPickerView(content: content), styled: true)
        picker = panel
        if let view = panel.styledContent as? DropPickerView {
            icons.prune(keeping: [content.picker.pid])
            view.icons = icons.icon(content.picker.pid) { NSRunningApplication(processIdentifier: $0)?.icon }
                .map { [content.picker.pid: $0] } ?? [:]
            view.content = content
        }
        let box = content.picker.frame
        place(panel, Geometry.cocoaFrame(Rect(x: box.minX, y: box.minY, width: box.width, height: box.height), primaryHeight: height))
        guard let target else { self.preview?.orderOut(nil); return }
        let preview = self.preview ?? Self.makePanel(level: Self.previewLevel, shadow: false, view: DropPreviewView(), styled: false)
        self.preview = preview
        place(preview, DropPreviewView.frame(around: Geometry.cocoaFrame(target, primaryHeight: height)))
    }

    func hide() {
        picker?.orderOut(nil)
        preview?.orderOut(nil)
    }

    func stop() {
        picker?.close()
        preview?.close()
        picker = nil
        preview = nil
    }

    private func place(_ panel: NSPanel, _ frame: NSRect) {
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// `styled` puts the view over the panels' dark backdrop; the preview draws only its outline.
    static func makePanel(level: NSWindow.Level, shadow: Bool, view: NSView, styled: Bool,
                          radius: CGFloat = PanelStyle.radius) -> NSPanel {
        let panel = GridPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        panel.animationBehavior = .none
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        if styled { panel.setStyledContent(view, radius: radius) } else { panel.contentView = view }
        return panel
    }
}

@MainActor
final class DropPickerView: NSView {
    var icons: [Int32: NSImage] = [:] {
        didSet { if icons != oldValue { needsDisplay = true } }
    }
    var content: DropPickerContent {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    init(content: DropPickerContent) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: content.picker.frame.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Layout picker")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        GridPainter.background(bounds)
        let painter = GridPainter(area: content.picker.area, metrics: content.picker.metrics, icons: icons)
        for option in content.picker.options {
            painter.draw(content.miniature(option), in: option.cell, current: option.current, selected: content.selected(option))
        }
    }
}

/// A concentric continuous-squircle 3D landing bay for the frame the dragged window would get: outer corner-arc hugs,
/// a dark keyline, a focal-accent rim, and nested depth rings receding inward.
@MainActor
final class DropPreviewView: NSView {
    static let radius: CGFloat = 14
    static let hugOffset: CGFloat = 6

    /// The panel reaches past the window's frame so the outer corner-arc hugs and their halo are not clipped.
    static func frame(around target: NSRect) -> NSRect {
        let margin = hugOffset + PanelStyle.preview.reach
        return target.insetBy(dx: -margin, dy: -margin)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let keyline = PanelStyle.keyline, margin = Self.hugOffset + PanelStyle.preview.reach
        let frame = bounds.insetBy(dx: margin, dy: margin)
        let inner = frame.insetBy(dx: keyline.width, dy: keyline.width)
        GridPainter.plate(inner, radius: Self.radius, fill: PanelStyle.previewFill, stroke: PanelStyle.preview)
        for step in [1, 2, 3] as [CGFloat] {
            let inset = step * 8
            let ring = inner.insetBy(dx: inset, dy: inset)
            guard ring.width > 12, ring.height > 12 else { break }
            let ringRadius = max(4, Self.radius - inset * 0.55)
            Stroke(paint: PanelStyle.accent.opacity(max(0.12, 0.46 - step * 0.11)), width: 0.85)
                .draw(inside: ring, radius: ringRadius)
        }
        // Over the rim's halo, so the target keeps a crisp dark edge over light windows, then the outer corner hugs.
        keyline.draw(inside: frame, radius: Self.radius + keyline.width)
        PanelStyle.cornerHugs(around: inner, radius: Self.radius, offset: Self.hugOffset, arm: 22, stroke: PanelStyle.preview)
    }
}
