import Foundation
import MinitileCore
import Testing
@testable import minitile

private let names: [UInt16: String] = [48: "tab", 123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 53: "escape", 0: "a", 96: "f5",
                                       12: "q"]
private let tab: UInt16 = 48, left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
private let enter: UInt16 = 36, escape: UInt16 = 53, q: UInt16 = 12

private func makeRouter(_ bindings: [Chord: [String]] = Config.defaultBindings) -> KeyRouter {
    var router = KeyRouter(bindings: bindings, names: names)
    router.switcherAvailable = true
    return router
}

@Test func switcherKeysPassUntilCmdTabOpensTheSwitcher() {
    var router = makeRouter()
    for code in [tab, left, up, enter, escape] {
        #expect(router.key(code, modifiers: [], down: true) == .pass)
        #expect(router.key(code, modifiers: [], down: false) == .pass)
    }
    #expect(router.key(tab, modifiers: .shift, down: true) == .pass)
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 1))
    #expect(router.key(tab, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.step(forward: true), session: 1))
    #expect(router.key(tab, modifiers: [.cmd, .shift], down: true) == .switcher(.step(forward: false), session: 1))
    #expect(router.key(tab, modifiers: [.cmd, .shift], down: false) == .swallow)
    let moves: [(UInt16, SwitcherDirection)] = [(left, .left), (right, .right), (up, .up), (down, .down)]
    for (code, direction) in moves {
        #expect(router.key(code, modifiers: .cmd, down: true) == .switcher(.move(direction), session: 1))
        #expect(router.key(code, modifiers: [], down: false) == .swallow)
    }
    #expect(router.key(0, modifiers: .cmd, down: true) == .swallow)
    #expect(router.key(0, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(96, modifiers: [], down: true) == .swallow)
    #expect(router.key(96, modifiers: [], down: false) == .swallow)
    #expect(router.key(escape, modifiers: .cmd, down: true) == .switcher(.cancel, session: 1))
    #expect(router.switcher == nil)
    #expect(router.key(escape, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(escape, modifiers: [], down: true) == .pass)
    #expect(router.key(left, modifiers: [], down: true) == .pass)
    #expect(router.key(tab, modifiers: [.cmd, .shift], down: true) == .switcher(.open(forward: false, held: .cmd), session: 2))
    #expect(router.key(enter, modifiers: [], down: true) == .switcher(.commit, session: 2))
    #expect(router.switcher == nil)
    #expect(router.key(enter, modifiers: [], down: false) == .swallow)
    #expect(router.key(enter, modifiers: [], down: true) == .pass)
}

@Test func openSwitcherRepeatsItsKeysWhileOtherBindingsStillFireOnce() {
    var router = makeRouter()
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 1))
    for _ in 0..<3 {
        #expect(router.key(tab, modifiers: .cmd, down: true, autorepeat: true) == .switcher(.step(forward: true), session: 1))
    }
    #expect(router.key(down, modifiers: .cmd, down: true) == .switcher(.move(.down), session: 1))
    #expect(router.key(down, modifiers: .cmd, down: true, autorepeat: true) == .switcher(.move(.down), session: 1))
    #expect(router.key(right, modifiers: .ctrl, down: true) == .switcher(.move(.right), session: 1))
    #expect(router.key(enter, modifiers: .cmd, down: true) == .switcher(.commit, session: 1))
    // Closed now: a Tab still held from the switcher keeps being swallowed without stepping or reopening.
    #expect(router.key(tab, modifiers: .cmd, down: true, autorepeat: true) == .swallow)
    #expect(router.key(right, modifiers: .ctrl, down: true, autorepeat: true) == .swallow)
    #expect(router.key(right, modifiers: .ctrl, down: false) == .swallow)
    #expect(router.key(right, modifiers: .ctrl, down: true) == .command(["page", "next"]))
    #expect(router.key(right, modifiers: .ctrl, down: true, autorepeat: true) == .swallow)
    // An unswallowed repeat of the binding, as when the tap starts mid-press, does not open the switcher.
    var fresh = makeRouter()
    #expect(fresh.key(tab, modifiers: .cmd, down: true, autorepeat: true) == .swallow)
    #expect(fresh.switcher == nil)
}

