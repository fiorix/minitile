import Testing
@testable import MinitileCore

@Test func floatingRulesDoNotConsumeTileCapacityAndFollowTheirPage() {
    var e = engine(4, config: Config(floatApps: ["app.5"]))
    _ = e.handle(.windowAppeared(window(5)))
    var info = window(6)
    info.tileable = false
    let out = e.handle(.windowAppeared(info))
    #expect(grid(e) == [[[1, 2, 3, 4, 5, 6]]])
    #expect(out.scene.displays["primary"]?.frames.count == 4)
    #expect(e.savedState().windows[5]?.floating == true)
    #expect(e.savedState().windows[6]?.floating == true)
    let hidden = command(&e, "page next")
    #expect(hidden.scene.displays["primary"]?.stashed == [1, 2, 3, 4, 5, 6])
    #expect(e.handle(.command(["window", "float", "6", "off"])).reply?.ok == false)
}

@Test func unfloatSpillsIfPageIsFullAndExplicitOverrideSurvivesReload() {
    var e = engine(4)
    var info = window(5, frontmost: true)
    info.bundleID = "always.float"
    _ = e.handle(.configLoaded(Config(floatApps: ["always.float"])))
    _ = e.handle(.windowAppeared(info))
    command(&e, "window float off")
    #expect(grid(e) == [[[1, 2, 3, 4], [5]]])
    #expect(e.makeScene().displays["primary"]?.visible == [5])
    _ = e.handle(.configLoaded(Config(floatApps: ["always.float"])))
    #expect(e.savedState().windows[5]?.floating == false)
}

@Test func minimizedWindowsKeepSlotsAndUnminimizingShowsTheirPage() {
    var e = engine(4)
    var info = window(2)
    info.minimized = true
    let minimized = e.handle(.windowUpdated(info))
    #expect(grid(e) == [[[1, 2, 3, 4]]])
    #expect(minimized.scene.displays["primary"]?.frames[2] == nil)
    _ = e.handle(.windowAppeared(window(5)))
    #expect(grid(e) == [[[1, 2, 3, 4], [5]]])
    command(&e, "page next")
    info.minimized = false
    let restored = e.handle(.windowUpdated(info))
    #expect(restored.scene.displays["primary"]?.visible == [1, 2, 3, 4])
    #expect(restored.actions.last == .focus(2))
}

@Test func hiddenAppsRetainSlotsAndDoNotStealViewWhenUnhidden() {
    var e = engine(5)
    var info = window(1)
    info.appHidden = true
    _ = e.handle(.windowUpdated(info))
    #expect(e.makeScene().displays["primary"]?.frames[1] == nil)
    #expect(grid(e)[0][0] == [1, 2, 3, 4])
    command(&e, "page next")
    info.appHidden = false
    let out = e.handle(.windowUpdated(info))
    #expect(out.scene.displays["primary"]?.visible == [5])
    #expect(out.scene.displays["primary"]?.frames[1] != nil)
}

@Test func explicitHideFreesSlotAndShowUsesCurrentWorkspace() {
    var e = engine(4)
    command(&e, "window focus 2")
    let hidden = command(&e, "window hide")
    #expect(grid(e) == [[[1, 3, 4]]])
    #expect(hidden.scene.displays["primary"]?.stashed == [2])
    _ = e.handle(.windowAppeared(window(5)))
    #expect(grid(e) == [[[1, 3, 4, 5]]])
    command(&e, "workspace next")
    let shown = command(&e, "window show 2")
    #expect(grid(e) == [[[1, 3, 4, 5]], [[2]]])
    #expect(shown.actions.last == .focus(2))
}

@Test func onlyAppsIgnoresOtherAppsEntirely() {
    var e = engine(3, config: Config(onlyApps: ["app.2"]))
    #expect(Set(e.savedState().windows.keys) == [2])
    #expect(grid(e) == [[[2]]])
    var info = window(4)
    info.bundleID = nil
    #expect(!e.handle(.windowAppeared(info)).stateChanged)
    _ = e.handle(.configLoaded(Config(onlyApps: ["app.3"])))
    #expect(e.savedState().windows.isEmpty)
}

