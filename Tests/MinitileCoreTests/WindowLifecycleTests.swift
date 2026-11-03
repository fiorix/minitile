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