@Test func releasingTheBindingModifierCommitsAndShiftDoesNot() {
    var router = makeRouter()
    #expect(router.flags(.cmd) == .pass)
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 1))
    #expect(router.flags([.cmd, .shift]) == .pass)
    #expect(router.flags(.cmd) == .pass)
    #expect(router.flags(.shift) == .switcher(.commit, session: 1))
    #expect(router.switcher == nil)
    #expect(router.flags([]) == .pass)
    #expect(router.key(tab, modifiers: [.cmd, .shift], down: true) == .switcher(.open(forward: false, held: .cmd), session: 2))
    #expect(router.flags(.cmd) == .pass)
    #expect(router.flags([]) == .switcher(.commit, session: 2))
    var custom = makeRouter([Chord(modifiers: [.ctrl, .alt], key: "tab"): ["switcher", "next"],
                              Chord(modifiers: [], key: "f5"): ["switcher", "prev"]])
    #expect(custom.key(tab, modifiers: [.ctrl, .alt], down: true) == .switcher(.open(forward: true, held: [.ctrl, .alt]), session: 1))
    #expect(custom.flags([.ctrl, .alt, .shift]) == .pass)
    #expect(custom.flags(.ctrl) == .switcher(.commit, session: 1))
    // A binding without modifiers keeps the switcher open until Return or Esc; pressing it again steps.
    #expect(custom.key(96, modifiers: [], down: true) == .switcher(.open(forward: false, held: []), session: 2))
    #expect(custom.flags([]) == .pass)
    #expect(custom.key(96, modifiers: [], down: false) == .swallow)
    #expect(custom.key(96, modifiers: [], down: true) == .switcher(.step(forward: false), session: 2))
    #expect(custom.key(escape, modifiers: [], down: true) == .switcher(.cancel, session: 2))
}

@Test func quickCmdTabOpensAndCommitsWhicheverKeyIsReleasedFirst() {
    var router = makeRouter()
    #expect(router.flags(.cmd) == .pass)
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 1))
    #expect(router.key(tab, modifiers: .cmd, down: false) == .swallow)
    #expect(router.flags([]) == .switcher(.commit, session: 1))
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 2))
    #expect(router.flags([]) == .switcher(.commit, session: 2))
    #expect(router.key(tab, modifiers: [], down: false) == .swallow)
    #expect(router.key(tab, modifiers: [], down: true) == .pass)
}

@Test func cmdTabPassesToMacOSWhenTheSwitcherIsUnavailableOrUnbound() {
    var router = makeRouter()
    router.switcherAvailable = false
    #expect(router.key(tab, modifiers: .cmd, down: true) == .pass)
    #expect(router.key(tab, modifiers: .cmd, down: true, autorepeat: true) == .pass)
    #expect(router.key(tab, modifiers: .cmd, down: false) == .pass)
    #expect(router.key(tab, modifiers: [.cmd, .shift], down: true) == .pass)
    router.switcherAvailable = true
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 1))
    router.switcherAvailable = false
    #expect(router.switcher == nil)
    #expect(router.key(tab, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(left, modifiers: .cmd, down: true) == .pass)
    #expect(router.flags([]) == .pass)
    var bindings = Config.defaultBindings
    bindings[Chord(modifiers: .cmd, key: "tab")] = nil
    var unbound = makeRouter(bindings)
    #expect(unbound.key(tab, modifiers: .cmd, down: true) == .pass)
    #expect(unbound.key(tab, modifiers: [.cmd, .shift], down: true) == .switcher(.open(forward: false, held: .cmd), session: 1))
}

