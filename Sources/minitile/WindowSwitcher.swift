import AppKit
import MinitileCore

@MainActor
protocol SwitcherPresenting: AnyObject {
    /// Shows `content` in the middle of the display's usable area, sliding there from the middle of `from`'s when that
    /// is another display.
    func show(_ content: SwitcherContent, display: DisplayID, from: DisplayID?)
    func hide()
}

extension SwitcherApp {
    static let finder = "com.apple.finder"

    /// The apps the native app switcher lists, other than minitile, oldest first, so the apps row keeps its order as
    /// apps come and go.
    @MainActor static func running() -> [SwitcherApp] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own }
            .sorted { ($0.launchDate ?? .distantPast, $0.processIdentifier) < ($1.launchDate ?? .distantPast, $1.processIdentifier) }
            .map { SwitcherApp(pid: $0.processIdentifier, name: $0.localizedName ?? "") }
    }
}

/// The switcher's main-thread side: its selection, its pointer state, its session with the key router, and when the
/// panel shows. Opened by a held binding, the panel waits `showDelay`, so a quick Cmd+Tab switches without it ever
/// appearing.
@MainActor
final class WindowSwitcher {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    typealias Names = @MainActor () -> [DisplayID: String]
    typealias Apps = @MainActor () -> [SwitcherApp]
    static let showDelay: TimeInterval = 0.15

    struct Press: Equatable {
        var hit: SwitcherHit?
        var start: CGPoint
        var dragging: WindowID?
    }

    enum PointerUpAction: Equatable {
        case none
        case commit
        case cross(SwitcherDirection)
        case drop(window: WindowID, drop: SwitcherDrop, layout: SwitcherDropLayout, sourceDisplay: DisplayID)
    }

    private(set) var selection: SwitcherSelection?
    private(set) var session: Int?
    /// Opened by a binding, so it commits when the binding's modifiers are released.
    private(set) var held = false
    private(set) var visible = false
    private(set) var press: Press?
    private(set) var releasedDuringPress = false
    private(set) var dragPoint: CGPoint?
    private(set) var hoveredDrop: SwitcherDrop?
    private(set) var dropLayout: SwitcherDropLayout?
    /// Runs before the delayed panel appears and may close the switcher, as a modifier release the tap missed does.
    var willShow: (() -> Void)?
    /// The newest session seen, so an open the tap thread sent before a newer session cannot reopen a closed switcher.
    private var latest = 0
    private var state: SavedState?
    private var config: Config = .default
    private var shown: SwitcherContent?
    /// The display the panel is on, or before it shows, the active display it starts from.
    private var presented: DisplayID?
    private let presenter: any SwitcherPresenting
    private let schedule: Schedule
    private let names: Names
    /// The running apps the apps row draws from, read when the switcher opens and on each update while it is open.
    private let apps: Apps

