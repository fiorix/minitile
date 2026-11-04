import AppKit
import MinitileCore

struct GridPosition: Equatable {
    var workspace: UInt64
    var page: UInt64

    init?(display: DisplayState) {
        guard display.info.unmanagedReason == nil,
              let workspace = display.workspaces.first(where: { $0.id == display.currentWorkspace }),
              workspace.pages.contains(where: { $0.id == workspace.currentPage }) else { return nil }
        self.workspace = workspace.id
        self.page = workspace.currentPage
    }

    init(workspace: UInt64, page: UInt64) { self.workspace = workspace; self.page = page }
}

struct GridIndicatorTiming {
    static let duration: TimeInterval = 1.5
    private(set) var position: GridPosition?
    private(set) var visibleUntil: TimeInterval = 0

    mutating func update(_ position: GridPosition?, now: TimeInterval) -> Bool {
        guard position != self.position else { return false }
        self.position = position
        visibleUntil = position == nil ? 0 : now + Self.duration
        return true
    }

    func visible(now: TimeInterval) -> Bool { position != nil && now < visibleUntil }
}

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
    private var timing: [DisplayID: GridIndicatorTiming] = [:]
    private var hideWork: [DisplayID: DispatchWorkItem] = [:]
    var displayCount: Int { timing.count }
    var visibleCount: Int { panels.values.filter(\.isVisible).count }

    func update(state: SavedState) {
        var present = Set<DisplayID>()
        let now = ProcessInfo.processInfo.systemUptime
        for screen in NSScreen.screens {
            guard let id = DisplayCatalog.id(for: screen), let display = state.displays.first(where: { $0.info.id == id }) else { continue }
            present.insert(id)
            var clock = timing[id] ?? GridIndicatorTiming()
            let changed = clock.update(GridPosition(display: display), now: now)
            timing[id] = clock
            if changed {
                hideWork.removeValue(forKey: id)?.cancel()
                if clock.visible(now: now) {
                    let until = clock.visibleUntil
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.timing[id]?.visibleUntil == until else { return }
                            self.panels[id]?.orderOut(nil)
                            self.hideWork.removeValue(forKey: id)
                        }
                    }
                    hideWork[id] = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + GridIndicatorTiming.duration, execute: work)
                }
            }
            guard clock.visible(now: now) else { panels[id]?.orderOut(nil); continue }
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
        for id in Array(timing.keys) where !present.contains(id) {
            hideWork.removeValue(forKey: id)?.cancel()
            timing.removeValue(forKey: id)
            panels.removeValue(forKey: id)?.close()
        }
    }

    func stop() {
        hideWork.values.forEach { $0.cancel() }
        hideWork.removeAll()
        timing.removeAll()
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }
}