@Test func mainThreadSessionsOpenAndCloseTheRouterSwitcher() {
    var router = makeRouter()
    let session = router.open(.switcher)
    #expect(router.switcher == KeyRouter.OpenModal(kind: .switcher, session: 1, held: []))
    #expect(router.key(tab, modifiers: [], down: true) == .switcher(.step(forward: true), session: session))
    #expect(router.flags([]) == .pass)
    router.close(session)
    #expect(router.switcher == nil)
    #expect(router.key(tab, modifiers: [], down: false) == .swallow)
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 2))
    // A close for an older session leaves the one a key opened since.
    router.close(session)
    #expect(router.switcher?.session == 2)
    router.resetHeld()
    #expect(router.switcher?.session == 2)
    #expect(router.key(tab, modifiers: .cmd, down: false) == .pass)
    #expect(router.open(.switcher) == 3)
    #expect(router.flags([]) == .pass)
    router.close(3)
    #expect(router.switcher == nil)
}

@Test func qQuitsFromTheOpenSwitcherOncePerPress() {
    var router = makeRouter()
    #expect(router.key(q, modifiers: .cmd, down: true) == .pass)
    #expect(router.key(q, modifiers: .cmd, down: false) == .pass)
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 1))
    #expect(router.key(q, modifiers: .cmd, down: true) == .switcher(.quit, session: 1))
    // Held, it quits nothing more: the selection moves on as the app goes, and repeats would take the next ones too.
    #expect(router.key(q, modifiers: .cmd, down: true, autorepeat: true) == .swallow)
    #expect(router.key(q, modifiers: .cmd, down: false) == .swallow)
    // The switcher stays open, and another press quits again.
    #expect(router.switcher?.session == 1)
    #expect(router.key(q, modifiers: [], down: true) == .switcher(.quit, session: 1))
    #expect(router.key(q, modifiers: [], down: false) == .swallow)
    #expect(router.flags([]) == .switcher(.commit, session: 1))
    // Closed, Cmd+Q is the frontmost app's again; a Q still held from the switcher stays swallowed.
    #expect(router.key(q, modifiers: .cmd, down: true) == .pass)
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 2))
    #expect(router.key(q, modifiers: .cmd, down: true) == .switcher(.quit, session: 2))
    #expect(router.flags([]) == .switcher(.commit, session: 2))
    #expect(router.key(q, modifiers: [], down: true, autorepeat: true) == .swallow)
}

@MainActor
private final class FakePresenter: SwitcherPresenting {
    var shown: [SwitcherTarget] = []
    /// Each show's display and the display it slides from.
    var moves: [(display: DisplayID, from: DisplayID?)] = []
    var contents: [SwitcherContent] = []
    var hides = 0
    func show(_ content: SwitcherContent, display: DisplayID, from: DisplayID?) {
        shown.append(content.selected)
        moves.append((display, from))
        contents.append(content)
    }
    func hide() { hides += 1 }
}

@MainActor
private final class FakeClock {
    var pending: [(delay: TimeInterval, work: @MainActor @Sendable () -> Void)] = []
    func fire() {
        let due = pending
        pending = []
        for item in due { item.work() }
    }
}

@MainActor
private final class FakeApps {
    var running: [SwitcherApp] = []
}

@MainActor
private func controller(_ apps: FakeApps = FakeApps()) -> (WindowSwitcher, FakePresenter, FakeClock) {
    let presenter = FakePresenter(), clock = FakeClock()
    let switcher = WindowSwitcher(presenter: presenter, schedule: { clock.pending.append(($0, $1)) },
                                  names: { ["d": "Laptop", "e": "External"] }, apps: { apps.running })
    return (switcher, presenter, clock)
}

private func switcherState() -> SavedState {
    var state = SavedState()
    var page = PageState(id: 10)
    page.windows = [1, 2, 3]
    state.displays = [DisplayState(info: DisplayInfo(id: "d", frame: Rect(x: 0, y: 0, width: 1512, height: 982), isPrimary: true),
                                   workspaces: [WorkspaceState(id: 1, home: "d", pages: [page], currentPage: 10)], currentWorkspace: 1)]
    for id: WindowID in [1, 2, 3] {
        state.windows[id] = WindowState(info: WindowInfo(id: id, pid: Int32(id), display: "d"), display: "d", floating: false)
        state.windows[id]?.lastFocused = UInt64(10 - id)
    }
    state.focus = 1
    return state
}