    init(presenter: any SwitcherPresenting, schedule: @escaping Schedule = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }, names: @escaping Names = { DisplayCatalog.names() }, apps: @escaping Apps = { SwitcherApp.running() }) {
        self.presenter = presenter
        self.schedule = schedule
        self.names = names
        self.apps = apps
    }

    var isOpen: Bool { selection != nil }
    var dragging: WindowID? { press?.dragging }
    var isDragging: Bool { dragging != nil }
    var currentDropLayout: SwitcherDropLayout? {
        guard let selection, let state else { return nil }
        return SwitcherContent(selection: selection, state: state, names: names()).dropLayout
    }

    func isStale(_ session: Int) -> Bool { session <= latest }

    /// Opens over the windows of every managed display and the apps row, replacing an open switcher. The panel starts
    /// in the middle of `display`, the active one, and slides on to the selection's display when that is another.
    /// Returns false, leaving it closed, without a managed display or anything to offer.
    func open(session: Int, forward: Bool, held: Bool, state: SavedState, display: DisplayID?, config: Config) -> Bool {
        latest = max(latest, session)
        close()
        guard let selection = SwitcherSelection(state: state, config: config, apps: apps(), forward: forward, active: display) else {
            return false
        }
        self.selection = selection
        self.session = session
        self.held = held
        self.state = state
        self.config = config
        presented = display
        if held { schedule(Self.showDelay) { [weak self] in self?.reveal(session) } }
        else { reveal(session) }
        return true
    }

    func step(forward: Bool) {
        guard !isDragging else { return }
        selection?.step(forward: forward)
        redraw()
    }

    func move(_ direction: SwitcherDirection) {
        guard !isDragging else { return }
        selection?.move(direction)
        redraw()
    }

    func hover(_ target: SwitcherTarget) {
        guard visible, press == nil else { return }
        selection?.select(target)
        redraw()
    }

    func cross(_ side: SwitcherDirection) {
        guard !isDragging else { return }
        selection?.cross(side)
        redraw()
    }

    func pointerDown(at point: CGPoint) {
        guard visible, let selection, let state else { return }
        let base = SwitcherContent(selection: selection, state: state, names: names())
        let hit = base.target(at: point)
        press = Press(hit: hit, start: point, dragging: nil)
        dragPoint = nil
        hoveredDrop = nil
        dropLayout = nil
        if case .target(let target) = hit {
            self.selection?.select(target)
            redraw()
        }
    }

    func pointerDragged(to point: CGPoint) {
        guard visible, var currentPress = press, let state else { return }
        let moved = hypot(point.x - currentPress.start.x, point.y - currentPress.start.y) > DragMove.tolerance
        if currentPress.dragging == nil, moved, case .target(.window(let id)) = currentPress.hit,
           state.windows[id]?.info.fullscreen != true {
            currentPress.dragging = id
        }
        press = currentPress
        if let id = currentPress.dragging {
            dragPoint = point
            recomputeDrop(for: id, at: point)
            redraw()
        }
    }

    /// Returns true when no press or physical button holds the switcher open, so the caller commits immediately.
    func unhold(buttonDown: Bool) -> Bool {
        held = false
        if press != nil || buttonDown {
            releasedDuringPress = true
            return false
        }
        return true
    }

    /// Consumes a deferred modifier release once the physical mouse button goes up without a recorded press.
    func consumeDeferredReleaseCommit() -> Bool {
        guard isOpen, releasedDuringPress, press == nil else { return false }
        releasedDuringPress = false
        return true
    }

    func pointerUp(at point: CGPoint) -> PointerUpAction {
        guard let currentPress = press else { return .none }
        let released = releasedDuringPress
        let drop = hoveredDrop
        let layout = dropLayout
        let sourceDisplay = selection?.display
        clearPress()
        if let id = currentPress.dragging {
            redraw()
            guard let drop, let layout, let sourceDisplay else { return .none }
            return .drop(window: id, drop: drop, layout: layout, sourceDisplay: sourceDisplay)
        }
        let moved = hypot(point.x - currentPress.start.x, point.y - currentPress.start.y) > DragMove.tolerance
        if !moved {
            switch currentPress.hit {
            case .target(let target):
                selection?.select(target)
                return .commit
            case .marker(let side):
                return released ? .commit : .cross(side)
            case nil:
                return released ? .commit : .none
            }
        }
        return released ? .commit : .none
    }

    /// Follows model changes and apps starting and quitting. Returns the session it closed because nothing is left to
    /// offer.
    func update(state: SavedState, config: Config, keeping: DisplayID? = nil) -> Int? {
        guard var selection, let session else { return nil }
        guard selection.update(state: state, config: config, apps: apps(), keeping: keeping) else { close(); return session }
        self.selection = selection
        self.state = state
        self.config = config
        if let dragged = press?.dragging {
            if !selection.order.contains(.window(dragged)) || state.windows[dragged]?.info.fullscreen == true {
                clearPress()
            } else if let point = dragPoint {
                let fresh = SwitcherContent(selection: selection, state: state, names: names())
                if fresh.dropLayout != dropLayout {
                    recomputeDrop(for: dragged, at: point)
                }
            }
        }
        redraw()
        return nil
    }

    /// Hides the panel before returning what to switch to, so the panel never shows in a transition capture. Before the
    /// panel shows, a quick Cmd+Tab switches to the selection's `quick` window until a step or an arrow moves it, and an
    /// app opens only from a panel that showed, so it switches to a window or does nothing.
    func commit() -> SwitcherTarget? {
        let selected = visible ? selection?.selected : (selection?.quick ?? selection?.selected.window).map(SwitcherTarget.window)
        close()
        return selected
    }

    func cancel() { close() }

    /// The help screen took the keyboard under `session`, so the switcher closes without changing anything and
    /// ignores opens sent before it.
    func supersede(_ session: Int) {
        latest = max(latest, session)
        close()
    }

    private func recomputeDrop(for id: WindowID, at point: CGPoint) {
        guard let selection, let state else { return }
        let base = SwitcherContent(selection: selection, state: state, names: names())
        let floating = state.windows[id]?.floating == true
        hoveredDrop = base.dropTarget(at: point, dragging: id, floating: floating)
        dropLayout = base.dropLayout
    }

    private func makeDragOverlay() -> SwitcherDrag? {
        guard let id = press?.dragging, let point = dragPoint, let selection, let state,
              let window = state.windows[id] else { return nil }
        var pagePreview: GridMiniature?
        if case .page(let w, let p) = hoveredDrop,
           let displayState = state.displays.first(where: { $0.info.id == selection.display }),
           displayState.workspaces.indices.contains(w),
           displayState.workspaces[w].pages.indices.contains(p) {
            var page = displayState.workspaces[w].pages[p]
            page.windows.removeAll { $0 == id }
            page.windows.append(id)
            if !window.floating {
                page.nativeLayout = nil
                let activeCount = page.windows.filter { other in
                    state.windows[other].map { !$0.floating && !$0.info.minimized && !$0.info.appHidden } ?? false
                }.count
                let (r1, r2) = Layout.defaults(count: activeCount, variant: page.variant)
                page.r1 = r1
                page.r2 = r2
            }
            pagePreview = GridMiniature(page: page, windows: state.windows, focus: nil, area: selection.grid.area, config: config)
        }
        return SwitcherDrag(window: id, pid: window.info.pid, floating: window.floating, point: point, drop: hoveredDrop,
                            pagePreview: pagePreview)
    }

    private func reveal(_ session: Int) {
        guard self.session == session, !visible else { return }
        willShow?()
        guard self.session == session else { return }
        visible = true
        redraw()
    }

    private func redraw() {
        guard visible, let selection, let state else { return }
        let content = SwitcherContent(selection: selection, state: state, names: names(), drag: makeDragOverlay())
        guard content != shown || selection.display != presented else { return }
        shown = content
        presenter.show(content, display: selection.display, from: presented)
        presented = selection.display
    }

    private func clearPress() {
        press = nil
        releasedDuringPress = false
        dragPoint = nil
        hoveredDrop = nil
        dropLayout = nil
    }

    private func close() {
        if visible { presenter.hide() }
        selection = nil
        session = nil
        held = false
        visible = false
        clearPress()
        state = nil
        shown = nil
        presented = nil
    }
}

