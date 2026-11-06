import Testing
@testable import MinitileCore

@Test func inspectionCommandsExposeStableObjectsAndArrays() {
    var e = engine(5)
    command(&e, "window focus 2")
    let before = e.savedState()
    for noun in ["window", "page", "workspace", "display"] {
        let list = command(&e, "\(noun) list").reply!
        guard case .array(let rows) = list.data else { Issue.record("Expected array for \(noun) list"); continue }
        #expect(!rows.isEmpty)
        #expect(list.text.contains("  "))
        let info = command(&e, "\(noun) info").reply!
        guard case .object(let fields) = info.data else { Issue.record("Expected object for \(noun) info"); continue }
        #expect(fields["id"] != nil)
        #expect(info.text.contains("\n"))
    }
    #expect(e.savedState() == before)
    let info = command(&e, "window info 2").reply!
    if case .object(let fields) = info.data {
        #expect(fields["slot"] == .number(1))
        #expect(fields["workspace"] == .number(1))
        #expect(fields["page"] == .number(1))
        #expect(fields["focused"] == .bool(true))
        #expect(fields["bundle_id"] == .string("app.2"))
    }
    if case .object(let fields) = command(&e, "state").reply!.data {
        #expect(fields["focus"] == .number(2))
        if case .array(let windows) = fields["windows"] { #expect(windows.count == 5) }
        else { Issue.record("Expected window array") }
    } else { Issue.record("Expected state object") }
}

@Test func indexedAndRelativeAddressesUseOneBasedGridIndices() {
    var e = engine(9)
    _ = e.handle(.windowGone(4))
    command(&e, "page show 3")
    #expect(e.makeScene().displays["primary"]?.visible == [9])
    command(&e, "page show prev")
    #expect(e.makeScene().displays["primary"]?.visible == [5, 6, 7, 8])
    command(&e, "page variant 1")
    #expect(e.savedState().displays[0].workspaces[0].pages[0].variant == .twoByOneTall)
    #expect(e.makeScene().displays["primary"]?.visible == [5, 6, 7, 8])
    command(&e, "workspace new")
    _ = e.handle(.windowAppeared(window(10)))
    command(&e, "workspace show 1")
    #expect(e.makeScene().displays["primary"]?.visible == [5, 6, 7, 8])
}

@Test(arguments: ["wat", "debug spaces", "window wat 1", "page show 0", "page ratio nan", "page ratio 0.5 bad", "workspace variant", "display show", "window move 1 nowhere 2", "window swap 1 nope", "window resize 1 -2", "config reload extra"])
func malformedCommandsFailWithoutStateChanges(_ text: String) {
    var e = engine(2)
    command(&e, "window focus 1")
    let before = e.savedState()
    let out = e.handle(.command(text.split(separator: " ").map(String.init)))
    #expect(out.reply?.ok == false)
    #expect(out.reply?.text.isEmpty == false)
    #expect(out.reply?.data == .null)
    #expect(out.actions.isEmpty)
    #expect(e.savedState() == before)
}

@Test func helpAndLifecycleCommandsAreAvailableWithoutDisplays() {
    var e = Engine()
    #expect(command(&e, "help").reply?.text.contains("window resize") == true)
    #expect(command(&e, "help").reply?.text.contains("switcher next|prev|commit|cancel") == true)
    #expect(command(&e, "config reload").actions == [.reloadConfig])
    #expect(command(&e, "config open").actions == [.openConfig])
    #expect(command(&e, "quit").actions == [.quit])
    #expect(command(&e, "watch").reply?.ok == true)
    #expect(command(&e, "config info").reply?.text.contains("bindings:") == true)
    #expect(e.handle(.command(["debug", "spaces"])).reply?.ok == false)
    #expect(Engine.help.hasPrefix("help [show]\nignore\n"))
}

@Test func ignoreRepliesOKWithoutChangingAnything() {
    var e = engine(3)
    command(&e, "window focus 2")
    let before = e.savedState()
    let out = command(&e, "ignore")
    #expect(out.reply == Reply(text: "OK"))
    #expect(out.actions.isEmpty)
    #expect(out.events.isEmpty)
    #expect(out.rewrite.isEmpty)
    #expect(!out.stateChanged)
    #expect(e.savedState() == before)
    var empty = Engine()
    #expect(empty.handle(.command(["ignore"])).reply?.ok == true)
    #expect(e.handle(.command(["ignore", "extra"])).reply?.ok == false)
}

@Test func spatialFocusStaysOnPageAndUsesNearestWindow() {
    var e = engine(5)
    command(&e, "window focus 1")
    command(&e, "window focus right")
    #expect(e.savedState().focus == 2)
    command(&e, "window focus down")
    #expect(e.savedState().focus == 4)
    command(&e, "window focus left")
    #expect(e.savedState().focus == 3)
    command(&e, "window focus down")
    #expect(e.savedState().focus == 3)
}

@Test func commandsEmitExpectedEventsAndCloseIsOnlyAnAction() {
    var e = engine(1)
    #expect(e.handle(.windowAppeared(window(2))).events.contains { $0.type == "window_added" })
    #expect(command(&e, "window focus 2").events.contains { $0.type == "focus" })
    let moved = command(&e, "window nudge right")
    #expect(moved.events.contains { $0.type == "window_moved" })
    #expect(moved.events.contains { $0.type == "page_shown" })
    #expect(command(&e, "window close").actions == [.close(2)])
    #expect(e.savedState().windows[2] != nil)
    #expect(e.handle(.windowGone(2)).events.contains { $0.type == "window_removed" })
    #expect(e.handle(.configLoaded(.default)).events.contains { $0.type == "config_reloaded" })
    #expect(e.handle(.displaysChanged([testDisplay])).events.contains { $0.type == "display_changed" })
}

@Test func pageShownEventUsesIndicesAfterEmptyPageRemoval() {
    var e = engine(5)
    command(&e, "window focus 5")
    let out = command(&e, "window move 5 workspace next")
    let event = out.events.first { $0.type == "page_shown" }
    #expect(event?.data == .object(["display": .string("primary"), "workspace": .number(2), "page": .number(1)]))
}

@Test func everyDefaultBindingUsesAcceptedGrammar() {
    // The app shell answers switcher commands and help show, so the core grammar check skips them; the shell tests
    // cover them.
    for args in Config.default.bindings.values where args.first != "switcher" && args != ["help", "show"] {
        var e = engine(4)
        command(&e, "window focus 1")
        #expect(e.handle(.command(args)).reply?.ok == true)
    }
}

@Test func nextAndPreviousFocusWalkThePageInGridOrderAndWrap() {
    var e = engine(5)
    command(&e, "window focus 3")
    let out = command(&e, "window focus next")
    #expect(out.actions == [.focus(4)])
    #expect(out.events.contains { $0.type == "focus" })
    #expect(!out.events.contains { $0.type == "page_shown" })
    command(&e, "window focus next")
    #expect(e.savedState().focus == 1)
    command(&e, "window focus prev")
    #expect(e.savedState().focus == 4)
    command(&e, "window focus prev")
    #expect(e.savedState().focus == 3)
}

@Test func focusCyclingVisitsFloatingWindowsAfterTiles() {
    var e = engine(4)
    command(&e, "window float 2 on")
    command(&e, "window focus 1")
    var visited: [WindowID?] = []
    for _ in 0..<4 { command(&e, "window focus next"); visited.append(e.savedState().focus) }
    #expect(visited == [3, 4, 2, 1])
    command(&e, "window focus prev")
    #expect(e.savedState().focus == 2)
}

@Test func focusCyclingSkipsMinimizedAndAppHiddenWindows() {
    var e = engine(4)
    var minimized = window(2)
    minimized.minimized = true
    _ = e.handle(.windowUpdated(minimized))
    var hidden = window(3)
    hidden.appHidden = true
    _ = e.handle(.windowUpdated(hidden))
    command(&e, "window focus 1")
    command(&e, "window focus next")
    #expect(e.savedState().focus == 4)
    command(&e, "window focus next")
    #expect(e.savedState().focus == 1)
    command(&e, "window focus prev")
    #expect(e.savedState().focus == 4)
}

@Test func focusCyclingWithoutFocusPicksTheShownPagesFirstWindow() {
    var e = engine(6)
    command(&e, "page next")
    _ = e.handle(.focusChanged(nil))
    let out = command(&e, "window focus prev")
    #expect(out.actions == [.focus(5)])
    #expect(e.savedState().focus == 5)
    #expect(e.makeScene().displays["primary"]?.visible == [5, 6])
}

@Test func focusCyclingDoesNothingOnAnEmptyPageOrAlone() {
    var e = engine(5)
    command(&e, "window focus 5")
    var before = e.savedState()
    var out = command(&e, "window focus next")
    #expect(out.actions.isEmpty)
    #expect(out.events.isEmpty)
    #expect(e.savedState() == before)
    command(&e, "page next")
    #expect(e.savedState().focus == nil)
    before = e.savedState()
    out = command(&e, "window focus next")
    #expect(out.actions.isEmpty)
    #expect(e.savedState() == before)
}

@Test func focusCycleOrderWrapsInBothDirections() {
    let order: [WindowID] = [1, 2, 3]
    #expect(Engine.cycle(order, from: 3, step: 1) { _ in true } == 1)
    #expect(Engine.cycle(order, from: 1, step: -1) { _ in true } == 3)
    #expect(Engine.cycle(order, from: 1, step: 1) { $0 == 1 } == nil)
    #expect(Engine.cycle(order, from: nil, step: -1) { $0 != 1 } == 2)
    #expect(Engine.cycle([], from: nil, step: 1) { _ in true } == nil)
    #expect(Engine.cycle([7], from: 7, step: 1) { _ in true } == nil)
}