@Test @MainActor func quickCmdTabCommitsWithoutEverShowingThePanel() {
    let (switcher, presenter, clock) = controller()
    #expect(switcher.open(session: 1, forward: true, held: true, state: switcherState(), display: "d", config: .default))
    #expect(switcher.held)
    #expect(clock.pending.map(\.delay) == [WindowSwitcher.showDelay])
    #expect(presenter.shown.isEmpty)
    // It opens on the focused window, 1, and a quick release goes back to 2, focused before it.
    #expect(switcher.selection?.selected == 1)
    #expect(switcher.commit() == 2)
    #expect(!switcher.isOpen)
    clock.fire()
    #expect(presenter.shown.isEmpty)
    #expect(presenter.hides == 0)
}

/// `switcherState` with `focus` focused last, after `recent` in order, most recent first; other windows never focused.
private func focusedState(_ focus: WindowID?, recent: [WindowID]) -> SavedState {
    var state = switcherState()
    for id: WindowID in [1, 2, 3] { state.windows[id]?.lastFocused = 0 }
    let stamps = (focus.map { [$0] } ?? []) + recent
    for (index, id) in stamps.enumerated() { state.windows[id]?.lastFocused = UInt64(stamps.count - index) }
    state.focus = focus
    return state
}

@Test @MainActor func quickCmdTabTogglesBetweenTheLastTwoWindows() {
    let (switcher, _, _) = controller()
    // 3 was focused before 1, so a quick Cmd+Tab skips 2, the next in the ring.
    #expect(switcher.open(session: 1, forward: true, held: true, state: focusedState(1, recent: [3, 2]), display: "d", config: .default))
    #expect(switcher.commit() == 3)
    // Focusing 3 stamps it, so the next quick Cmd+Tab comes back to 1.
    #expect(switcher.open(session: 2, forward: true, held: true, state: focusedState(3, recent: [1, 2]), display: "d", config: .default))
    #expect(switcher.commit() == 1)
}

@Test @MainActor func quickCmdTabWithoutHistoryAndQuickCmdShiftTabFollowTheRing() {
    let (switcher, _, _) = controller()
    // No other window focused before: the next window in the ring.
    #expect(switcher.open(session: 1, forward: true, held: true, state: focusedState(1, recent: []), display: "d", config: .default))
    #expect(switcher.commit() == 2)
    // Cmd+Shift+Tab goes to the window before in the ring, whatever was focused before.
    #expect(switcher.open(session: 2, forward: false, held: true, state: focusedState(2, recent: [3]), display: "d", config: .default))
    #expect(switcher.selection?.selected == 2)
    #expect(switcher.commit() == 1)
    #expect(switcher.open(session: 3, forward: false, held: true, state: focusedState(1, recent: []), display: "d", config: .default))
    #expect(switcher.commit() == 3)
}

@Test @MainActor func quickCmdTabAfterAStepOrAnArrowCommitsTheSelection() {
    let (switcher, presenter, _) = controller()
    // Cmd+Tab then Tab lands on 2, after the focused window, not on 3, focused before it.
    #expect(switcher.open(session: 1, forward: true, held: true, state: focusedState(1, recent: [3]), display: "d", config: .default))
    switcher.step(forward: true)
    #expect(switcher.commit() == 2)
    #expect(switcher.open(session: 2, forward: true, held: true, state: focusedState(1, recent: [3]), display: "d", config: .default))
    switcher.step(forward: false)
    #expect(switcher.commit() == 3)
    // 1 is the large left tile, beside the stacked 2 and 3, which tie; grid order picks 2.
    #expect(switcher.open(session: 3, forward: true, held: true, state: focusedState(1, recent: [3]), display: "d", config: .default))
    switcher.move(.right)
    #expect(switcher.commit() == 2)
    #expect(presenter.shown.isEmpty)
}