/// The switcher panel's move between displays, from the middle of one usable area to the middle of another's.
enum PanelSlide {
    static let duration: TimeInterval = 0.25

    /// A frame of `size` centered on `point`, on whole points.
    static func frame(_ size: CGSize, centeredOn point: CGPoint) -> CGRect {
        CGRect(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    /// Where the panel's origin is `elapsed` seconds into a slide, eased in and out; at `to` once the slide is over.
    static func origin(from: CGPoint, to: CGPoint, elapsed: TimeInterval) -> CGPoint {
        guard elapsed < duration else { return to }
        let t = max(0, elapsed / duration)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(2 - 2 * t, 3) / 2
        return CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
    }
}

/// A non-activating panel in the middle of the display's usable area. It moves to another display by sliding there.
@MainActor
final class SwitcherPanel: SwitcherPresenting {
    /// Above the position indicator (`.floating`), the page-transition overlays (one below it) and other apps' floating
    /// windows, as the native app switcher is.
    static let level = NSWindow.Level.popUpMenu
    /// Off with Reduce Motion or `transition_ms` at 0: the panel then moves between displays at once.
    var slides = true
    var frameChanged: ((Rect?) -> Void)?
    var usesFallbackMonitors: (() -> Bool)?
    var dismissed: (() -> Void)?
    var hovered: ((SwitcherTarget) -> Void)?
    var pressed: ((CGPoint) -> Void)?
    var dragged: ((CGPoint) -> Void)?
    var released: ((CGPoint) -> Void)?
    private var panel: NSPanel?
    private var icons = AppIconCache<NSImage>()
    private var slide: (timer: Timer, target: NSRect)?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    func show(_ content: SwitcherContent, display: DisplayID, from: DisplayID?) {
        guard let screen = NSScreen.screen(for: display) else { hide(); return }
        let panel = self.panel ?? makePanel(content)
        self.panel = panel
        let wasVisible = panel.isVisible
        if let view = panel.styledContent as? SwitcherView {
            icons.prune(keeping: Set(content.pages.flatMap { $0.flatMap { $0.slots.map(\.pid) + $0.floaters.map(\.pid) } }
                                         + content.apps.map(\.pid) + (content.drag.map { [$0.pid] } ?? [])))
            var images: [Int32: NSImage] = [:]
            for pid in content.pids {
                images[pid] = icons.icon(pid) { NSRunningApplication(processIdentifier: $0)?.icon }
            }
            view.icons = images
            view.content = content
            if !wasVisible { view.noteShown(at: NSEvent.mouseLocation) }
            let parts = [content.app, content.title, content.position, content.displayName ?? ""].filter { !$0.isEmpty }
            view.setAccessibilityLabel((["Window switcher"] + parts).joined(separator: ", "))
        }
        let size = content.geometry.size, area = screen.visibleFrame
        let target = PanelSlide.frame(size, centeredOn: CGPoint(x: area.midX, y: area.midY))
        if let slide, slide.target == target {
            updateFallbackMonitors()
            return
        }
        // A slide starts where the panel is, mid-slide or in the middle of the display left behind; a panel not yet
        // shown starts in the middle of `from`.
        var start: NSRect?
        if slides, slide != nil || (from != nil && from != display) {
            let old = panel.isVisible ? panel.frame : from.flatMap { NSScreen.screen(for: $0)?.visibleFrame }
            start = old.map { PanelSlide.frame(size, centeredOn: CGPoint(x: $0.midX, y: $0.midY)) }
        }
        endSlide()
        if let start, start != target {
            panel.setFrame(start, display: true)
            publishFrame(panel.frame)
            slide(panel, from: start.origin, to: target)
        } else if panel.frame != target {
            panel.setFrame(target, display: true)
            publishFrame(panel.frame)
        } else {
            publishFrame(panel.frame)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            publishFrame(panel.frame)
        }
        updateFallbackMonitors()
    }

    func hide() {
        endSlide()
        removeFallbackMonitors()
        publishFrame(nil)
        panel?.orderOut(nil)
    }

    func stop() {
        endSlide()
        removeFallbackMonitors()
        publishFrame(nil)
        panel?.close()
        panel = nil
    }

    private func publishFrame(_ frame: NSRect?) {
        guard let frame else { frameChanged?(nil); return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        frameChanged?(Geometry.cgFrame(frame, primaryHeight: primaryHeight))
    }

    private func updateFallbackMonitors() {
        guard usesFallbackMonitors?() == true else { removeFallbackMonitors(); return }
        guard mouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissed?() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.dismissed?() }
            }
            return event
        }
    }

