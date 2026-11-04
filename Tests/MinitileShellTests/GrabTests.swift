import AppKit
import MinitileCore
import Testing
@testable import minitile

private let display = DisplayInfo(id: "d", frame: Rect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: Rect(x: 0, y: 33, width: 1512, height: 900), isPrimary: true)

private func engine(_ count: Int) -> Engine {
    var engine = Engine()
    let windows = (1...count).map { WindowInfo(id: WindowID($0), pid: Int32(100 + $0), display: "d") }
    _ = engine.handle(.started(saved: nil, windows: windows, displays: [display], focus: 1))
    return engine
}

/// Runs a command the way the shell does and returns what it means for the grab.
private func grabbing(_ engine: inout Engine, _ text: String) -> GrabCommand? {
    let argv = text.split(separator: " ").map(String.init)
    let focus = engine.savedState().focus
    return GrabCommand(argv: argv, focus: focus, output: engine.handle(.command(argv)))
}

private func scene(_ engine: inout Engine) -> Scene { engine.handle(.command(["state"])).scene }

private func split(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

private extension SavedState {
    static func focused(_ focus: WindowID?, windows: [WindowID]) -> SavedState {
        var state = SavedState()
        for id in windows {
            state.windows[id] = WindowState(info: WindowInfo(id: id, pid: Int32(id), display: "d"), display: "d", floating: false)
        }
        state.focus = focus
        return state
    }
}

@Test func onlyNudgeCarrySlotSwapAndDirectionalResizeGrab() {
    let grabbing = ["window nudge left", "window nudge 42 right", "window move left", "window move 42 down",
                    "window move workspace prev", "window move 42 workspace next", "window resize up", "window resize 42 left",
                    "window swap next", "window swap 42 prev"]
    for text in grabbing { #expect(GrabCommand.grabs(split(text)), Comment(rawValue: text)) }
    let other = ["window nudge", "window nudge up", "window nudge x left", "window nudge 42 left right", "window move workspace 2",
                 "window move page next", "window move display next", "window move 42 workspace", "window resize 0.6",
                 "window resize 42 400x300", "window focus left", "window swap 42 43", "window place standard 0",
                 "page next", "workspace next", "switcher next"]
    for text in other { #expect(!GrabCommand.grabs(split(text)), Comment(rawValue: text)) }
}

@Test func grabbingCommandsActOnTheirWindowAndNoOpsChangeNothing() {
    var two = engine(2)
    #expect(grabbing(&two, "window resize right") == GrabCommand(window: 1, acted: true))
    #expect(grabbing(&two, "window resize 2 left") == GrabCommand(window: 2, acted: true))
    #expect(grabbing(&two, "window nudge right") == GrabCommand(window: 1, acted: true))
    #expect(grabbing(&two, "window move workspace next") == GrabCommand(window: 1, acted: true))
    // Alone on the first page and workspace: nothing to the left or above.
    #expect(grabbing(&two, "window move workspace prev") == GrabCommand(window: 1, acted: true))
    #expect(grabbing(&two, "window move workspace prev") == GrabCommand(window: 1, acted: false))
    #expect(grabbing(&two, "window nudge 1 left") == GrabCommand(window: 1, acted: true))
    #expect(grabbing(&two, "window nudge left") == GrabCommand(window: 1, acted: false))
    // A lone window has no cut to move.
    #expect(grabbing(&two, "window resize left") == GrabCommand(window: 1, acted: false))
    // A floating window changes size.
    #expect(grabbing(&two, "window float 2 on") == nil)
    #expect(grabbing(&two, "window resize 2 right") == GrabCommand(window: 2, acted: true))
    // Failed and other commands never grab.
    #expect(grabbing(&two, "window nudge 99 left") == nil)
    #expect(grabbing(&two, "window resize 1 0.6") == nil)
    #expect(grabbing(&two, "page next") == nil)
    var unfocused = engine(2)
    _ = unfocused.handle(.focusChanged(nil))
    #expect(grabbing(&unfocused, "window nudge left") == nil)
}

@Test func aNudgeAcrossDisplaysGrabsAndTheOutlineFollowsTheWindow() {
    let right = DisplayInfo(id: "e", frame: Rect(x: 1512, y: 0, width: 1512, height: 982), visibleFrame: Rect(x: 1512, y: 0, width: 1512, height: 982))
    var e = Engine()
    _ = e.handle(.started(saved: nil, windows: [WindowInfo(id: 1, pid: 101, display: "d"), WindowInfo(id: 2, pid: 102, display: "e")],
                          displays: [display, right], focus: 1))
    #expect(grabbing(&e, "window nudge right") == GrabCommand(window: 1, acted: true))
    let placed = GrabPlacement.frame(of: 1, scene: scene(&e), state: e.savedState())
    #expect(placed?.display == "e")
    #expect(placed.map { $0.frame.x >= 1512 } == true)
    // Nothing lies right of the right display.
    #expect(grabbing(&e, "window nudge right") == GrabCommand(window: 1, acted: true))
    #expect(grabbing(&e, "window nudge right") == GrabCommand(window: 1, acted: false))
}

@Test func bindingGrabLastsUntilItsSessionIsReleased() {
    var lifetime = GrabLifetime()
    lifetime.command(GrabCommand(window: 1, acted: true), session: 3, focus: 1, now: 10)
    #expect(lifetime.grab == GrabLifetime.Grab(window: 1, session: 3, until: nil, focus: 1))
    lifetime.check(SavedState.focused(1, windows: [1, 2]), now: 100)
    #expect(lifetime.grab?.window == 1)
    // Further presses continue it, and a no-op on the grabbed window keeps it.
    lifetime.command(GrabCommand(window: 1, acted: false), session: 3, focus: 1, now: 101)
    #expect(lifetime.grab?.session == 3)
    lifetime.released(2)
    #expect(lifetime.grab?.session == 3)
    lifetime.released(3)
    #expect(lifetime.grab == nil)
}

@Test func timedGrabLastsASecondAfterItsLastCommand() {
    var lifetime = GrabLifetime()
    let state = SavedState.focused(1, windows: [1, 2])
    lifetime.command(GrabCommand(window: 1, acted: true), session: nil, focus: 1, now: 10)
    #expect(lifetime.grab?.until == 10 + GrabLifetime.timeout)
    lifetime.check(state, now: 10.9)
    #expect(lifetime.grab != nil)
    lifetime.command(GrabCommand(window: 1, acted: false), session: nil, focus: 1, now: 10.9)
    lifetime.check(state, now: 11.5)
    #expect(lifetime.grab?.until == 11.9)
    lifetime.check(state, now: 11.9)
    #expect(lifetime.grab == nil)
    // Releases never end a timed grab.
    lifetime.command(GrabCommand(window: 1, acted: true), session: nil, focus: 1, now: 20)
    lifetime.released(1)
    #expect(lifetime.grab != nil)
}

@Test func noOpsStartNothingAndLeaveAGrabOfAnotherWindowAlone() {
    var lifetime = GrabLifetime()
    lifetime.command(GrabCommand(window: 1, acted: false), session: 1, focus: 1, now: 0)
    #expect(lifetime.grab == nil)
    lifetime.command(GrabCommand(window: 1, acted: true), session: 1, focus: 1, now: 0)
    lifetime.command(GrabCommand(window: 2, acted: false), session: nil, focus: 1, now: 0.5)
    #expect(lifetime.grab == GrabLifetime.Grab(window: 1, session: 1, until: nil, focus: 1))
    // A no-op on the grabbed window from a binding makes a timed grab held.
    var timed = GrabLifetime()
    timed.command(GrabCommand(window: 1, acted: true), session: nil, focus: 1, now: 0)
    timed.command(GrabCommand(window: 1, acted: false), session: 4, focus: 1, now: 0.5)
    #expect(timed.grab == GrabLifetime.Grab(window: 1, session: 4, until: nil, focus: 1))
}

@Test func commandsWithoutModifiersKeepAHeldGrabOfTheirWindowAndTakeOverOthers() {
    var lifetime = GrabLifetime()
    lifetime.command(GrabCommand(window: 1, acted: true), session: 1, focus: 1, now: 0)
    lifetime.command(GrabCommand(window: 1, acted: true), session: nil, focus: 1, now: 5)
    #expect(lifetime.grab == GrabLifetime.Grab(window: 1, session: 1, until: nil, focus: 1))
    lifetime.command(GrabCommand(window: 2, acted: true), session: nil, focus: 2, now: 6)
    #expect(lifetime.grab == GrabLifetime.Grab(window: 2, session: nil, until: 7, focus: 2))
    lifetime.released(1)
    #expect(lifetime.grab?.window == 2)
    lifetime.command(GrabCommand(window: 2, acted: true), session: 2, focus: 2, now: 6.5)
    #expect(lifetime.grab == GrabLifetime.Grab(window: 2, session: 2, until: nil, focus: 2))
}

@Test(arguments: ["gone", "minimized", "appHidden", "hidden", "focus", "unfocused"])
func grabEndsWhenItsWindowGoesOrLosesFocus(_ change: String) {
    var state = SavedState.focused(1, windows: [1, 2])
    var lifetime = GrabLifetime()
    lifetime.command(GrabCommand(window: 1, acted: true), session: 1, focus: 1, now: 0)
    switch change {
    case "gone": state.windows[1] = nil
    case "minimized": state.windows[1]?.info.minimized = true
    case "appHidden": state.windows[1]?.info.appHidden = true
    case "hidden": state.windows[1]?.hidden = true
    case "focus": state.focus = 2
    default: state.focus = nil
    }
    lifetime.check(state, now: 0)
    #expect(lifetime.grab == nil)
}

@Test func grabOfAnUnfocusedWindowSurvivesUntilFocusMovesOn() {
    var state = SavedState.focused(2, windows: [1, 2, 3])
    var lifetime = GrabLifetime()
    lifetime.command(GrabCommand(window: 1, acted: true), session: nil, focus: 2, now: 0)
    lifetime.check(state, now: 0.5)
    #expect(lifetime.grab?.window == 1)
    // Focus moving to the grabbed window itself keeps it; moving on from there ends it.
    state.focus = 1
    lifetime.check(state, now: 0.6)
    #expect(lifetime.grab?.focus == 1)
    state.focus = 2
    lifetime.check(state, now: 0.7)
    #expect(lifetime.grab == nil)
    lifetime.command(GrabCommand(window: 1, acted: true), session: nil, focus: 2, now: 1)
    state.focus = 3
    lifetime.check(state, now: 1.1)
    #expect(lifetime.grab == nil)
}

@Test func outlineGoesOnTheTileOrTheFloatingFrameOnTheVisibleDesktop() throws {
    var e = engine(3)
    var current = scene(&e)
    let tile = try #require(current.displays["d"]?.frames[1])
    #expect(GrabPlacement.frame(of: 1, scene: current, state: e.savedState())?.frame == tile)
    #expect(GrabPlacement.frame(of: 1, scene: current, state: e.savedState())?.display == "d")
    _ = e.handle(.command(["window", "float", "2", "on"]))
    _ = e.handle(.command(["window", "resize", "2", "400x300"]))
    current = scene(&e)
    #expect(GrabPlacement.frame(of: 2, scene: current, state: e.savedState())?.frame == e.savedState().windows[2]?.info.frame)
    #expect(GrabPlacement.frame(of: 2, scene: current, state: e.savedState())?.frame.width == 400)
    // A tiled window without a tile, or on the stash, has no outline.
    var minimized = WindowInfo(id: 3, pid: 103, display: "d")
    minimized.minimized = true
    _ = e.handle(.windowUpdated(minimized))
    current = scene(&e)
    #expect(current.displays["d"]?.visible.contains(3) == true)
    #expect(GrabPlacement.frame(of: 3, scene: current, state: e.savedState()) == nil)
    _ = e.handle(.command(["window", "nudge", "1", "right"]))
    _ = e.handle(.command(["page", "prev"]))
    current = scene(&e)
    #expect(current.displays["d"]?.stashed.contains(1) == true)
    #expect(GrabPlacement.frame(of: 1, scene: current, state: e.savedState()) == nil)
    #expect(GrabPlacement.frame(of: 99, scene: current, state: e.savedState()) == nil)
}

@MainActor
private final class FakeOutline: GrabPresenting {
    var shown: [Rect] = []
    var hides = 0
    func show(_ frame: Rect) { shown.append(frame) }
    func hide() { hides += 1 }
}

@MainActor
private final class FakeTimer {
    var now: TimeInterval = 100
    var pending: [(delay: TimeInterval, work: @MainActor @Sendable () -> Void)] = []
    func fire() {
        let due = pending
        pending = []
        for item in due { item.work() }
    }
}

@MainActor
private func highlight() -> (GrabHighlight, FakeOutline, FakeTimer) {
    let outline = FakeOutline(), timer = FakeTimer()
    let highlight = GrabHighlight(presenter: outline, now: { timer.now }, schedule: { timer.pending.append(($0, $1)) })
    return (highlight, outline, timer)
}

@Test @MainActor func outlineFollowsMovesAndHidesWhileASlideCoversItsDisplay() throws {
    let (grab, outline, _) = highlight()
    var e = engine(3)
    grab.update(state: e.savedState(), scene: scene(&e), covered: { _ in false })
    #expect(outline.shown.isEmpty && outline.hides == 0)
    let resize = try #require(grabbing(&e, "window resize right"))
    grab.command(resize, session: 1, focus: e.savedState().focus)
    grab.update(state: e.savedState(), scene: scene(&e), covered: { _ in false })
    let wider = try #require(scene(&e).displays["d"]?.frames[1])
    #expect(outline.shown == [wider])
    // Unchanged, it is not drawn again.
    grab.update(state: e.savedState(), scene: scene(&e), covered: { _ in false })
    #expect(outline.shown == [wider])
    // A nudge onto a new page slides: hidden while covered, then on the new tile.
    let nudge = try #require(grabbing(&e, "window nudge right"))
    grab.command(nudge, session: 1, focus: e.savedState().focus)
    grab.update(state: e.savedState(), scene: scene(&e), covered: { $0 == "d" })
    #expect(outline.hides == 1)
    grab.update(state: e.savedState(), scene: scene(&e), covered: { _ in false })
    let alone = try #require(scene(&e).displays["d"]?.frames[1])
    #expect(outline.shown == [wider, alone])
    #expect(alone != wider)
    grab.released(1)
    grab.update(state: e.savedState(), scene: scene(&e), covered: { _ in false })
    #expect(grab.window == nil)
    #expect(outline.hides == 2)
}

@Test @MainActor func timedGrabSchedulesItsEndAndHidesWhenDue() {
    let (grab, outline, timer) = highlight()
    var e = engine(2)
    var updates = 0
    grab.due = { updates += 1; grab.update(state: e.savedState(), scene: scene(&e), covered: { _ in false }) }
    grab.command(GrabCommand(window: 1, acted: true), session: nil, focus: 1)
    #expect(timer.pending.map(\.delay) == [GrabLifetime.timeout])
    grab.update(state: e.savedState(), scene: scene(&e), covered: { _ in false })
    #expect(outline.shown.count == 1)
    timer.now += 0.5
    grab.command(GrabCommand(window: 1, acted: false), session: nil, focus: 1)
    timer.now += 0.5
    timer.fire()
    #expect(updates == 2)
    #expect(grab.window == 1 && outline.hides == 0)
    timer.now += 0.5
    grab.due?()
    #expect(grab.window == nil && outline.hides == 1)
    // A held grab needs no timer.
    grab.command(GrabCommand(window: 1, acted: true), session: 1, focus: 1)
    #expect(timer.pending.isEmpty)
}

@Test @MainActor func outlineSitsAboveWindowsAndBelowTheOtherPanels() {
    #expect(GrabPanel.level.rawValue > NSWindow.Level.normal.rawValue)
    #expect(GrabPanel.level.rawValue < TransitionOverlay.level.rawValue)
    #expect(GrabPanel.level.rawValue < DropPickerPanels.previewLevel.rawValue)
    #expect(GrabPanel.level.rawValue < NSWindow.Level.floating.rawValue)
    #expect(GrabPanel.level.rawValue < SwitcherPanel.level.rawValue)
}

@Test @MainActor func outlineIsALitLineInTheGapJustOutsideTheTile() {
    let tile = NSRect(x: 100, y: 200, width: 640, height: 480), width = PanelStyle.grab.width, reach = PanelStyle.grab.reach
    #expect(PanelStyle.grab.glow == PanelStyle.glow && width <= Config.default.gaps / 2)
    let frame = GrabPanel.frame(around: tile)
    let line = GrabOutlineView.line(in: NSRect(origin: .zero, size: frame.size))
    // The line runs from the tile's edge out into the gap, and the panel leaves its halo the reach past it.
    #expect(line.rect.offsetBy(dx: frame.minX, dy: frame.minY) == tile.insetBy(dx: -width, dy: -width))
    #expect(frame == tile.insetBy(dx: -(width + reach), dy: -(width + reach)))
    // Stroked half its width inside that rect, the line's corner is the tile's grown by the same distance.
    #expect(line.radius - width / 2 == GrabPanel.radius + width / 2)
}

private let arrows: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 49: "space", 48: "tab", 0: "a", 96: "f5"]

@Test func grabbingBindingHoldsUntilAnyOfItsModifiersIsReleased() {
    // No default Ctrl+Shift binding is non-grabbing, so add one.
    var bindings = Config.defaultBindings
    bindings[Chord(modifiers: [.ctrl, .shift], key: "space")] = ["page", "variant"]
    var router = KeyRouter(bindings: bindings, names: arrows)
    #expect(router.grabFlags([.ctrl, .shift]) == .pass)
    #expect(router.key(124, modifiers: [.ctrl, .shift], down: true) == .command(["window", "nudge", "right"], grab: 1))
    #expect(router.grab == KeyRouter.HeldGrab(session: 1, held: [.ctrl, .shift]))
    #expect(router.key(124, modifiers: [.ctrl, .shift], down: false) == .swallow)
    // Further presses while held continue it, carries included, and so does a binding that does not grab.
    #expect(router.key(123, modifiers: [.ctrl, .shift], down: true) == .command(["window", "nudge", "left"], grab: 1))
    #expect(router.key(125, modifiers: [.ctrl, .shift], down: true) == .command(["window", "move", "workspace", "next"], grab: 1))
    #expect(router.key(49, modifiers: [.ctrl, .shift], down: true) == .command(["page", "variant"]))
    #expect(router.grab?.session == 1)
    // Adding a modifier keeps it, and the switcher's check is not affected.
    #expect(router.grabFlags([.ctrl, .shift, .cmd]) == .pass)
    #expect(router.flags([.ctrl]) == .pass)
    #expect(router.grabFlags([.ctrl]) == .grabReleased(1))
    #expect(router.grab == nil)
    #expect(router.grabFlags([]) == .pass)
    #expect(router.key(124, modifiers: [.ctrl, .shift], down: true) == .command(["window", "nudge", "right"], grab: 2))
    #expect(router.grabFlags(.shift) == .grabReleased(2))
}

@Test func resizeRepeatsContinueTheGrabUntilItsModifiersChange() {
    var router = KeyRouter(bindings: Config.defaultBindings, names: arrows)
    let resize: KeyDecision = .command(["window", "resize", "right"], grab: 1)
    #expect(router.key(124, modifiers: [.ctrl, .alt], down: true) == resize)
    for _ in 0..<3 { #expect(router.key(124, modifiers: [.ctrl, .alt], down: true, autorepeat: true) == resize) }
    #expect(router.grabFlags(.ctrl) == .grabReleased(1))
    #expect(router.key(124, modifiers: .ctrl, down: true, autorepeat: true) == .swallow)
    #expect(router.grab == nil)
    // A held repeat after the release grabs again only when its chord still names a resize.
    var custom = KeyRouter(bindings: [Chord(modifiers: [.ctrl, .alt], key: "left"): ["window", "resize", "left"],
                                      Chord(modifiers: .alt, key: "left"): ["window", "resize", "left"]], names: arrows)
    #expect(custom.key(123, modifiers: [.ctrl, .alt], down: true) == .command(["window", "resize", "left"], grab: 1))
    #expect(custom.grabFlags(.alt) == .grabReleased(1))
    #expect(custom.key(123, modifiers: .alt, down: true, autorepeat: true) == .command(["window", "resize", "left"], grab: 2))
    #expect(custom.grab == KeyRouter.HeldGrab(session: 2, held: .alt))
}

@Test func dragKeysAndBindingsWithoutModifiersHoldNothing() {
    var dragging = KeyRouter(bindings: Config.defaultBindings, names: arrows, dragged: 42)
    #expect(dragging.key(123, modifiers: .ctrl, down: true) == .command(["window", "nudge", "42", "left"]))
    #expect(dragging.grab == nil)
    var bare = KeyRouter(bindings: [Chord(modifiers: [], key: "f5"): ["window", "nudge", "left"]], names: arrows)
    #expect(bare.key(96, modifiers: [], down: true) == .command(["window", "nudge", "left"]))
    #expect(bare.grab == nil)
}

@Test func openSwitcherSwallowsGrabbingBindingsAndBothReleasesAreReported() {
    var bindings = Config.defaultBindings
    bindings[Chord(modifiers: [.ctrl, .shift], key: "a")] = ["window", "nudge", "left"]
    bindings[Chord(modifiers: [.ctrl, .shift], key: "tab")] = ["switcher", "next"]
    var router = KeyRouter(bindings: bindings, names: arrows)
    router.switcherAvailable = true
    let session = router.open(.switcher)
    #expect(router.key(0, modifiers: [.ctrl, .shift], down: true) == .swallow)
    #expect(router.grab == nil)
    router.close(session)
    // A grab held when a binding opens the switcher ends with the same release that commits it.
    #expect(router.key(123, modifiers: [.ctrl, .shift], down: true) == .command(["window", "nudge", "left"], grab: 1))
    #expect(router.key(48, modifiers: [.ctrl, .shift], down: true) == .switcher(.open(forward: true, held: .ctrl), session: 2))
    #expect(router.key(123, modifiers: [.ctrl, .shift], down: true) == .switcher(.move(.left), session: 2))
    #expect(router.flags(.shift) == .switcher(.commit, session: 2))
    #expect(router.grabFlags(.shift) == .grabReleased(1))
}
