import AppKit
import CSkyLight
import MinitileCore

/// The private fields of a Dock swipe event (CGEvent type 30), as measured in the gesture spike.
struct SwipeEvent: Equatable, Sendable {
    static let eventType: UInt32 = 30
    static let dockSwipe: Int64 = 23
    static let began: Int64 = 1, ended: Int64 = 4, cancelled: Int64 = 8
    static let sideways: Int64 = 1, vertical: Int64 = 2

    var hidType: Int64
    var phase: Int64
    var axis: Int64
    var progress: Double
    var velocity: Double
    /// CG global coordinates, like `DisplayInfo.frame`.
    var location: Point
}

extension SwipeEvent {
    init(_ event: CGEvent) {
        func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }
        self.init(hidType: event.getIntegerValueField(field(110)), phase: event.getIntegerValueField(field(132)),
                  axis: event.getIntegerValueField(field(123)), progress: event.getDoubleValueField(field(124)),
                  velocity: event.getDoubleValueField(field(129)), location: Point(x: event.location.x, y: event.location.y))
    }
}

/// What the main thread knows when a swipe begins, so the tap thread never has to ask it.
struct SwipePolicy: Equatable, Sendable {
    struct Display: Equatable, Sendable {
        var id: DisplayID
        var frame: Rect
        /// Managed, and showing its visible desktop rather than the stash, a fullscreen Space or an extra desktop.
        var owned: Bool

        init(id: DisplayID, frame: Rect, owned: Bool) { self.id = id; self.frame = frame; self.owned = owned }

        init(_ info: DisplayInfo, currentSpace: UInt64) {
            self.init(id: info.id, frame: info.frame,
                      owned: info.unmanagedReason == nil && info.visibleSpace != nil && info.visibleSpace == currentSpace)
        }
    }

    var started = false
    var suspended = false
    var displays: [Display] = []

    /// The display a swipe beginning at `point` navigates, or nil to leave the swipe to macOS.
    func owner(at point: Point) -> DisplayID? {
        guard started, !suspended, let display = displays.first(where: { $0.frame.contains(point) }), display.owned else { return nil }
        return display.id
    }
}

enum SwipeDecision: Equatable, Sendable { case pass, swallow, command([String]) }

/// The last swipe that began, for `debug health`.
struct SwipeRecord: Equatable, Sendable {
    var location: Point
    var display: DisplayID?
    var command: [String]?
}

/// Decides at `began` whether minitile owns a swipe, then swallows or passes every event of it until it ends, so
/// macOS never sees half a gesture.
struct SwipeTracker {
    static let minimumProgress = 0.3
    static let minimumVelocity = 2.0

    private enum Swipe { case passed, owned(DisplayID, axis: Int64) }
    private var swipe: Swipe?
    private(set) var last: SwipeRecord?

    mutating func receive(_ event: SwipeEvent, policy: SwipePolicy) -> SwipeDecision {
        guard event.hidType == SwipeEvent.dockSwipe else { return .pass }
        if event.phase == SwipeEvent.began {
            let known = event.axis == SwipeEvent.sideways || event.axis == SwipeEvent.vertical
            let owner = known ? policy.owner(at: event.location) : nil
            swipe = owner.map { .owned($0, axis: event.axis) } ?? .passed
            last = SwipeRecord(location: event.location, display: owner)
        }
        let finished = event.phase == SwipeEvent.ended || event.phase == SwipeEvent.cancelled
        guard case .owned(let display, let axis)? = swipe else {
            if finished { swipe = nil }
            return .pass
        }
        guard finished else { return .swallow }
        swipe = nil
        guard event.phase == SwipeEvent.ended,
              let command = Self.command(axis: axis, progress: event.progress, velocity: event.velocity) else { return .swallow }
        last?.command = command + ["display", display]
        return .command(command + ["display", display])
    }