    private func removeFallbackMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
    }

    /// Moves the panel's origin on each tick, which the window server does without redrawing the panel.
    private func slide(_ panel: NSPanel, from start: CGPoint, to target: NSRect) {
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                if let panel {
                    panel.setFrameOrigin(PanelSlide.origin(from: start, to: target.origin, elapsed: elapsed))
                    self.publishFrame(panel.frame)
                }
                if elapsed >= PanelSlide.duration || panel == nil { self.endSlide() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slide = (timer, target)
    }

    private func endSlide() {
        slide?.timer.invalidate()
        slide = nil
    }

    private func makePanel(_ content: SwitcherContent) -> NSPanel {
        let panel = GridPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = SwitcherView(content: content)
        view.isSliding = { [weak self] in self?.slide != nil }
        view.onHover = { [weak self] in self?.hovered?($0) }
        view.onMouseDown = { [weak self] in self?.pressed?($0) }
        view.onMouseDragged = { [weak self] in self?.dragged?($0) }
        view.onMouseUp = { [weak self] in self?.released?($0) }
        panel.setStyledContent(view)
        return panel
    }
}

@MainActor
final class SwitcherView: NSView {
    var icons: [Int32: NSImage] = [:] {
        didSet { if icons != oldValue { needsDisplay = true } }
    }
    var content: SwitcherContent {
        didSet { if content != oldValue { needsDisplay = true } }
    }
    var isSliding: (() -> Bool)?
    var onHover: ((SwitcherTarget) -> Void)?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    private var lastScreenMouse: NSPoint?