@Test func floatingResizeEmitsAnExplicitFrameAction() {
    var e = engine(1)
    command(&e, "window float 1 on")
    let out = command(&e, "window resize 1 640x480")
    #expect(out.actions == [.setFrame(1, Rect(x: 120, y: 80, width: 640, height: 480))])
    #expect(out.scene.displays["primary"]?.frames[1] == nil)
}

@Test func changedPIDReplacesWindowIdentity() {
    var e = engine(1)
    command(&e, "window hide 1")
    _ = e.handle(.windowUpdated(window(1, pid: 999)))
    #expect(e.savedState().windows[1]?.info.pid == 999)
    #expect(e.savedState().windows[1]?.hidden == false)
    #expect(grid(e) == [[[1]]])
}

@Test func minimizingFocusedWindowWaitsForNativeFocus() {
    var e = engine(2)
    command(&e, "window focus 1")
    var info = window(1)
    info.minimized = true
    let out = e.handle(.windowUpdated(info))
    #expect(out.actions.isEmpty)
    #expect(e.savedState().focus == nil)
    #expect(grid(e) == [[[1, 2]]])
    #expect(out.scene.displays["primary"]?.visible == [1, 2])
    #expect(out.events.allSatisfy { $0.type != "page_shown" })
}

@Test(arguments: [[WindowID(1), 2], [WindowID(2), 1]])
func hidingFocusedAppWaitsForNativeFocus(_ order: [WindowID]) {
    var e = Engine()
    let windows = [window(1, pid: 500), window(2, pid: 500), window(3)]
    _ = e.handle(.started(saved: nil, windows: windows, displays: [testDisplay], focus: 1))
    for id in order {
        var info = window(id, pid: 500)
        info.appHidden = true
        let out = e.handle(.windowUpdated(info))
        #expect(out.actions.isEmpty)
        #expect(out.scene.displays["primary"]?.visible == [1, 2, 3])
        #expect(out.events.allSatisfy { $0.type != "page_shown" })
    }
    #expect(e.savedState().focus == nil)
    #expect(grid(e) == [[[1, 2, 3]]])
    let out = e.handle(.focusChanged(3))
    #expect(e.savedState().focus == 3)
    #expect(out.actions.isEmpty)
}

@Test func explicitHideStillRefocusesRemainingWindow() {
    var e = engine(2)
    command(&e, "window focus 1")
    let out = command(&e, "window hide")
    #expect(out.actions == [.focus(2)])
    #expect(e.savedState().focus == 2)
}

@Test func configExclusionStillRefocusesRemainingWindow() {
    var e = engine(2)
    command(&e, "window focus 1")
    let out = e.handle(.configLoaded(Config(onlyApps: ["app.2"])))
    #expect(out.actions == [.focus(2)])
    #expect(e.savedState().focus == 2)
}

@Test func orderedOutWindowsLeaveTheirPageAndStayListed() {
    var e = engine(4)
    _ = e.handle(.focusChanged(2))
    var info = window(2)
    info.orderedOut = true
    let out = e.handle(.windowUpdated(info))
    #expect(grid(e) == [[[1, 3, 4]]])
    #expect(e.savedState().focus == nil)
    #expect(out.scene.displays["primary"]?.visible == [1, 3, 4])
    #expect(out.scene.displays["primary"]?.stashed == [])
    #expect(out.events.contains(Event(type: "window_moved", data: .number(2))))
    guard case .object(let record) = command(&e, "window info 2").reply?.data else { Issue.record("Expected window object"); return }
    #expect(record["ordered_out"] == .bool(true))
    #expect(record["page"] == .null)
    #expect(record["shown"] == .bool(false))
    for verb in ["show", "focus", "hide"] {
        #expect(e.handle(.command(["window", verb, "2"])).reply?.text == "Window 2 is ordered out by its app")
    }
    #expect(e.handle(.command(["window", "move", "2", "page", "next"])).reply?.ok == false)
    #expect(e.handle(.command(["window", "close", "2"])).actions == [.close(2)])
}

@Test func orderedInWindowsArePlacedLikeNewWindows() {
    var e = engine(4)
    var info = window(2, frontmost: true)
    info.orderedOut = true
    _ = e.handle(.windowUpdated(info))
    _ = e.handle(.windowAppeared(window(5)))
    command(&e, "page next")
    #expect(grid(e) == [[[1, 3, 4, 5], []]])
    info.orderedOut = false
    let out = e.handle(.windowUpdated(info))
    #expect(grid(e) == [[[1, 3, 4, 5], [2]]])
    #expect(out.scene.displays["primary"]?.visible == [2])
    #expect(e.savedState().focus == 2)
    #expect(out.events.contains(Event(type: "window_moved", data: .number(2))))
}

