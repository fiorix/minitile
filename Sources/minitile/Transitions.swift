import AppKit
import MinitileCore

/// Owns page transitions and the reconcile they hold back. The page being left must be captured before its windows
/// move, so an animated command's reconcile waits for that capture, and every output arriving meanwhile joins it.
@MainActor
final class Transitions {
    static let captureTimeout: TimeInterval = 0.15
    /// About one frame for the overlay to reach the screen before windows move underneath it.
    static let coverDelay: TimeInterval = 0.016
    static let incomingDelay: TimeInterval = 0.02
    static let incomingTimeout: TimeInterval = 0.15
    static let bounceDuration: TimeInterval = 0.3

    private struct Pending {
        var serial: Int
        var before: SavedState
        var reconcile: PendingReconcile
        var waiting: Set<DisplayID>
        var images: [DisplayID: CGImage] = [:]
        var covering = false
        var sliding: [DisplayID: Int] = [:]
    }

    /// Applies a reconcile: moves and frames, then focus.
    var commit: ((Output) -> Void)?
    var model: (() -> SavedState)?
    var visibleIsCurrent: ((DisplayID) -> Bool)?
    private(set) var milliseconds: Double = 0
    private var gate: String? = "Not started"
    private let capture: any TransitionCapturing
    private var overlays: [DisplayID: TransitionOverlay] = [:]
    private var pending: Pending?
    private var serial = 0
    private var bounceRequests: [DisplayID: Int] = [:]
    private var waiters: [() -> Void] = []

    init(capture: any TransitionCapturing = ScreenCapture()) { self.capture = capture }

    var reason: String? { gate ?? capture.problem }
    var enabled: Bool { reason == nil }

    func configure(milliseconds: Double, reduceMotion: Bool, screenRecording: Bool) {
        let wasOpen = gate == nil
        self.milliseconds = milliseconds
        gate = TransitionGate.reason(milliseconds: milliseconds, reduceMotion: reduceMotion, screenRecording: screenRecording)
        if gate == nil, !wasOpen || capture.problem != nil { capture.refresh() }
        if gate != nil { capture.clear(); flush(); overlays.values.forEach { $0.end($0.generation) } }
    }

    func displaysChanged() {
        flush()
        let present = Set(NSScreen.screens.compactMap(DisplayCatalog.id(for:)))
        for id in overlays.keys where !present.contains(id) { overlays.removeValue(forKey: id)?.close() }
        if gate == nil { capture.refresh() }
    }

    /// Returns true when the output's reconcile is held for a capture; it is then applied with its focus later.
    func hold(_ output: Output, plan: [DisplayID: TransitionKind], before: SavedState?) -> Bool {
        let slides = plan.compactMap { id, kind -> DisplayID? in
            guard case .slide = kind, capture.canCapture(id), visibleIsCurrent?(id) != false else { return nil }
            return id
        }
        if var pending {
            pending.reconcile.add(output)
            if !pending.covering {
                for id in slides where !pending.waiting.contains(id) && pending.images[id] == nil {
                    pending.waiting.insert(id)
                    captureLeaving(id, serial: pending.serial)
                }
            }
            self.pending = pending
            return true
        }
        for (id, kind) in plan { if case .bounce(let direction) = kind { bounce(id, direction) } }
        guard enabled, let before, !slides.isEmpty else { return false }
        serial += 1
        let serial = serial
        pending = Pending(serial: serial, before: before, reconcile: PendingReconcile(output), waiting: Set(slides))
        for id in slides { captureLeaving(id, serial: serial) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureTimeout) { [weak self] in
            guard let self, self.pending?.serial == serial, self.pending?.covering == false else { return }
            logger.info("Transition capture timed out; applying without a slide where missing")
            self.cover()
        }
        return true
    }

    /// Apply any held reconcile now. Slides already covering keep running; captures still in flight are dropped.
    func flush() { if pending != nil { commitPending() } }

    /// Run `work` once the held reconcile, if any, has been applied.
    func afterReconcile(_ work: @escaping () -> Void) {
        if pending == nil { work() } else { waiters.append(work) }
    }

