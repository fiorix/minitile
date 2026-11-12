import Foundation
import Testing
@testable import MinitileCore

@discardableResult
private func setFullscreen(_ e: inout Engine, _ id: WindowID, _ value: Bool = true) -> Output {
    var info = e.savedState().windows[id]!.info
    info.fullscreen = value
    return e.handle(.windowUpdated(info))
}

/// Windows 1, 2 and 3 on one page, with 2 focused and then full screen.
private func fullscreenSecond() -> Engine {
    var e = engine(3)
    command(&e, "window focus 2")
    setFullscreen(&e, 2)
    return e
}

private func focusActions(_ output: Output) -> [Action] {
    output.actions.filter { if case .focus = $0 { true } else { false } }
}

@Test func windowSharingItsPageTakesAPageOfItsOwnWhenItGoesFullScreen() {
    var e = engine(3)
    command(&e, "window focus 2")
    let out = setFullscreen(&e, 2)
    #expect(grid(e) == [[[1, 3], [2]]])
    let scene = out.scene.displays["primary"]
    #expect(scene?.label == "1:2")
    // minitile leaves the window where macOS put it: no desktop and no frame.
    #expect(scene?.visible == [])
    #expect(scene?.stashed == [1, 3])
    #expect(scene?.frames[2] == nil)
    #expect(scene?.frames[1] != nil)
    #expect(e.savedState().focus == 2)
    #expect(focusActions(out).isEmpty)
    #expect(out.events.contains(Event(type: "window_moved", data: .number(2))))
    #expect(out.events.contains { $0.type == "page_shown" })
}

@Test func windowAloneOnItsPageStaysThereWhenItGoesFullScreen() {
    var e = engine(1)
    let out = setFullscreen(&e, 1)
    #expect(grid(e) == [[[1]]])
    #expect(out.scene.displays["primary"]?.visible == [])
    #expect(out.scene.displays["primary"]?.stashed == [])
    #expect(out.scene.displays["primary"]?.frames.isEmpty == true)
    #expect(!out.events.contains { $0.type == "window_moved" })
}

@Test func windowLeavingFullScreenIsTiledOnItsOwnPage() {
    var e = fullscreenSecond()
    let out = setFullscreen(&e, 2, false)
    #expect(grid(e) == [[[1, 3], [2]]])
    let scene = out.scene.displays["primary"]
    #expect(scene?.visible == [2])
    #expect(scene?.stashed == [1, 3])
    #expect(scene?.frames[2] == Rect(x: 128, y: 88, width: 984, height: 784))
    #expect(scene?.label == "1:2")
}

@Test func windowLeavingFullScreenOnAHiddenPageStaysHidden() {
    var e = fullscreenSecond()
    command(&e, "page prev")
    let out = setFullscreen(&e, 2, false)
    #expect(out.scene.displays["primary"]?.visible == [1, 3])
    #expect(out.scene.displays["primary"]?.stashed == [2])
    #expect(out.scene.displays["primary"]?.label == "1:1")
}

@Test func fullScreenPageIsReachedAndLeftLikeAnyOther() {
    var e = fullscreenSecond()
    let left = command(&e, "page prev")
    #expect(left.scene.displays["primary"]?.visible == [1, 3])
    #expect(left.scene.displays["primary"]?.stashed == [])
    #expect(focusActions(left) == [.focus(1)])
    // Focusing the window is what makes macOS show its Space.
    let back = command(&e, "page next")
    #expect(back.scene.displays["primary"]?.visible == [])
    #expect(back.scene.displays["primary"]?.stashed == [1, 3])
    #expect(focusActions(back) == [.focus(2)])
}

@Test func windowOnAHiddenPageShowsItsPageWhenItGoesFullScreen() {
    var e = engine(6)
    #expect(grid(e) == [[[1, 2, 3, 4], [5, 6]]])
    let out = setFullscreen(&e, 5)
    #expect(grid(e) == [[[1, 2, 3, 4], [6], [5]]])
    #expect(out.scene.displays["primary"]?.label == "1:3")
    #expect(out.scene.displays["primary"]?.stashed == [1, 2, 3, 4, 6])
    #expect(e.savedState().focus == 5)
}

@Test func newWindowsSkipAFullScreenPage() {
    var e = fullscreenSecond()
    let background = e.handle(.windowAppeared(window(4)))
    #expect(grid(e) == [[[1, 3], [2], [4]]])
    #expect(background.scene.displays["primary"]?.label == "1:2")
    var floating = window(5)
    floating.tileable = false
    _ = e.handle(.windowAppeared(floating))
    #expect(grid(e) == [[[1, 3], [2], [4, 5]]])
    let frontmost = e.handle(.windowAppeared(window(6, frontmost: true)))
    #expect(grid(e) == [[[1, 3], [2], [4, 5, 6]]])
    #expect(frontmost.scene.displays["primary"]?.label == "1:3")
}