@Test func aWindowShownAgainBesideItsAppsFocusIsPlacedWithoutTakingTheViewOrTheFocus() {
    var e = engine(5)
    var info = window(5)
    info.orderedOut = true
    _ = e.handle(.windowUpdated(info))
    _ = e.handle(.focusChanged(1))
    #expect(grid(e) == [[[1, 2, 3, 4]]])
    // The shell reports a window that is not its app's focus, as the tab a detach leaves behind, with this flag off.
    info.orderedOut = false
    info.fromFrontmostApp = false
    let out = e.handle(.windowUpdated(info))
    #expect(grid(e) == [[[1, 2, 3, 4], [5]]])
    #expect(out.scene.displays["primary"]?.visible == [1, 2, 3, 4])
    #expect(e.savedState().focus == 1)
    #expect(out.actions.isEmpty)
}

@Test func closingLastWindowOnAShownPageDropsItAndFollowsFocusHistoryThenTopLeft() {
    var e = engine(4)
    // Four workspaces: W1:[1, 2], W2:[3], W3:[4], W4:[5], with 1 and 2 never focused, then 3 -> 4 -> 5.
    command(&e, "window move 3 workspace next")
    command(&e, "window move 4 workspace next")
    command(&e, "window move 4 workspace next")
    _ = e.handle(.windowAppeared(window(5, frontmost: true)))
    command(&e, "window move 5 workspace next")
    for id: WindowID in [1, 2, 3, 4, 5] { e.state.windows[id]?.lastFocused = 0 }
    command(&e, "window focus 3")
    command(&e, "window focus 4")
    command(&e, "window focus 5")
    #expect(grid(e) == [[[1, 2]], [[3]], [[4]], [[5]]])

    // Closing 5 drops W4 and shows W3 (4), leaving focus nil with no focus action so macOS can choose.
    let first = e.handle(.windowGone(5))
    #expect(grid(e) == [[[1, 2]], [[3]], [[4]]])
    #expect(first.scene.displays["primary"]?.visible == [4])
    #expect(e.savedState().focus == nil && first.actions.isEmpty)

    // Fallback focuses 4; closing 4 drops W3 and shows W2 (3); closing 3 drops W2 and falls back to W1:P1 ([1, 2]).
    let fallback4 = e.handle(.noFocusAfterClose)
    #expect(e.savedState().focus == 4 && fallback4.actions == [.focus(4)])
    _ = e.handle(.windowGone(4))
    #expect(grid(e) == [[[1, 2]], [[3]]])
    #expect(e.makeScene().displays["primary"]?.visible == [3])
    _ = e.handle(.windowGone(3))
    #expect(grid(e) == [[[1, 2]]])
    #expect(e.makeScene().displays["primary"]?.visible == [1, 2])
    let fallback1 = e.handle(.noFocusAfterClose)
    #expect(e.savedState().focus == 1 && fallback1.actions == [.focus(1)])
}

@Test func closingLastWindowKeepsADisplaysOnlyPageAndRespectsReservedAndSharedPages() {
    var e = engine(2)
    command(&e, "window nudge 2 right")
    // Closing 1 on a shared or hidden page: first make [1, 3] on P1 and [2] on P2.
    command(&e, "window focus 1")
    _ = e.handle(.windowAppeared(window(3, frontmost: true)))
    #expect(grid(e) == [[[1, 3], [2]]])
    // Shared shown page stays shown; hidden page closing its sole window leaves the shown page alone.
    _ = e.handle(.windowGone(3))
    #expect(grid(e) == [[[1], [2]]])
    #expect(e.makeScene().displays["primary"]?.visible == [1])
    let hiddenClose = e.handle(.windowGone(2))
    #expect(grid(e) == [[[1]]])
    #expect(!hiddenClose.events.contains { $0.type == "page_shown" })
    // The display's only page stays empty when its last window closes.
    let last = e.handle(.windowGone(1))
    #expect(grid(e) == [[[]]])
    #expect(last.actions.isEmpty && e.savedState().focus == nil)
    #expect(e.handle(.noFocusAfterClose).actions.isEmpty)
}

