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
        let panel = picker ?? makePanel(level: Self.pickerLevel, shadow: true, view: DropPickerView(content: content))
        picker = panel
        if let view = panel.contentView as? DropPickerView {
            icons.prune(keeping: [content.picker.pid])
            view.icons = icons.icon(content.picker.pid) { NSRunningApplication(processIdentifier: $0)?.icon }
                .map { [content.picker.pid: $0] } ?? [:]
            view.content = content
        }
        let box = content.picker.frame
        place(panel, Geometry.cocoaFrame(Rect(x: box.minX, y: box.minY, width: box.width, height: box.height), primaryHeight: height))
        guard let target else { self.preview?.orderOut(nil); return }
        let preview = self.preview ?? makePanel(level: Self.previewLevel, shadow: false, view: DropPreviewView())
        self.preview = preview
        place(preview, Geometry.cocoaFrame(target, primaryHeight: height))
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

    private func makePanel(level: NSWindow.Level, shadow: Bool, view: NSView) -> NSPanel {
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
        panel.contentView = view
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
        let painter = GridPainter(area: content.picker.area, metrics: .picker, icons: icons)
        for option in content.picker.options {
            painter.draw(content.miniature(option), in: option.cell, current: option.current, selected: content.selected(option))
        }
    }
}

/// A translucent outline of the frame the dragged window would get.
@MainActor
final class DropPreviewView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
