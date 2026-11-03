import Testing
@testable import MinitileCore

let testDisplay = DisplayInfo(id: "primary", frame: Rect(x: 120, y: 80, width: 1000, height: 800), isPrimary: true)
func window(_ id: WindowID, pid: Int32? = nil, frontmost: Bool = false, display: DisplayID? = "primary") -> WindowInfo {
    WindowInfo(id: id, pid: pid ?? Int32(id + 100), bundleID: "app.\(id)", appName: "App \(id)", title: "Window \(id)",
               frame: Rect(x: 120, y: 80, width: 400, height: 300), fromFrontmostApp: frontmost, display: display)
}
func engine(_ count: Int = 0, config: Config = .default) -> Engine {
    var engine = Engine(config: config)
    let windows = (0..<count).map { window(WindowID($0 + 1)) }
    _ = engine.handle(.started(saved: nil, windows: windows, displays: [testDisplay], focus: nil))
    return engine
}
func grid(_ engine: Engine, display: Int = 0) -> [[[WindowID]]] {
    engine.savedState().displays[display].workspaces.map { $0.pages.map(\.windows) }
}
@discardableResult
func command(_ engine: inout Engine, _ args: String) -> Output {
    let result = engine.handle(.command(args.split(separator: " ").map(String.init)))
    #expect(result.reply?.ok == true, Comment(rawValue: result.reply?.text ?? "missing reply"))
    return result
}

@Test func placementSpillsAndFrontmostAppFollows() {
    var e = engine(5)
    #expect(grid(e) == [[[1, 2, 3, 4], [5]]])
    #expect(e.makeScene().displays["primary"]?.visible == [1, 2, 3, 4])
    let out = e.handle(.windowAppeared(window(6, frontmost: true)))
    #expect(out.scene.displays["primary"]?.visible == [5, 6])
    #expect(out.actions.isEmpty)
    #expect(e.savedState().focus == 6)
}

@Test func closeReusesCurrentPageSlotWithoutPullingLaterWindows() {
    var e = engine(5)
    _ = e.handle(.windowGone(2))
    _ = e.handle(.windowAppeared(window(6)))
    #expect(grid(e) == [[[1, 3, 4, 6], [5]]])
    command(&e, "page next")
    _ = e.handle(.windowGone(3))
    _ = e.handle(.windowAppeared(window(7)))
    #expect(grid(e) == [[[1, 4, 6], [5, 7]]])
}

@Test func emptyPageExistsOnlyWhileViewed() {
    var e = engine(1)
    let before = e.savedState()
    command(&e, "page prev")
    #expect(e.savedState() == before)
    command(&e, "page next")
    #expect(grid(e) == [[[1], []]])
    command(&e, "page next")
    #expect(grid(e) == [[[1], []]])
    command(&e, "page prev")
    #expect(grid(e) == [[[1]]])
    command(&e, "page next")
    _ = e.handle(.windowAppeared(window(2)))
    #expect(grid(e) == [[[1], [2]]])
}

@Test func emptyWorkspaceExistsOnlyWhileViewed() {
    var e = engine(1)
    command(&e, "workspace prev")
    #expect(grid(e) == [[[1]]])
    command(&e, "workspace next")
    command(&e, "workspace next")
    #expect(grid(e) == [[[1]], [[]]])
    command(&e, "workspace prev")
    #expect(grid(e) == [[[1]]])
    command(&e, "workspace next")
    _ = e.handle(.windowAppeared(window(2)))
    #expect(grid(e) == [[[1]], [[2]]])
}

@Test func pageRemembersFocusAndWorkspaceRemembersPage() {
    var e = engine(6)
    command(&e, "window focus 3")
    command(&e, "page next")
    command(&e, "window focus 6")
    command(&e, "workspace next")
    _ = e.handle(.windowAppeared(window(7)))
    let out = command(&e, "workspace prev")
    #expect(out.scene.displays["primary"]?.visible == [5, 6])
    #expect(out.actions.last == .focus(6))
    #expect(command(&e, "page prev").actions.last == .focus(3))
}

@Test func externalFocusShowsHiddenPageWithoutFocusEcho() {
    var e = engine(5)
    let out = e.handle(.focusChanged(5))
    #expect(out.scene.displays["primary"]?.visible == [5])
    #expect(out.actions.isEmpty)
    #expect(e.savedState().focus == 5)
}

@Test func activationChoosesMostRecentWindowWithoutFocusAction() {
    var e = engine(9)
    for id: WindowID in [5, 9] {
        var info = window(id, pid: 500)
        info.appName = "Shared"
        _ = e.handle(.windowUpdated(info))
    }
    command(&e, "window focus 9")
    command(&e, "window focus 5")
    command(&e, "window focus 1")
    let out = e.handle(.appActivated(pid: 500))
    #expect(out.scene.displays["primary"]?.visible == [5, 6, 7, 8])
    #expect(out.actions.isEmpty)
    let before = e.savedState()
    _ = e.handle(.appActivated(pid: 500))
    #expect(e.savedState() == before)
}

@Test func activationWithoutFocusHistoryChoosesGridOrder() {
    var e = engine(9)
    for id: WindowID in [5, 9] { _ = e.handle(.windowUpdated(window(id, pid: 500))) }
    let out = e.handle(.appActivated(pid: 500))
    #expect(out.scene.displays["primary"]?.visible == [5, 6, 7, 8])
    #expect(out.actions.isEmpty)
}

@Test func closingFocusedWindowChoosesRemainingWindow() {
    var e = engine(2)
    command(&e, "window focus 1")
    let out = e.handle(.windowGone(1))
    #expect(out.actions == [.focus(2)])
    #expect(e.savedState().focus == 2)
    #expect(!e.handle(.windowGone(999)).stateChanged)
}
