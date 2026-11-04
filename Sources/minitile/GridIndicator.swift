import AppKit
import MinitileCore

@MainActor
private final class GridIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension GridIndicatorContent {
    init(display: DisplayState, name: String, active: Bool) {
        let workspace = display.workspaces.firstIndex { $0.id == display.currentWorkspace }
        let page = workspace.flatMap { index in
            display.workspaces[index].pages.firstIndex { $0.id == display.workspaces[index].currentPage }
        }
        self.init(displayName: name, active: active, workspace: workspace.map { $0 + 1 }, page: page.map { $0 + 1 },
                  windowCounts: display.workspaces.map { $0.pages.map { $0.windows.count } }, warning: display.info.unmanagedReason)
    }
}

@MainActor
final class GridIndicator {
    private var panels: [DisplayID: NSPanel] = [:]
    var displayCount: Int { panels.count }

    func update(state: SavedState) {
        var present = Set<DisplayID>()
        for screen in NSScreen.screens {
            guard let id = DisplayCatalog.id(for: screen), let display = state.displays.first(where: { $0.info.id == id }) else { continue }
            present.insert(id)
            let content = GridIndicatorContent(display: display, name: screen.localizedName, active: state.activeDisplay == id)
            let panel: NSPanel
            if let existing = panels[id] { panel = existing }
            else {
                panel = GridIndicatorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                panel.contentView = GridIndicatorView(content: content)
                panels[id] = panel
            }
            if let view = panel.contentView as? GridIndicatorView {
                view.content = content
                view.setAccessibilityLabel("\(content.displayName), \(content.position)")
            }
            let frame = NSRect(x: screen.visibleFrame.maxX - content.size.width - 12,
                               y: screen.visibleFrame.maxY - content.size.height - 12,
                               width: content.size.width, height: content.size.height)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        for id in Array(panels.keys) where !present.contains(id) { panels.removeValue(forKey: id)?.close() }
    }

    func stop() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }
}