    func stop() {
        pending = nil
        let waiting = waiters
        waiters = []
        waiting.forEach { $0() }
        overlays.values.forEach { $0.close() }
        overlays.removeAll()
        capture.clear()
    }

    private func overlay(_ id: DisplayID) -> TransitionOverlay? {
        guard let screen = NSScreen.screen(for: id) else { return nil }
        let overlay = overlays[id] ?? TransitionOverlay()
        overlays[id] = overlay
        overlay.place(on: screen)
        return overlay
    }

    private func captureLeaving(_ id: DisplayID, serial: Int) {
        bounceRequests[id, default: 0] += 1
        capture.image(of: id) { [weak self] image in
            guard let self, var pending = self.pending, pending.serial == serial, !pending.covering else { return }
            if let image { pending.images[id] = image }
            pending.waiting.remove(id)
            self.pending = pending
            if pending.waiting.isEmpty { self.cover() }
        }
    }

    /// Start each captured display's slide with a dark incoming half, then apply the held reconcile.
    private func cover() {
        guard var pending, !pending.covering else { return }
        pending.covering = true
        // Directions span every output held so far, so a quick second navigation slides from where the screen is.
        let plan = TransitionPlan.plan(before: pending.before, after: model?() ?? pending.before, argv: [], context: nil)
        for (id, image) in pending.images {
            guard enabled, case .slide(let direction)? = plan[id], let overlay = overlay(id) else { continue }
            pending.sliding[id] = overlay.slide(from: image, direction: direction, duration: milliseconds / 1000)
        }
        self.pending = pending
        guard !pending.sliding.isEmpty else { commitPending(); return }
        let serial = pending.serial
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coverDelay) { [weak self] in
            guard self?.pending?.serial == serial else { return }
            self?.commitPending()
        }
    }

    private func commitPending() {
        guard let pending else { return }
        self.pending = nil
        commit?(pending.reconcile.output(modelFocus: model?().focus))
        let deadline = ProcessInfo.processInfo.systemUptime + Self.incomingTimeout
        for (id, generation) in pending.sliding {
            captureIncoming(id, generation: generation, deadline: deadline)
            // Without the new page's image, ending the slide early beats a dark page sliding all the way in.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.incomingTimeout) { [weak self] in
                guard let overlay = self?.overlays[id], overlay.generation == generation, overlay.awaitingIncoming else { return }
                logger.info("Transition incoming capture missing; ending the slide early")
                overlay.end(generation)
            }
        }
        let waiting = waiters
        waiters = []
        waiting.forEach { $0() }
    }

    /// Capture the new page once its windows have moved, only while the visible desktop is current: if macOS
    /// switched to the stash, the shell bounces back first.
    private func captureIncoming(_ id: DisplayID, generation: Int, deadline: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.incomingDelay) { [weak self] in
            guard let self, let overlay = self.overlays[id], overlay.generation == generation,
                  ProcessInfo.processInfo.systemUptime < deadline else { return }
            guard self.visibleIsCurrent?(id) != false else {
                self.captureIncoming(id, generation: generation, deadline: deadline); return
            }
            self.capture.image(of: id) { image in
                guard overlay.generation == generation else { return }
                if let image { overlay.arrive(image, generation: generation) } else { overlay.end(generation) }
            }
        }
    }

    /// A bounce changes nothing underneath, so its reconcile is not held. A later slide request on the display
    /// drops it; a bounce cuts a running slide short.
    private func bounce(_ id: DisplayID, _ direction: TransitionDirection) {
        guard enabled, capture.canCapture(id), visibleIsCurrent?(id) != false else { return }
        bounceRequests[id, default: 0] += 1
        let request = bounceRequests[id]
        capture.image(of: id) { [weak self] image in
            guard let self, let image, self.enabled, self.bounceRequests[id] == request, let overlay = self.overlay(id) else { return }
            overlay.bounce(image, direction: direction, duration: Self.bounceDuration)
        }
    }
}