    init(content: SwitcherContent) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: content.geometry.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
    }

    func noteShown(at screenPoint: NSPoint) {
        lastScreenMouse = screenPoint
    }

    override func mouseEntered(with event: NSEvent) {
        lastScreenMouse = NSEvent.mouseLocation
    }

    override func mouseExited(with event: NSEvent) {
        lastScreenMouse = NSEvent.mouseLocation
    }

    override func mouseMoved(with event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        defer { lastScreenMouse = screenPoint }
        guard isSliding?() != true, NSEvent.pressedMouseButtons == 0 else { return }
        if let last = lastScreenMouse, hypot(screenPoint.x - last.x, screenPoint.y - last.y) < 0.5 { return }
        let point = convert(event.locationInWindow, from: nil)
        if case .target(let target) = content.target(at: point) {
            onHover?(target)
        }
    }

    override func mouseDown(with event: NSEvent) {
        lastScreenMouse = NSEvent.mouseLocation
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        lastScreenMouse = NSEvent.mouseLocation
        onMouseDragged?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        lastScreenMouse = NSEvent.mouseLocation
        onMouseUp?(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        let geometry = content.geometry
        GridPainter.background(bounds)
        let litSide: SwitcherDirection? = if case .display(_, let side) = content.drag?.drop { side } else { nil }
        for marker in content.markers {
            GridPainter.marker(marker, geometry: geometry, lit: marker.side == litSide)
        }
        GridPainter.inner(at: geometry.inset) { drawInner(geometry) }
        if let drag = content.drag, bounds.contains(drag.point) {
            GridPainter(area: content.area, metrics: geometry.metrics, icons: icons)
                .dragIcon(drag.pid, at: drag.point, scale: geometry.metrics.scale)
        }
    }

    private func drawInner(_ geometry: GridIndicatorGeometry) {
        let s = geometry.metrics.scale, margin = geometry.margin, bounds = NSRect(origin: .zero, size: geometry.inner)
        let width = bounds.width - 2 * margin
        let headerPlinth = NSRect(x: margin - 4 * s, y: 6 * s, width: width + 8 * s, height: 40 * s)
        PanelStyle.well.opacity(0.68).color.setFill()
        Squircle.path(headerPlinth, radius: 10 * s).fill()
        Stroke(paint: PanelStyle.wire.opacity(0.24), width: 0.65).draw(inside: headerPlinth, radius: 10 * s)

        GridPainter.text(content.app, rect: NSRect(x: margin + 4 * s, y: 10 * s, width: width - 168 * s, height: 17 * s), size: 12 * s,
                         weight: .semibold)
        if !content.position.isEmpty {
            let posText = content.position as NSString
            let posW = ceil(posText.size(withAttributes: [.font: PanelStyle.font(size: 9.5 * s, weight: .semibold, monospaced: true)]).width) + 16 * s
            let posPill = NSRect(x: bounds.width - margin - 4 * s - posW, y: 9 * s, width: posW, height: 17 * s)
            GridPainter.capsulePlate(posPill, fill: PanelStyle.plateFill, stroke: PanelStyle.highlight,
                                     gradientTop: PanelStyle.amber.opacity(0.22), gradientBottom: PanelStyle.amberBloom.opacity(0.12))
            GridPainter.text(content.position, rect: NSRect(x: posPill.minX, y: posPill.minY + 2.5 * s, width: posPill.width, height: 13 * s),
                             size: 9.5 * s, weight: .semibold, color: PanelStyle.amberCore, alignment: .center, monospaced: true)
        }
        // The display's name shares the title's row, right-aligned under the position, as the indicator's "Active" does.
        let named = content.displayName != nil
        GridPainter.text(content.title, rect: NSRect(x: margin + 4 * s, y: 28 * s, width: width - (named ? 164 * s : 8 * s), height: 16 * s),
                         size: 11 * s, color: PanelStyle.dim)
        if let name = content.displayName {
            GridPainter.text(name, rect: NSRect(x: bounds.width - margin - 154 * s, y: 29 * s, width: 150 * s, height: 16 * s),
                             size: 10 * s, color: PanelStyle.dim, alignment: .right, monospaced: true)
        }
        let painter = GridPainter(area: content.area, metrics: geometry.metrics, icons: icons)
        if let drag = content.drag {
            let selectedTile: WindowID? = if case .swap(let other) = drag.drop { other } else { nil }
            let preview: (cell: GridCell, miniature: GridMiniature, window: WindowID)? =
                if case .page(let w, let p) = drag.drop, let pagePreview = drag.pagePreview {
                    (GridCell(workspace: w, page: p), pagePreview, drag.window)
                } else {
                    nil
                }
            painter.grid(content.pages, rows: content.rows, columns: content.columns, geometry: geometry, labeled: content.labeled,
                         current: content.shown, selected: selectedTile, dimmed: drag.window, preview: preview)
            if let drop = drag.drop, let visual = content.insertionVisual(for: drop, drag: drag, geometry: geometry) {
                switch visual {
                case .ghostCell(let rect, let miniature):
                    painter.draw(miniature, in: rect, current: false, litCell: true, selected: drag.window)
                case .bar(let from, let to):
                    let path = NSBezierPath()
                    path.move(to: from)
                    path.line(to: to)
                    path.lineCapStyle = .round
                    PanelStyle.grab.draw(path)
                }
            }
            painter.shelf(content.apps.map(\.pid), geometry: geometry, selected: nil)
        } else {
            painter.grid(content.pages, rows: content.rows, columns: content.columns, geometry: geometry, labeled: content.labeled,
                         current: content.shown, selected: content.selected.window)
            painter.shelf(content.apps.map(\.pid), geometry: geometry, selected: content.selected.app)
        }
        if content.cropped {
            GridPainter.text("Grid cropped around the selection", rect: geometry.footerRect, size: 9 * s, color: PanelStyle.dim,
                             monospaced: true)
        }
    }
}

