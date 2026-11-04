import AppKit
import MinitileCore
import Testing
@testable import minitile

private let primary = DisplayInfo(id: "primary", frame: Rect(x: 0, y: 0, width: 1000, height: 800), isPrimary: true,
                                  visibleSpace: 1, stashSpace: 2)
private let secondary = DisplayInfo(id: "secondary", frame: Rect(x: 1000, y: 0, width: 1200, height: 900),
                                    visibleSpace: 3, stashSpace: 4)

private func info(_ id: WindowID, display: DisplayID = "primary") -> WindowInfo {
    WindowInfo(id: id, pid: Int32(id + 100), bundleID: "app.\(id)", frame: Rect(x: 0, y: 0, width: 400, height: 300), display: display)
}

private func started(_ count: Int, displays: [DisplayInfo] = [primary], extra: [WindowInfo] = []) -> Engine {
    var engine = Engine()
    let windows = (0..<count).map { info(WindowID($0 + 1)) } + extra
    _ = engine.handle(.started(saved: nil, windows: windows, displays: displays, focus: 1))
    return engine
}

/// Run a command the way the shell does and return the transitions it plans and the display it crossed into.
private func run(_ engine: inout Engine, _ command: String) -> (plan: [DisplayID: TransitionKind], crossed: DisplayID?) {
    let argv = command.split(separator: " ").map(String.init)
    let before = engine.savedState(), context = engine.commandDisplay
    let output = engine.handle(.command(argv))
    #expect(output.reply?.ok == true, Comment(rawValue: output.reply?.text ?? "missing reply"))
    let after = engine.savedState()
    let window = GrabCommand(argv: argv, focus: before.focus, output: output)?.window
    let crossed = TransitionPlan.crossing(argv: argv, window: window, before: before, after: after,
                                          context: context, contextAfter: engine.commandDisplay)
    return (TransitionPlan.plan(before: before, after: after, argv: argv, context: context, crossed: crossed != nil), crossed)
}

private func plan(_ engine: inout Engine, _ command: String) -> [DisplayID: TransitionKind] { run(&engine, command).plan }

private let right = TransitionKind.slide(TransitionDirection(dx: 1, dy: 0))
private let left = TransitionKind.slide(TransitionDirection(dx: -1, dy: 0))
private let down = TransitionKind.slide(TransitionDirection(dx: 0, dy: 1))
private let up = TransitionKind.slide(TransitionDirection(dx: 0, dy: -1))

@Test func pageNavigationSlidesAndBouncesAtTheEdges() {
    var e = started(5)
    #expect(plan(&e, "page prev") == ["primary": .bounce(TransitionDirection(dx: -1, dy: 0))])
    #expect(plan(&e, "page next") == ["primary": right])
    #expect(plan(&e, "page next") == ["primary": right])
    #expect(plan(&e, "page next") == ["primary": .bounce(TransitionDirection(dx: 1, dy: 0))])
    // Leaving the empty last page removes it; the order before the command still says left.
    #expect(plan(&e, "page prev") == ["primary": left])
    #expect(plan(&e, "page show 1") == ["primary": left])
    #expect(plan(&e, "page variant").isEmpty)
}

@Test func workspaceNavigationSlidesVerticallyAndBouncesAtTheEdges() {
    var e = started(2)
    #expect(plan(&e, "workspace prev") == ["primary": .bounce(TransitionDirection(dx: 0, dy: -1))])
    #expect(plan(&e, "workspace next") == ["primary": down])
    #expect(plan(&e, "workspace next") == ["primary": .bounce(TransitionDirection(dx: 0, dy: 1))])
    #expect(plan(&e, "workspace prev") == ["primary": up])
    #expect(e.savedState().displays[0].workspaces.count == 1)
}

@Test func nudgeAndCarrySlideWhenFocusFollowsTheWindow() {
    var e = started(5)
    #expect(plan(&e, "window nudge 1 right") == ["primary": right])
    // 1 is alone on its page, so it joins the page on its left.
    #expect(plan(&e, "window nudge 1 left") == ["primary": left])
    #expect(plan(&e, "window move 1 workspace next") == ["primary": down])
    #expect(plan(&e, "window move 1 workspace prev") == ["primary": up])
    // 2 shares the first page, so it gets a new first page; only the state after holds both pages.
    #expect(plan(&e, "window nudge 2 left") == ["primary": left])
}