@Test @MainActor func aShownPanelCommitsTheCurrentWindowUntilTheSelectionMoves() {
    let (switcher, presenter, clock) = controller()
    #expect(switcher.open(session: 1, forward: true, held: true, state: focusedState(1, recent: [3]), display: "d", config: .default))
    clock.fire()
    #expect(presenter.shown == [1])
    #expect(switcher.commit() == 1)
    // Opened from mntl it shows at once, so its commit is the selection too.
    #expect(switcher.open(session: 2, forward: true, held: false, state: focusedState(1, recent: [3]), display: "d", config: .default))
    #expect(switcher.commit() == 1)
}

@Test @MainActor func quickCmdTabFollowsTheSelectedWindowClosing() {
    let (switcher, _, _) = controller()
    #expect(switcher.open(session: 1, forward: true, held: true, state: focusedState(2, recent: [1]), display: "d", config: .default))
    // 2 closes before the release: 3 takes the selection, but the quick Cmd+Tab still goes back to 1.
    var closed = focusedState(nil, recent: [1])
    closed.displays[0].workspaces[0].pages[0].windows = [1, 3]
    closed.windows[2] = nil
    #expect(switcher.update(state: closed, config: .default) == nil)
    #expect(switcher.selection?.selected == 3)
    #expect(switcher.commit() == 1)
}

@Test @MainActor func heldSwitcherShowsAfterTheDelayAndHidesBeforeCommitting() {
    let (switcher, presenter, clock) = controller()
    #expect(switcher.open(session: 1, forward: true, held: true, state: switcherState(), display: "d", config: .default))
    clock.fire()
    #expect(presenter.shown == [1])
    switcher.step(forward: true)
    #expect(presenter.shown == [1, 2])
    // An unchanged model does not redraw.
    #expect(switcher.update(state: switcherState(), config: .default) == nil)
    #expect(presenter.shown == [1, 2])
    #expect(switcher.commit() == 2)
    #expect(presenter.hides == 1)
    #expect(switcher.session == nil)
}

@Test @MainActor func switcherOpenedWithoutAHeldModifierShowsAtOnce() {
    let (switcher, presenter, clock) = controller()
    #expect(switcher.open(session: 4, forward: false, held: false, state: focusedState(3, recent: [1, 2]), display: "d", config: .default))
    #expect(clock.pending.isEmpty)
    #expect(presenter.shown == [3])
    // 3 is the lower right tile beside the large tile 1.
    switcher.move(.left)
    #expect(presenter.shown == [3, 1])
    switcher.cancel()
    #expect(presenter.hides == 1)
    #expect(!switcher.isOpen)
}

@Test @MainActor func switcherClosesWhenItHasNothingToOffer() {
    let (switcher, presenter, _) = controller()
    #expect(!switcher.open(session: 1, forward: true, held: false, state: SavedState(), display: "d", config: .default))
    var unmanaged = switcherState()
    unmanaged.displays[0].info.unmanagedReason = "No desktop pair"
    #expect(!switcher.open(session: 2, forward: true, held: false, state: unmanaged, display: "d", config: .default))
    #expect(!switcher.isOpen)
    #expect(switcher.isStale(2) && !switcher.isStale(3))
    #expect(switcher.open(session: 3, forward: true, held: false, state: switcherState(), display: "d", config: .default))
    var closed = switcherState()
    closed.displays[0].workspaces[0].pages[0].windows = []
    closed.windows = [:]
    #expect(switcher.update(state: closed, config: .default) == 3)
    #expect(presenter.hides == 1)
    #expect(!switcher.isOpen)
}

@Test @MainActor func modifierCheckBeforeShowingCanCommitFirst() {
    let (switcher, presenter, clock) = controller()
    var committed: SwitcherTarget?
    switcher.willShow = { committed = switcher.commit() }
    #expect(switcher.open(session: 1, forward: true, held: true, state: switcherState(), display: "d", config: .default))
    clock.fire()
    #expect(committed == 2)
    #expect(presenter.shown.isEmpty)
    #expect(!switcher.isOpen)
}