extension AppDelegate {
    /// `switcher next|prev|commit|cancel`, answered here since the switcher is shell UI.
    func switcherCommand(_ argv: [String]) -> Reply {
        let usage = Reply(ok: false, text: "Expected switcher next|prev|commit|cancel")
        guard argv.count == 2 else { return usage }
        switch argv[1] {
        case "next", "prev":
            let forward = argv[1] == "next"
            if windowSwitcher.isOpen { windowSwitcher.step(forward: forward); return Reply(text: "OK") }
            let opened = openSwitcher(session: keyboard?.open(.switcher) ?? 0, forward: forward, held: false)
            return opened ? Reply(text: "OK") : Reply(ok: false, text: "No window or app to switch to")
        case "commit":
            return windowSwitcher.isOpen ? commitSwitcher() : Reply(ok: false, text: "The switcher is not open")
        case "cancel":
            guard let session = windowSwitcher.session else { return Reply(ok: false, text: "The switcher is not open") }
            windowSwitcher.cancel()
            keyboard?.close(session)
            return Reply(text: "OK")
        default: return usage
        }
    }

    /// Keys the router sent for a session; ones for a switcher that has since closed are dropped.
    func switcherKey(_ key: SwitcherKey, session: Int) {
        if case .open(let forward, let held) = key {
            if !windowSwitcher.isStale(session) { _ = openSwitcher(session: session, forward: forward, held: !held.isEmpty) }
            return
        }
        guard windowSwitcher.session == session else { return }
        switch key {
        case .step(let forward): windowSwitcher.step(forward: forward)
        case .move(let direction): windowSwitcher.move(direction)
        case .quit: quitSwitcherSelection()
        case .unhold:
            if windowSwitcher.unhold(buttonDown: NSEvent.pressedMouseButtons & 1 != 0) {
                _ = commitSwitcher()
            } else {
                startSwitcherPressTimer()
            }
        case .commit: _ = commitSwitcher()
        case .cancel: windowSwitcher.cancel()
        case .open: break
        }
    }

    func switcherPointerDown(_ point: CGPoint) {
        switcherOwnsPress = true
        startSwitcherPressTimer()
        windowSwitcher.pointerDown(at: point)
    }