    /// Fingers left show the next page and fingers up the workspace below, like the native desktop swipe.
    static func command(axis: Int64, progress: Double, velocity: Double) -> [String]? {
        guard abs(progress) >= minimumProgress || abs(velocity) >= minimumVelocity else { return nil }
        let sign = progress != 0 ? progress : velocity
        guard sign != 0 else { return nil }
        return axis == SwipeEvent.sideways ? ["page", sign > 0 ? "next" : "prev"] : ["workspace", sign < 0 ? "next" : "prev"]
    }
}

final class SwipeTap: @unchecked Sendable {
    // All shared state is under lock. The callback only runs the tracker on a policy snapshot that the main thread
    // keeps current; commands run on the main thread.
    private let lock = NSLock()
    private var policy = SwipePolicy()
    private var tracker = SwipeTracker()
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var stopping = false
    private var failed = false
    /// A command carries the uptime its last event reached the tap, so the main thread can tell how long it waited.
    private let handle: @MainActor @Sendable ([String], TimeInterval) -> Void

    init(handle: @escaping @MainActor @Sendable ([String], TimeInterval) -> Void) { self.handle = handle }

    func update(_ policy: SwipePolicy) { lock.withLock { self.policy = policy } }

    var unavailable: Bool { lock.withLock { failed } }
    var running: Bool { lock.withLock { port }.map { CGEvent.tapIsEnabled(tap: $0) } == true }
    var last: SwipeRecord? { lock.withLock { tracker.last } }

    func start() {
        let thread = Thread { [self] in
            // Swipes reach only the HID level, and the mask keeps every other kind of input out of this callback.
            guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: CGEventMask(1) << SwipeEvent.eventType, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                return Unmanaged<SwipeTap>.fromOpaque(pointer).takeUnretainedValue().receive(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
                  let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                logger.error("Swipe tap unavailable; trackpad swipes stay with macOS")
                lock.withLock { failed = true }; return
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
                port = nil; loop = nil
                if !stopping { failed = true }
                return !stopping
            }
            if unexpected { logger.error("Swipe tap stopped; trackpad swipes stay with macOS") }
        }
        thread.name = "minitile.swipes"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        let values = lock.withLock { stopping = true; return (port, loop) }
        if let port = values.0 { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop = values.1 { CFRunLoopStop(loop) }
    }

    func checkHealth() {
        guard let port = lock.withLock({ port }), !CGEvent.tapIsEnabled(tap: port) else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let received = ProcessInfo.processInfo.systemUptime
        // Swipes go to macOS while the tap is disabled. A swipe already decided keeps its decision.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == SwipeEvent.eventType else { return Unmanaged.passUnretained(event) }
        let swipe = SwipeEvent(event)
        let decision = lock.withLock { tracker.receive(swipe, policy: policy) }
        if case .command(let argv) = decision { DispatchQueue.main.async { [handle] in handle(argv, received) } }
        return decision == .pass ? Unmanaged.passUnretained(event) : nil
    }
}

extension AppDelegate {
    /// Run the swipe tap while minitile is started and `trackpad_swipes` is on, with a current policy snapshot.
    func updateSwipes() {
        guard started, !quitting, engine.config.trackpadSwipes else { swipes?.stop(); swipes = nil; return }
        let tap = swipes ?? SwipeTap { [weak self] argv, received in self?.swiped(argv, received: received) }
        tap.update(swipePolicy())
        if swipes == nil { swipes = tap; tap.start() }
    }

    func swipePolicy() -> SwipePolicy {
        SwipePolicy(started: started, suspended: !suspendedReasons.isEmpty, displays: displays.displays.map {
            SwipePolicy.Display($0.info, currentSpace: csl_current_space($0.identifier as CFString))
        })
    }

    /// The same path as a key binding, so swipes slide, bounce and focus like Ctrl+arrows.
    func swiped(_ argv: [String], received: TimeInterval) {
        inputWaited("Swipe \(argv.joined(separator: " "))", since: received)
        let reply = command(argv)
        if !reply.ok { logger.info("Swipe \(argv.joined(separator: " "), privacy: .public): \(reply.text, privacy: .public)") }
    }
}