/// The windows of `switcherState` gone, so only the apps row is left.
private func emptyState() -> SavedState {
    var state = switcherState()
    state.displays[0].workspaces[0].pages[0].windows = []
    state.windows = [:]
    state.focus = nil
    return state
}

@Test @MainActor func switcherStepsFromTheWindowsIntoTheAppsRowAndFollowsIt() {
    let apps = FakeApps()
    apps.running = [SwitcherApp(pid: 1, name: "One"), SwitcherApp(pid: 7, name: "Seven"), SwitcherApp(pid: 8, name: "Eight")]
    let (switcher, presenter, _) = controller(apps)
    let state = focusedState(3, recent: [1, 2])
    #expect(switcher.open(session: 1, forward: false, held: false, state: state, display: "d", config: .default))
    #expect(presenter.shown == [3])
    #expect(presenter.contents.last?.apps.map(\.pid) == [7, 8])
    switcher.step(forward: true)
    #expect(presenter.shown == [3, .app(7)])
    #expect(presenter.contents.last?.app == "Seven" && presenter.contents.last?.title == "No window in the grid")
    #expect(presenter.moves.last?.display == "d")
    // The app quits: the next one takes the selection, and the row redraws without it.
    apps.running.remove(at: 1)
    #expect(switcher.update(state: state, config: .default) == nil)
    #expect(presenter.shown == [3, .app(7), .app(8)])
    #expect(presenter.contents.last?.apps.map(\.pid) == [8])
    #expect(switcher.commit() == .app(8))
    #expect(presenter.hides == 1)
}

@Test @MainActor func quickCmdTabNeverOpensAnApp() {
    let apps = FakeApps()
    apps.running = [SwitcherApp(pid: 7, name: "Seven")]
    let (switcher, presenter, clock) = controller(apps)
    // With no window anywhere the first selection is an app, which a release before the panel shows leaves alone.
    #expect(switcher.open(session: 1, forward: true, held: true, state: emptyState(), display: "d", config: .default))
    #expect(switcher.selection?.selected == .app(7))
    #expect(switcher.commit() == nil)
    #expect(!switcher.isOpen && presenter.shown.isEmpty)
    // Once the panel shows, releasing opens the app.
    #expect(switcher.open(session: 2, forward: true, held: true, state: emptyState(), display: "d", config: .default))
    clock.fire()
    #expect(presenter.shown == [.app(7)])
    #expect(switcher.commit() == .app(7))
    // The last app quitting with no window left closes the switcher.
    #expect(switcher.open(session: 3, forward: true, held: false, state: emptyState(), display: "d", config: .default))
    apps.running = []
    #expect(switcher.update(state: emptyState(), config: .default) == 3)
    #expect(!switcher.isOpen)
    #expect(!switcher.open(session: 4, forward: true, held: false, state: emptyState(), display: "d", config: .default))
}

@Test func switcherDefaultBindingsUseShellVerbs() {
    #expect(Config.defaultBindings[Chord(modifiers: .cmd, key: "tab")] == ["switcher", "next"])
    #expect(Config.defaultBindings[Chord(modifiers: [.cmd, .shift], key: "tab")] == ["switcher", "prev"])
    #expect(Engine.help.contains("switcher next|prev|commit|cancel"))
}

/// Display "d" with windows 1 and 2, and display "e" above it with window 3, so the ring is 3, 1, 2.
private func twoDisplayState(focus: WindowID? = 2) -> SavedState {
    var state = switcherState()
    state.displays[0].workspaces[0].pages[0].windows = [1, 2]
    var page = PageState(id: 20)
    page.windows = [3]
    state.displays.append(DisplayState(info: DisplayInfo(id: "e", frame: Rect(x: 0, y: -982, width: 1512, height: 982)),
                                       workspaces: [WorkspaceState(id: 2, home: "e", pages: [page], currentPage: 20)], currentWorkspace: 2))
    state.windows[3] = WindowState(info: WindowInfo(id: 3, pid: 3, display: "e"), display: "e", floating: false)
    state.focus = focus
    state.activeDisplay = "d"
    return state
}

