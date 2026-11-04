import AppKit
import MinitileCore

/// A click-through outline around the grabbed window's tile.
@MainActor
final class GrabPanel: GrabPresenting {
    /// Above normal windows and below the page-transition overlays (one below `.floating`), so a slide covers it, and
    /// the position indicator, the drop picker and the window switcher above those.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 2)
    /// The border lies just outside the tile, in the gap, so it does not cover the window's edge.
    static let width: CGFloat = 4
    /// The corner radius at the tile's edge.
    static let radius: CGFloat = 12
    private var panel: NSPanel?

    var visible: Bool { panel?.isVisible == true }

    func show(_ frame: Rect) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let target = Geometry.cocoaFrame(frame, primaryHeight: height).insetBy(dx: -Self.width, dy: -Self.width)
        if panel.frame != target { panel.setFrame(target, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    func stop() {
        panel?.close()
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = GridPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = GrabOutlineView()
        return panel
    }
}

@MainActor
final class GrabOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = GrabPanel.width / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: GrabPanel.radius + inset,
                                yRadius: GrabPanel.radius + inset)
        path.lineWidth = GrabPanel.width
        PanelStyle.grab.color.setStroke()
        path.stroke()
    }
}

extension AppDelegate {
    /// Outlines the grabbed window where the applied scene puts it, or hides the outline while a slide covers its
    /// display; transitions call this again when the slide ends.
    func updateGrab() {
        guard started, !quitting, let reconciler else {
            grabHighlight.end()
            grabHighlight.update(state: SavedState(), scene: Scene(), covered: { _ in false })
            return
        }
        grabHighlight.update(state: engine.savedState(), scene: reconciler.scene, covered: transitions.covers)
    }

    func endGrab() {
        grabHighlight.end()
        updateGrab()
    }

    /// A release of the grab's binding modifiers that the tap missed ends it like one it saw.
    func checkGrabModifiers() {
        guard let session = grabHighlight.session, let keyboard, !keyboard.grabHeld(session) else { return }
        grabHighlight.released(session)
        updateGrab()
    }
}