@Test func onlyTheCommandDisplayBounces() {
    var e = started(1, displays: [primary, secondary], extra: [info(9, display: "secondary")])
    #expect(e.commandDisplay == "primary")
    #expect(plan(&e, "page prev") == ["primary": .bounce(TransitionDirection(dx: -1, dy: 0))])
    #expect(plan(&e, "window focus 9").isEmpty)
    #expect(plan(&e, "workspace prev") == ["secondary": .bounce(TransitionDirection(dx: 0, dy: -1))])
}

@Test func addressedNavigationSlidesAndBouncesOnTheAddressedDisplay() {
    var e = started(1, displays: [primary, secondary], extra: [info(9, display: "secondary")])
    #expect(e.commandDisplay == "primary")
    #expect(plan(&e, "page prev display secondary") == ["secondary": .bounce(TransitionDirection(dx: -1, dy: 0))])
    #expect(plan(&e, "workspace prev display secondary") == ["secondary": .bounce(TransitionDirection(dx: 0, dy: -1))])
    #expect(plan(&e, "page next display secondary") == ["secondary": right])
    #expect(plan(&e, "page next display secondary") == ["secondary": .bounce(TransitionDirection(dx: 1, dy: 0))])
    #expect(plan(&e, "page prev display secondary") == ["secondary": left])
    #expect(plan(&e, "workspace next display secondary") == ["secondary": down])
    #expect(plan(&e, "workspace next display secondary") == ["secondary": .bounce(TransitionDirection(dx: 0, dy: 1))])
    #expect(plan(&e, "page prev display primary") == ["primary": .bounce(TransitionDirection(dx: -1, dy: 0))])
}

@Test func crossingBouncesNowhereAndTheDisplayLeftBehindSlidesBack() {
    var e = started(1, displays: [primary, secondary], extra: [info(9, display: "secondary")])
    #expect(plan(&e, "page next") == ["primary": right])
    // The empty page opened on primary goes, so primary slides back; secondary keeps its page.
    #expect(run(&e, "page next") == (["primary": left], "secondary"))
    #expect(e.commandDisplay == "secondary")
    #expect(run(&e, "page prev") == ([:], "primary"))
    // Nothing lies left of primary or above either display, so these bounce as before.
    #expect(run(&e, "page prev") == (["primary": .bounce(TransitionDirection(dx: -1, dy: 0))], nil))
    #expect(run(&e, "workspace prev") == (["primary": .bounce(TransitionDirection(dx: 0, dy: -1))], nil))
    // A swipe names its display and never crosses.
    #expect(run(&e, "page next display primary") == (["primary": right], nil))
    #expect(run(&e, "page next display primary") == (["primary": .bounce(TransitionDirection(dx: 1, dy: 0))], nil))
    #expect(e.commandDisplay == "primary")
}

@Test func nudgeAndCarryAcrossSlideOnlyWhereTheShownPageChanged() {
    var e = started(2, displays: [primary, secondary], extra: [info(9, display: "secondary")])
    #expect(run(&e, "window nudge right") == (["primary": right], nil))
    // 1 is alone on the last page, so it goes to secondary's shown page, and primary slides back to the page before.
    #expect(run(&e, "window nudge right") == (["primary": left], "secondary"))
    #expect(e.savedState().windows[1]?.display == "secondary")
    // 1 shares secondary's page with 9, so it gets its own page there, and then goes back left.
    #expect(run(&e, "window nudge 1 left") == (["secondary": left], nil))
    #expect(run(&e, "window nudge 1 left") == (["secondary": right], "primary"))
    #expect(run(&e, "window resize 1 left").crossed == nil)
    #expect(run(&e, "window focus 9").crossed == nil)
}

@Test func onlyNavigationCommandsCarryABounceAndAnAddress() {
    #expect(TransitionPlan.navigation(["page", "next"])?.direction == TransitionDirection(dx: 1, dy: 0))
    #expect(TransitionPlan.navigation(["page", "next"])?.display == nil)
    #expect(TransitionPlan.navigation(["workspace", "prev", "display", "B"])?.display == "B")
    #expect(TransitionPlan.navigation(["workspace", "prev", "display", "B"])?.direction == TransitionDirection(dx: 0, dy: -1))
    #expect(TransitionPlan.navigation(["workspace", "new"]) == nil)
    #expect(TransitionPlan.navigation(["page", "next", "display"]) == nil)
    #expect(TransitionPlan.navigation(["page", "next", "screen", "B"]) == nil)
    #expect(TransitionPlan.navigation(["page", "show", "display", "B"]) == nil)
}

