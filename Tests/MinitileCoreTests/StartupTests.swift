import Foundation
import Testing
@testable import MinitileCore

@Test func savedStateRestoresGridRatiosFloatingHiddenAndFocusMemory() throws {
    var original = engine(6)
    command(&original, "page ratio 0.6 0.7")
    command(&original, "window float 3 on")
    command(&original, "page ratio 0.6 0.7")
    command(&original, "window hide 6")
    command(&original, "window focus 2")
    command(&original, "page next")
    command(&original, "page variant")
    let saved = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(original.savedState()))
    var restored = Engine()
    let out = restored.handle(.started(saved: saved, windows: saved.windows.values.map(\.info), displays: [testDisplay], focus: 5))
    #expect(grid(restored) == grid(original))
    #expect(out.scene == original.makeScene())
    #expect(restored.savedState().windows[3]?.floating == true)
    #expect(restored.savedState().windows[6]?.hidden == true)
    #expect(restored.savedState().displays[0].workspaces[0].pages[0].r1 == 0.6)
    #expect(command(&restored, "page prev").actions.last == .focus(2))
}

@Test func restoreDropsMissingWindowsAndTreatsChangedPIDAsNew() {
    var old = engine(3)
    command(&old, "window hide 2")
    var e = Engine()
    _ = e.handle(.started(saved: old.savedState(), windows: [window(2, pid: 999), window(3)], displays: [testDisplay], focus: nil))
    #expect(e.savedState().windows[1] == nil)
    #expect(e.savedState().windows[2]?.hidden == false)
    #expect(grid(e) == [[[3, 2]]])
}

@Test func startupAdoptsVisibleWindowsBeforeStashOnSeparatePages() {
    var stashed = window(1)
    stashed.onStash = true
    var frontmost = window(6, frontmost: true)
    frontmost.onStash = true
    var e = Engine()
    let out = e.handle(.started(saved: nil, windows: [stashed, window(2), frontmost, window(3), window(4), window(5)], displays: [testDisplay], focus: nil))
    #expect(grid(e) == [[[2, 3, 4, 5], [1, 6]]])
    #expect(out.scene.displays["primary"]?.visible == [2, 3, 4, 5])
    #expect(out.actions.isEmpty)
}

@Test func stashAdoptionDoesNotFillVisiblePagesFreeSlots() {
    var stash = window(2)
    stash.onStash = true
    var e = Engine()
    _ = e.handle(.started(saved: nil, windows: [stash, window(1)], displays: [testDisplay], focus: nil))
    #expect(grid(e) == [[[1], [2]]])
}

@Test func unknownWindowsUseFirstWorkspaceWithoutChangingSavedView() {
    var old = engine(1)
    command(&old, "workspace next")
    _ = old.handle(.windowAppeared(window(2)))
    var e = Engine()
    let out = e.handle(.started(saved: old.savedState(), windows: [window(1), window(2), window(3)], displays: [testDisplay], focus: nil))
    #expect(grid(e) == [[[1, 3]], [[2]]])
    #expect(out.scene.displays["primary"]?.visible == [2])
}

@Test func restartMergesMissingDisplaysAndRetainsHome() {
    let old = twoDisplays()
    var e = Engine()
    _ = e.handle(.started(saved: old.savedState(), windows: [window(1), window(2, display: "primary")], displays: [testDisplay], focus: nil))
    #expect(grid(e) == [[[1]], [[2]]])
    #expect(e.savedState().displays[0].workspaces[1].home == "secondary")
    _ = e.handle(.displaysChanged([testDisplay, secondDisplay]))
    #expect(grid(e, display: 1) == [[[2]]])
}

@Test func changedFloatConfigSpillsRestoredWindowsWithoutLosingAny() {
    var old = Engine(config: Config(floatApps: (1...9).map { "app.\($0)" }))
    _ = old.handle(.started(saved: nil, windows: (1...9).map { window(WindowID($0)) }, displays: [testDisplay], focus: nil))
    var e = Engine()
    _ = e.handle(.started(saved: old.savedState(), windows: (1...9).map { window(WindowID($0)) }, displays: [testDisplay], focus: nil))
    #expect(grid(e) == [[[1, 2, 3, 4], [5, 6, 7, 8], [9]]])
}

@Test func invalidSnapshotFallsBackToAdoptionAndDuplicateObservationsAreIgnored() {
    var saved = engine(2).savedState()
    saved.version = 99
    var e = Engine()
    _ = e.handle(.started(saved: saved, windows: [window(1), window(1), window(2)], displays: [testDisplay, testDisplay], focus: nil))
    #expect(grid(e) == [[[1, 2]]])
    #expect(e.savedState().displays.count == 1)
}

@Test func savedStateDecoderDefaultsNewFields() throws {
    let saved = try JSONDecoder().decode(SavedState.self, from: Data("{}".utf8))
    #expect(saved == SavedState())
}

@Test func orderedOutWindowsStayOffTheirPagesAtStartup() {
    let old = engine(3)
    var restored = window(2)
    restored.orderedOut = true
    var unknown = window(4)
    unknown.orderedOut = true
    var e = Engine()
    _ = e.handle(.started(saved: old.savedState(), windows: [window(1), restored, window(3), unknown], displays: [testDisplay], focus: nil))
    #expect(grid(e) == [[[1, 3]]])
    #expect(e.savedState().windows[2]?.info.orderedOut == true)
    #expect(e.savedState().windows[4]?.info.orderedOut == true)
}