@Test @MainActor func switcherPanelStartsOnTheActiveDisplayAndSlidesToTheSelections() {
    let (switcher, presenter, clock) = controller()
    // Nothing is focused on the active display "d", and 3 on "e" was focused last, so the selection starts on "e".
    var state = twoDisplayState(focus: nil)
    state.windows[3]?.lastFocused = 20
    #expect(switcher.open(session: 1, forward: true, held: true, state: state, display: "d", config: .default))
    clock.fire()
    #expect(presenter.shown == [3])
    #expect(presenter.moves.map(\.display) == ["e"] && presenter.moves.map(\.from) == ["d"])
    #expect(presenter.contents.last?.displayName == "External")
    // Tab moves back to "d", sliding from "e"; another Tab stays there.
    switcher.step(forward: true)
    switcher.step(forward: true)
    #expect(presenter.shown == [3, 1, 2])
    #expect(presenter.moves.map(\.display) == ["e", "d", "d"] && presenter.moves.map(\.from) == ["d", "e", "d"])
    #expect(presenter.contents.last?.displayName == "Laptop")
    // Up crosses to "e" and Down comes back.
    switcher.move(.up)
    switcher.move(.down)
    #expect(presenter.shown == [3, 1, 2, 3, 1])
    #expect(presenter.moves.suffix(2).map(\.from) == ["d", "e"])
    #expect(switcher.commit() == 1)
}

@Test @MainActor func switcherPanelMovesWhenTheSelectionsDisplayGoesAway() {
    let (switcher, presenter, _) = controller()
    #expect(switcher.open(session: 1, forward: true, held: false, state: twoDisplayState(focus: 3), display: "d", config: .default))
    #expect(presenter.moves.last?.display == "e")
    // "e" is unplugged and its window closes: the selection moves on to 1, on "d", and the panel with it.
    var gone = twoDisplayState()
    gone.displays.removeLast()
    gone.windows[3] = nil
    #expect(switcher.update(state: gone, config: .default) == nil)
    #expect(presenter.shown == [3, 1])
    #expect(presenter.moves.last?.display == "d" && presenter.moves.last?.from == "e")
    // With one managed display left, the header no longer names it.
    #expect(presenter.contents.last?.displayName == nil)
    #expect(switcher.isOpen)
}

@Test func panelSlideEasesFromTheMiddleOfOneDisplayToTheOther() {
    let laptop = CGRect(x: 0, y: 0, width: 2056, height: 1290), external = CGRect(x: -908, y: 1329, width: 3840, height: 2135)
    let size = CGSize(width: 1201, height: 701)
    let start = PanelSlide.frame(size, centeredOn: CGPoint(x: laptop.midX, y: laptop.midY))
    let end = PanelSlide.frame(size, centeredOn: CGPoint(x: external.midX, y: external.midY))
    #expect(start == CGRect(x: 428, y: 295, width: 1201, height: 701))
    #expect(end.size == size && abs(end.midX - external.midX) <= 0.5 && abs(end.midY - external.midY) <= 0.5)
    #expect(PanelSlide.origin(from: start.origin, to: end.origin, elapsed: 0) == start.origin)
    let middle = PanelSlide.origin(from: start.origin, to: end.origin, elapsed: PanelSlide.duration / 2)
    #expect(abs(middle.x - (start.minX + end.minX) / 2) < 1e-9 && abs(middle.y - (start.minY + end.minY) / 2) < 1e-9)
    #expect(PanelSlide.origin(from: start.origin, to: end.origin, elapsed: PanelSlide.duration) == end.origin)
    #expect(PanelSlide.origin(from: start.origin, to: end.origin, elapsed: 5) == end.origin)
    // Eased: slow at both ends, always moving on.
    let steps = stride(from: 0.0, through: PanelSlide.duration, by: PanelSlide.duration / 10).map {
        PanelSlide.origin(from: start.origin, to: end.origin, elapsed: $0).y
    }
    #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
    #expect(steps[1] - steps[0] < steps[6] - steps[5])
    #expect(PanelSlide.duration == 0.25)
}