@Test func windowThatAppearsFullScreenGetsAnEmptyPage() {
    var e = engine(2)
    var info = window(3, frontmost: true)
    info.fullscreen = true
    let out = e.handle(.windowAppeared(info))
    #expect(grid(e) == [[[1, 2], [3]]])
    #expect(out.scene.displays["primary"]?.visible == [])
    #expect(out.scene.displays["primary"]?.stashed == [1, 2])
}

@Test func movesPassOverAFullScreenPage() {
    var e = fullscreenSecond()
    _ = e.handle(.windowAppeared(window(4)))
    #expect(grid(e) == [[[1, 3], [2], [4]]])
    command(&e, "window nudge 4 left")
    #expect(grid(e) == [[[1, 3, 4], [2]]])
    // An explicit move to the page spills to the right of it, as onto a full page.
    command(&e, "window move 4 page 2")
    #expect(grid(e) == [[[1, 3], [2], [4]]])
    command(&e, "window nudge 1 right")
    #expect(grid(e) == [[[3], [1], [2], [4]]])
    command(&e, "window nudge 1 right")
    #expect(grid(e) == [[[3], [2], [4, 1]]])
}

@Test(arguments: ["window nudge 2 left", "window move 2 left", "window move 2 page 1", "window move 2 workspace next",
                  "window float 2", "window hide 2", "window resize 2 0.5", "window resize 2 left", "window swap 2 1",
                  "window swap 1 2", "window swap 2 next", "window place 2 standard 0"])
func fullScreenWindowKeepsItsPage(_ args: String) {
    var e = fullscreenSecond()
    let before = e.savedState()
    let out = e.handle(.command(args.split(separator: " ").map(String.init)))
    #expect(out.reply?.ok == false)
    #expect(e.savedState() == before)
}

@Test func fullScreenWindowCanBeInspectedFocusedAndClosed() {
    var e = fullscreenSecond()
    command(&e, "page prev")
    let shown = command(&e, "window show 2")
    #expect(shown.scene.displays["primary"]?.label == "1:2")
    #expect(focusActions(shown) == [.focus(2)])
    #expect(focusActions(command(&e, "window focus 2")) == [.focus(2)])
    guard case .object(let record)? = command(&e, "window info 2").reply?.data else { Issue.record("Expected a window record"); return }
    #expect(record["fullscreen"] == .bool(true))
    #expect(record["page"] == .number(2))
    #expect(record["shown"] == .bool(true))
    #expect(command(&e, "window close 2").actions.contains(.close(2)))
}

@Test func floatingWindowTakesAPageOfItsOwnWhenItGoesFullScreen() {
    var e = engine(2, config: Config(floatApps: ["app.2"]))
    #expect(e.savedState().windows[2]?.floating == true)
    let out = setFullscreen(&e, 2)
    #expect(grid(e) == [[[1], [2]]])
    #expect(out.scene.displays["primary"]?.visible == [])
    #expect(out.scene.displays["primary"]?.stashed == [1])
}

@Test func windowFoundFullScreenAtStartupIsMovedToAPageOfItsOwn() {
    let saved = engine(3).savedState()
    var observed = (1...3).map { window(WindowID($0)) }
    observed[1].fullscreen = true
    var e = Engine()
    let out = e.handle(.started(saved: saved, windows: observed, displays: [testDisplay], focus: 2))
    #expect(grid(e) == [[[1, 3], [2]]])
    #expect(out.scene.displays["primary"]?.label == "1:2")
    #expect(out.scene.displays["primary"]?.stashed == [1, 3])
    #expect(e.savedState().focus == 2)

    var unfocused = Engine()
    let kept = unfocused.handle(.started(saved: saved, windows: observed, displays: [testDisplay], focus: 1))
    #expect(grid(unfocused) == [[[1, 3], [2]]])
    #expect(kept.scene.displays["primary"]?.label == "1:1")
    #expect(kept.scene.displays["primary"]?.visible == [1, 3])
}

@Test func carriedWindowSkipsAFullScreenPageOnTheOtherDisplay() {
    var e = twoDisplays()
    command(&e, "window focus 2")
    setFullscreen(&e, 2)
    command(&e, "window move 1 display secondary")
    #expect(grid(e, display: 1) == [[[2], [1]]])
    #expect(e.makeScene().displays["secondary"]?.visible == [1])
}

@Test func savedWindowsLeaveOutTheFullScreenObservation() throws {
    var info = window(1)
    info.fullscreen = true
    let data = try JSONEncoder().encode(info)
    #expect(!String(decoding: data, as: UTF8.self).contains("fullscreen"))
    #expect(try JSONDecoder().decode(WindowInfo.self, from: data).fullscreen == false)
}
