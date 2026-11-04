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

/// One page as the core lays it out: tiled slots in order, with target frames for active windows only.
struct GridMiniature: Equatable {
    struct Slot: Equatable {
        var window: WindowID
        var pid: Int32
        /// Nil for reserved slots of minimized and app-hidden windows, which the core leaves out of the layout.
        var frame: Rect?
        var focused = false
        var dimmed: Bool { frame == nil }
    }

    var slots: [Slot] = []
    var floating = 0

    init(slots: [Slot] = [], floating: Int = 0) { self.slots = slots; self.floating = floating }

    /// Mirrors `Engine.tiled` and `Engine.frames`, so stashed pages match what showing them would lay out.
    init(page: PageState, windows: [WindowID: WindowState], focus: WindowID?, area: Rect, config: Config) {
        let tiled = page.windows.filter { windows[$0].map { !$0.floating } ?? false }
        let active = tiled.filter { windows[$0].map { !$0.info.minimized && !$0.info.appHidden } ?? false }
        let frames = Layout.frames(frame: area, count: active.count, variant: page.variant, r1: page.r1, r2: page.r2,
                                   gaps: config.gaps, padding: config.padding)
        let targets = Dictionary(uniqueKeysWithValues: zip(active, frames))
        slots = tiled.compactMap { id in windows[id].map { Slot(window: id, pid: $0.info.pid, frame: targets[id], focused: id == focus) } }
        floating = page.windows.count { windows[$0]?.floating == true }
    }

    var empty: Bool { slots.isEmpty && floating == 0 }
    var tiles: [Slot] { slots.filter { !$0.dimmed } }
    var reserved: [Slot] { slots.filter(\.dimmed) }
}

struct GridIndicatorContent: Equatable {
    static let rowLimit = 4
    static let columnLimit = 5

    var displayName: String
    var active: Bool
    var workspace: Int?
    var page: Int?
    /// The display's usable area: cells take its proportions and tiles are scaled from it.
    var area: Rect
    var pages: [[GridMiniature]]
    var warning: String?

    var rows: Range<Int> { Self.viewport(count: pages.count, selected: workspace, limit: Self.rowLimit) }
    var columns: Range<Int> { Self.viewport(count: pageCount, selected: page, limit: Self.columnLimit) }
    var cropped: Bool { rows.count < pages.count || columns.count < pageCount }
    var position: String {
        if warning != nil { return "Display not managed" }
        guard let workspace, let page else { return "No active workspace" }
        return "Workspace \(workspace) / Page \(page)"
    }

    private var pageCount: Int { pages.map(\.count).max() ?? 0 }

    func miniature(workspace: Int, page: Int) -> GridMiniature? {
        pages.indices.contains(workspace) && pages[workspace].indices.contains(page) ? pages[workspace][page] : nil
    }

    /// Apps whose icons the drawn cells need.
    var pids: Set<Int32> {
        Set(rows.flatMap { w in columns.compactMap { miniature(workspace: w, page: $0) } }.flatMap { $0.slots.map(\.pid) })
    }

    static func viewport(count: Int, selected: Int?, limit: Int) -> Range<Int> {
        let length = min(count, limit)
        let first = max(0, min((selected ?? 1) - 1 - length / 2, count - length))
        return first..<(first + length)
    }
}

extension GridIndicatorContent {
    init(display: DisplayState, state: SavedState, config: Config, name: String) {
        let workspace = display.workspaces.firstIndex { $0.id == display.currentWorkspace }
        let page = workspace.flatMap { index in
            display.workspaces[index].pages.firstIndex { $0.id == display.workspaces[index].currentPage }
        }
        let area = display.info.visibleFrame
        let pages = display.workspaces.map { workspace in
            workspace.pages.map { page in
                let shown = workspace.id == display.currentWorkspace && page.id == workspace.currentPage
                return GridMiniature(page: page, windows: state.windows, focus: shown ? state.focus : nil, area: area, config: config)
            }
        }
        self.init(displayName: name, active: state.activeDisplay == display.info.id, workspace: workspace.map { $0 + 1 },
                  page: page.map { $0 + 1 }, area: area, pages: pages, warning: display.info.unmanagedReason)
    }
}

/// App icons by pid. Misses are cached too, and pruning drops apps that no longer own a managed window.
struct AppIconCache<Icon> {
    private(set) var icons: [Int32: Icon?] = [:]

    mutating func icon(_ pid: Int32, load: (Int32) -> Icon?) -> Icon? {
        if let cached = icons[pid] { return cached }
        let icon = load(pid)
        icons[pid] = .some(icon)
        return icon
    }

    mutating func prune(keeping pids: Set<Int32>) {
        icons = icons.filter { pids.contains($0.key) }
    }
}

@MainActor
final class GridIndicator {
    private var panels: [DisplayID: NSPanel] = [:]
    private var timing: [DisplayID: GridIndicatorTiming] = [:]
    private var hideWork: [DisplayID: DispatchWorkItem] = [:]
    private var icons = AppIconCache<NSImage>()
    var displayCount: Int { timing.count }
    var visibleCount: Int { panels.values.filter(\.isVisible).count }

    func update(state: SavedState, config: Config) {
        icons.prune(keeping: Set(state.windows.values.map(\.info.pid)))
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
            let content = GridIndicatorContent(display: display, state: state, config: config, name: screen.localizedName)
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
                var images: [Int32: NSImage] = [:]
                for pid in content.pids {
                    images[pid] = icons.icon(pid) { NSRunningApplication(processIdentifier: $0)?.icon }
                }
                view.icons = images
                view.content = content
                view.setAccessibilityLabel("\(content.displayName), \(content.position)")
            }
            let size = GridIndicatorGeometry(content: content).size
            let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.maxY - size.height - 12,
                               width: size.width, height: size.height)
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