@Test func directionUsesTheStateThatHoldsBothIdentities() {
    #expect(TransitionPlan.step([7, 8], [8], 7, 8) == 1)
    #expect(TransitionPlan.step([8], [9, 8], 8, 9) == -1)
    #expect(TransitionPlan.step([5, 7], [9, 5], 7, 9) == -1)
    #expect(TransitionPlan.step([7, 5], [5, 9], 7, 9) == 1)
}

@Test func transitionGateExplainsWhyTransitionsAreOff() {
    #expect(TransitionGate.reason(milliseconds: 500, reduceMotion: false, screenRecording: true) == nil)
    #expect(TransitionGate.reason(milliseconds: 0, reduceMotion: true, screenRecording: false) == "transition_ms is 0")
    #expect(TransitionGate.reason(milliseconds: 500, reduceMotion: true, screenRecording: false) == "Reduce Motion is on")
    #expect(TransitionGate.reason(milliseconds: 500, reduceMotion: false, screenRecording: false) == "Screen Recording is not granted")
    #expect(TransitionGate.needsPermission(milliseconds: 500, reduceMotion: false, screenRecording: false))
    #expect(!TransitionGate.needsPermission(milliseconds: 0, reduceMotion: false, screenRecording: false))
    #expect(!TransitionGate.needsPermission(milliseconds: 500, reduceMotion: true, screenRecording: false))
}

@Test func heldOutputsMergeWithFocusLastAndOnlyIfStillFocused() {
    let frame = Rect(x: 0, y: 0, width: 10, height: 10)
    var pending = PendingReconcile(Output(scene: Scene(displays: ["a": DisplayScene(label: "1:1")]),
                                          actions: [.setFrame(1, frame), .focus(1)], rewrite: [1]))
    pending.add(Output(scene: Scene(displays: ["a": DisplayScene(label: "1:2")]), actions: [.close(2), .reloadConfig]))
    pending.add(Output(scene: Scene(displays: ["a": DisplayScene(label: "1:3")]), actions: [.focus(3)], rewrite: [4]))
    let merged = pending.output(modelFocus: 3)
    #expect(merged.scene.displays["a"]?.label == "1:3")
    #expect(merged.actions == [.setFrame(1, frame), .close(2), .focus(3)])
    #expect(merged.rewrite == [1, 4])
    #expect(pending.output(modelFocus: 5).actions == [.setFrame(1, frame), .close(2)])
}

@Test func captureGeometryUsesTopLeftDisplayLocalCoordinates() {
    let frame = CGRect(x: 100, y: 0, width: 1000, height: 800)
    #expect(TransitionGeometry.sourceRect(frame: frame, visible: CGRect(x: 100, y: 50, width: 1000, height: 725))
            == CGRect(x: 0, y: 25, width: 1000, height: 725))
    let size = CGSize(width: 200, height: 100)
    #expect(TransitionGeometry.shift(TransitionDirection(dx: 1, dy: 0), size: size) == CGSize(width: -200, height: 0))
    #expect(TransitionGeometry.shift(TransitionDirection(dx: 0, dy: 1), size: size) == CGSize(width: 0, height: 100))
}

@Test @MainActor func overlayStaysBelowTheIndicatorAndAboveNormalWindows() {
    #expect(TransitionOverlay.level.rawValue > NSWindow.Level.normal.rawValue)
    #expect(TransitionOverlay.level.rawValue < NSWindow.Level.floating.rawValue)
}

@MainActor
private final class FakeCapture: TransitionCapturing {
    var problem: String?
    var requests: [(DisplayID, @MainActor @Sendable (CGImage?) -> Void)] = []
    func canCapture(_ id: DisplayID) -> Bool { true }
    func refresh() {}
    func clear() {}
    func image(of id: DisplayID, done: @escaping @MainActor @Sendable (CGImage?) -> Void) { requests.append((id, done)) }
}