@Test func minimizedSlotsKeepTheirPageAndRankBehindFocusableWindows() {
    var e = engine(2)
    command(&e, "window nudge 2 right")
    _ = e.handle(.windowAppeared(window(3, frontmost: true)))
    command(&e, "window nudge 3 right")
    #expect(grid(e) == [[[1], [2], [3]]])
    // P1:[1], P2:[2], P3:[3]. Focus 2 more recently than 1, then minimize 2 and focus 3.
    command(&e, "window focus 1")
    command(&e, "window focus 2")
    var min2 = window(2)
    min2.minimized = true
    _ = e.handle(.windowUpdated(min2))
    command(&e, "window focus 3")
    // Closing 3 vacates P3 onto P1 ([1], focusable) rather than P2 ([2], minimized despite a newer stamp).
    let vacated = e.handle(.windowGone(3))
    #expect(grid(e) == [[[1], [2]]])
    #expect(vacated.scene.displays["primary"]?.visible == [1])
    // On a page that still holds a minimized slot, closing the other window keeps the page.
    command(&e, "page next")
    _ = e.handle(.windowAppeared(window(4, frontmost: true)))
    #expect(grid(e) == [[[1], [2, 4]]])
    _ = e.handle(.windowGone(4))
    #expect(grid(e) == [[[1], [2]]])
    #expect(e.savedState().displays[0].workspaces[0].currentPage == e.savedState().displays[0].workspaces[0].pages[1].id)
}

@Test func backgroundCloseOnAnotherDisplayPreservesActiveDisplayAndFallbackCrossesDisplays() {
    let other = DisplayInfo(id: "other", frame: Rect(x: -880, y: 80, width: 1000, height: 800))
    var e = Engine()
    _ = e.handle(.started(saved: nil, windows: [window(1, display: "other"), window(2, display: "other"), window(3, display: "primary")],
                          displays: [other, testDisplay], focus: 3))
    // Split other into two pages and show its second page, then return focus to 3 on primary.
    command(&e, "window nudge 2 right")
    command(&e, "window focus 3")
    #expect(grid(e, display: 0) == [[[1], [2]]])
    #expect(e.commandDisplay == "primary")
    // Window 2 closes in the background on other: other drops P2 for P1, while primary stays active and 3 keeps focus.
    let bg = e.handle(.windowGone(2))
    #expect(grid(e, display: 0) == [[[1]]])
    #expect(bg.scene.displays["other"]?.visible == [1])
    #expect(e.commandDisplay == "primary" && e.savedState().focus == 3)
    // While focus is held, noFocusAfterClose changes nothing; once 3 closes, it crosses to 1 on other.
    #expect(e.handle(.noFocusAfterClose).actions.isEmpty)
    _ = e.handle(.windowGone(3))
    #expect(grid(e, display: 1) == [[[]]])
    let fallback = e.handle(.noFocusAfterClose)
    #expect(e.savedState().focus == 1 && fallback.actions == [.focus(1)] && e.commandDisplay == "other")

    // With no focus history on either display, noFocusAfterClose prefers a window on the command display over display 0.
    var fresh = Engine()
    _ = fresh.handle(.started(saved: nil, windows: [window(10, display: "other"), window(20, display: "primary"), window(21, display: "primary")],
                              displays: [other, testDisplay], focus: 21))
    fresh.state.windows[10]?.lastFocused = 0
    fresh.state.windows[20]?.lastFocused = 0
    command(&fresh, "window nudge 21 right")
    _ = fresh.handle(.windowGone(21))
    let local = fresh.handle(.noFocusAfterClose)
    #expect(fresh.savedState().focus == 20 && local.actions == [.focus(20)] && fresh.commandDisplay == "primary")
}

@Test func closingASelectedTabAfterSlotTransferKeepsItsPage() {
    var e = engine(2)
    command(&e, "window nudge 2 right")
    #expect(grid(e) == [[[1], [2]]])
    // Tab 3 replaces 2 in its slot before 2 is reported gone.
    _ = e.handle(.windowTabSelected(previous: 2, window(3, pid: window(2).pid, frontmost: true)))
    let out = e.handle(.windowGone(2))
    #expect(grid(e) == [[[1], [3]]])
    #expect(out.scene.displays["primary"]?.visible == [3])
    #expect(e.savedState().focus == 3)
}