    func switcherPointerUp(_ point: CGPoint) {
        switch windowSwitcher.pointerUp(at: point) {
        case .none: break
        case .commit: _ = commitSwitcher()
        case .cross(let side): windowSwitcher.cross(side)
        case .drop(let id, let drop, let expectedLayout, let sourceDisplay):
            if let closed = windowSwitcher.update(state: engine.savedState(), config: engine.config) {
                keyboard?.close(closed)
                return
            }
            guard windowSwitcher.isOpen, windowSwitcher.currentDropLayout == expectedLayout else { return }
            let reply = command(drop.command(id, display: sourceDisplay))
            if !reply.ok { logger.info("Switcher drop \(id): \(reply.text, privacy: .public)") }
            let keeping: DisplayID? = if case .display = drop { sourceDisplay } else { nil }
            if let closed = windowSwitcher.update(state: engine.savedState(), config: engine.config, keeping: keeping) {
                keyboard?.close(closed)
            }
        }
    }

    /// Opens over every managed display's windows and the apps row, starting on the display a command without an
    /// address acts on. The help screen closes even when there is nothing to offer, since the router has already given
    /// the keyboard to the switcher.
    func openSwitcher(session: Int, forward: Bool, held: Bool) -> Bool {
        helpScreen.supersede(session)
        let state = engine.savedState()
        let opened = windowSwitcher.open(session: session, forward: forward, held: held, state: state,
                                         display: engine.commandDisplay, config: engine.config)
        if !opened { keyboard?.close(session) }
        return opened
    }

    /// Focuses a selected window through the command path, so its page shows with the usual slide and focus follows,
    /// and opens a selected app.
    func commitSwitcher() -> Reply {
        guard windowSwitcher.isOpen else { return Reply(ok: false, text: "The switcher is not open") }
        let session = windowSwitcher.session
        let target = windowSwitcher.commit()
        if let session { keyboard?.close(session) }
        switch target {
        case .window(let id):
            let reply = command(["window", "focus", String(id)])
            if !reply.ok { logger.info("Switcher focus \(id): \(reply.text, privacy: .public)") }
            return reply
        case .app(let pid): return openApp(pid)
        case nil: return Reply(text: "OK")
        }
    }

    /// Opens a running app as a click on its Dock icon does: it comes to the front, unhidden, and is asked to reopen,
    /// which brings back a window in most apps that show none. Plain activation, as the native app switcher does it,
    /// would leave such an app with only its menu bar.
    func openApp(_ pid: Int32) -> Reply {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return Reply(ok: false, text: "App \(pid) is not running")
        }
        guard let url = app.bundleURL else { app.activate(); return Reply(text: "OK") }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            logger.info("Switcher open \(pid): \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
        }
        return Reply(text: "OK")
    }

    /// Q asks the selection's app to quit: the selected app, or the selected window's. Only a panel on screen takes
    /// it, so nothing quits unseen, and Finder is left alone, as in the native app switcher. The switcher stays open and
    /// follows the app going away.
    func quitSwitcherSelection() {
        guard windowSwitcher.visible, !windowSwitcher.isDragging, let target = windowSwitcher.selection?.selected else { return }
        let pid = target.app ?? target.window.flatMap { engine.savedState().windows[$0]?.info.pid }
        guard let pid, let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != SwitcherApp.finder else { return }
        if !app.terminate() { logger.info("Switcher quit \(pid): the app did not take the request") }
    }

    /// The switcher's bindings work while minitile is started and not suspended, with a managed display and a window
    /// or an app to offer, and the help screen's while it is started and not suspended; otherwise Cmd+Tab and Cmd+H
    /// pass to macOS.
    func updateModalAvailability() {
        let help = modalsAvailable
        let switcher = help && SwitcherSelection.offers(state: engine.savedState(), config: engine.config) { SwitcherApp.running() }
        keyboard?.availability(switcher: switcher, help: help)
        if !switcher, let session = windowSwitcher.session {
            windowSwitcher.cancel()
            keyboard?.close(session)
        }
        if !help, let session = helpScreen.session {
            helpScreen.close()
            keyboard?.close(session)
        }
    }

    /// A release of the opening binding's modifiers that the tap missed commits the switcher, like one it saw.
    func checkModalModifiers() {
        guard windowSwitcher.held, let decision = keyboard?.checkModalModifiers() else { return }
        handleKey(decision, trace: nil)
    }
}
