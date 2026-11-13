import AppKit
import CSkyLight
import MinitileCore

final class EdgeDropTap: @unchecked Sendable {
    // No AX reads or main-thread waits in the input callback. The main thread supplies confirmed window geometry.
    private let lock = NSLock()
    private var tracker = EdgeDropTracker()
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var stopping = false
    private var failed = false

    var unavailable: Bool { lock.withLock { failed } }
    var sequence: UInt64 { lock.withLock { tracker.sequence } }
    var running: Bool { lock.withLock { port }.map { CGEvent.tapIsEnabled(tap: $0) } == true }
    var preview: (owner: EdgeDropOwner, edge: DropEdge?)? {
        lock.withLock { tracker.owner.map { ($0, tracker.hovered) } }
    }

    func update(_ owner: EdgeDropOwner?, moved: Bool, press: UInt64?) { lock.withLock { tracker.update(owner, moved: moved, press: press) } }
    func cancel() { lock.withLock { tracker.cancel() } }
    func finish() -> EdgeDropFinish { lock.withLock { tracker.finish(now: ProcessInfo.processInfo.systemUptime) } }

    func start() {
        let thread = Thread { [self] in
            let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                .reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
            guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EdgeDropTap>.fromOpaque(pointer).takeUnretainedValue().receive(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
                  let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                lock.withLock { failed = true }
                logger.error("Edge drop tap unavailable; screen edges stay with macOS")
                return
            }
            let runLoop = CFRunLoopGetCurrent()!
            let shouldStop = lock.withLock { port = tap; loop = runLoop; return stopping }
            if !shouldStop {
                CFRunLoopAddSource(runLoop, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                CFRunLoopRun()
                CGEvent.tapEnable(tap: tap, enable: false)
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFMachPortInvalidate(tap)
            let unexpected = lock.withLock {
                port = nil; loop = nil; tracker.cancel()
                if !stopping { failed = true }
                return !stopping
            }
            if unexpected { logger.error("Edge drop tap stopped; screen edges stay with macOS") }
        }
        thread.name = "minitile.edge-drops"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        let values = lock.withLock { stopping = true; tracker.cancel(); return (port, loop) }
        if let port = values.0 { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop = values.1 {
            // A queued stop also handles stop() racing the thread just before CFRunLoopRun().
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
    }

    func checkHealth() {
        lock.withLock {
            guard !stopping, let port, !CGEvent.tapIsEnabled(tap: port) else { return }
            tracker.cancel()
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.withLock {
            guard !stopping else { return }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                tracker.cancel()
                if let port { CGEvent.tapEnable(tap: port, enable: true) }
                return
            }
            let point = Point(x: event.location.x, y: event.location.y)
            let location: Point
            switch type {
            case .leftMouseDown: tracker.begin(at: point); return
            case .leftMouseDragged: location = tracker.drag(to: point)
            case .leftMouseUp: location = tracker.end(at: point)
            default: return
            }
            if location != point { event.location = CGPoint(x: location.x, y: location.y) }
        }
        return Unmanaged.passUnretained(event)
    }
}

extension AppDelegate {
    func updateEdgeDrops() {
        guard started, !quitting, engine.config.edgeDrops else {
            edgeDrops?.stop(); edgeDrops = nil; edgePanels.hide()
            return
        }
        if edgeDrops == nil { edgeDrops = EdgeDropTap(); edgeDrops?.start() }
        updateEdgePolicy()
    }

    /// Gives the tap the dragged window's current eligibility and returns it; nil without a tap or an eligible drag.
    @discardableResult func updateEdgePolicy() -> EdgeDropOwner? {
        guard let edgeDrops else { return nil }
        let owner = edgeDropOwner()
        let moved = owner.flatMap { owner in discovery?.windows[owner.window].map { DragMove.isMove($0.info.frame, from: owner.origin) } } ?? false
        edgeDrops.update(owner, moved: moved, press: dragPress)
        return owner
    }

    func edgeDropOwner() -> EdgeDropOwner? {
        guard started, !quitting, engine.config.edgeDrops, discovery?.frozen == false, suspendedReasons.isEmpty,
              let id = reconciler?.dragging, let origin = dragOrigin,
              let observed = discovery?.windows[id]?.info, observed.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = engine.savedState().windows[id], window.info.pid == observed.pid else { return nil }
        guard let display = edgeDisplayCache.value(window: id, generation: dragGeneration.value, resolve: {
            displays.displays.first(where: { $0.info.id == window.display })
        }, readSpace: { csl_current_space($0 as CFString) }) else { return nil }
        return EdgeDropOwner(window: window, display: display.info, origin: origin, frame: observed.frame,
                             currentSpace: display.currentSpace,
                             visible: reconciler?.scene.displays[window.display]?.visible.contains(id) == true)
    }

    func updateEdgePreview() {
        updateEdgePolicy()
        guard let preview = edgeDrops?.preview else { edgePanels.hide(); return }
        edgePanels.show(owner: preview.owner, hovered: preview.edge)
    }
}