@MainActor
private final class Harness {
    let capture = FakeCapture()
    let transitions: Transitions
    var engine = started(5)
    var committed: [Output] = []
    var image: CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    init() {
        transitions = Transitions(capture: capture)
        transitions.configure(milliseconds: 500, reduceMotion: false, screenRecording: true)
        transitions.commit = { [unowned self] in self.committed.append($0) }
        transitions.model = { [unowned self] in self.engine.savedState() }
    }

    /// The shell's handle path, reduced to what decides whether the reconcile is held.
    func handle(_ input: Input) -> Bool {
        var argv: [String]?
        if case .command(let command) = input { argv = command }
        let before = argv.map { _ in engine.savedState() }
        let context = engine.commandDisplay
        let output = engine.handle(input)
        var plan: [DisplayID: TransitionKind] = [:]
        if let argv, let before {
            let after = engine.savedState()
            let window = GrabCommand(argv: argv, focus: before.focus, output: output)?.window
            let crossed = TransitionPlan.crossing(argv: argv, window: window, before: before, after: after,
                                                  context: context, contextAfter: engine.commandDisplay)
            plan = TransitionPlan.plan(before: before, after: after, argv: argv, context: context, crossed: crossed != nil)
        }
        return transitions.hold(output, plan: plan, before: before)
    }
}

@Test @MainActor func reconcileWaitsForTheLeavingCaptureAndAppliesTheLatestOutput() {
    let h = Harness()
    #expect(h.transitions.enabled)
    #expect(h.handle(.command(["page", "next"])))
    #expect(h.capture.requests.map(\.0) == ["primary"])
    #expect(h.handle(.command(["window", "focus", "5"])))
    #expect(h.handle(.windowAppeared(info(6))))
    var replied = false
    h.transitions.afterReconcile { replied = true }
    #expect(h.committed.isEmpty && !replied)
    h.capture.requests[0].1(h.image)
    #expect(h.committed.count == 1 && replied)
    #expect(h.committed[0].scene == h.engine.handle(.command(["state"])).scene)
    #expect(h.committed[0].actions == [.focus(5)])
    #expect(!h.handle(.windowAppeared(info(7))))
}

@Test @MainActor func flushAppliesAtOnceAndDropsTheLateCapture() {
    let h = Harness()
    #expect(h.handle(.command(["page", "next"])))
    _ = h.engine.handle(.focusChanged(nil))
    h.transitions.flush()
    #expect(h.committed.count == 1)
    #expect(h.committed[0].actions.isEmpty)
    h.capture.requests[0].1(h.image)
    #expect(h.committed.count == 1)
    #expect(!h.handle(.command(["page", "variant"])))
}

@Test @MainActor func bouncesAndDisabledTransitionsDoNotHoldTheReconcile() {
    let h = Harness()
    #expect(!h.handle(.command(["page", "prev"])))
    #expect(h.capture.requests.map(\.0) == ["primary"])
    h.transitions.configure(milliseconds: 0, reduceMotion: false, screenRecording: true)
    #expect(h.transitions.reason == "transition_ms is 0")
    #expect(!h.handle(.command(["page", "next"])))
}

@Test @MainActor func secondNavigationDuringCaptureJoinsTheHeldReconcile() {
    let h = Harness()
    #expect(h.handle(.command(["page", "next"])))
    #expect(h.handle(.command(["page", "next"])))
    #expect(h.capture.requests.count == 1)
    h.capture.requests[0].1(nil)
    #expect(h.committed.count == 1)
    #expect(h.committed[0].scene.displays["primary"]?.label == "1:3")
    #expect(h.committed[0].actions.isEmpty)
}

@Test @MainActor func slidingDisplayIsCoveredFromTheCommandUntilItsSlide() {
    let h = Harness()
    #expect(!h.transitions.covers("primary"))
    #expect(h.handle(.command(["window", "nudge", "1", "right"])))
    #expect(h.transitions.covers("primary"))
    #expect(!h.transitions.covers("secondary"))
    // Without a leaving image there is no slide, so the display shows at once.
    h.capture.requests[0].1(nil)
    #expect(h.committed.count == 1)
    #expect(!h.transitions.covers("primary"))
    #expect(!h.handle(.command(["window", "resize", "1", "left"])))
    #expect(!h.transitions.covers("primary"))
}
