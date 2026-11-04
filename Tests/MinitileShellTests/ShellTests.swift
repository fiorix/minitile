import Foundation
import CoreGraphics
import MinitileCore
import Testing
@testable import minitile

@Test func cocoaCoordinatesUsePrimaryHeightOnEveryScreen() {
    #expect(Geometry.cgFrame(CGRect(x: -1200, y: -200, width: 1200, height: 900), primaryHeight: 1000)
            == Rect(x: -1200, y: 300, width: 1200, height: 900))
    #expect(Geometry.cgFrame(CGRect(x: 0, y: 1000, width: 800, height: 1200), primaryHeight: 1000)
            == Rect(x: 0, y: -1200, width: 800, height: 1200))
}

@Test func frameReadbackAllowsCellGridRoundingButNotWrongTiles() {
    let target = Rect(x: 8, y: 38, width: 500, height: 600)
    #expect(Geometry.near(target, Rect(x: 8, y: 38, width: 480, height: 590), tolerance: 20))
    #expect(!Geometry.near(target, Rect(x: 508, y: 38, width: 500, height: 600), tolerance: 20))
}

@Test func showEveryDisplayBeforeHidingAnyPage() {
    let rect = Rect(x: 0, y: 0, width: 1000, height: 800)
    let displays = [DisplayInfo(id: "b", frame: rect, visibleSpace: 30, stashSpace: 40),
                    DisplayInfo(id: "a", frame: rect, visibleSpace: 10, stashSpace: 20)]
    let scene = Scene(displays: ["a": DisplayScene(visible: [1], stashed: [2]),
                                 "b": DisplayScene(visible: [3], stashed: [4])])
    let moves = ReconcilePlan.moves(scene: scene, displays: displays, known: [1, 2, 3, 4], spaces: [1: 20, 2: 10, 3: 40, 4: 30])
    #expect(moves == [SpaceMove(windows: [1], space: 10), SpaceMove(windows: [3], space: 30),
                      SpaceMove(windows: [2], space: 20), SpaceMove(windows: [4], space: 40)])
}

@Test func reconciliationDoesNotMoveUnknownOrAlreadyPlacedWindows() {
    let display = DisplayInfo(id: "a", frame: Rect(x: 0, y: 0, width: 1000, height: 800), visibleSpace: 10, stashSpace: 20)
    let scene = Scene(displays: ["a": DisplayScene(visible: [1, 99], stashed: [2, 3])])
    #expect(ReconcilePlan.moves(scene: scene, displays: [display], known: [1, 2, 3], spaces: [1: 10, 2: 20])
            == [SpaceMove(windows: [3], space: 20)])
    var unmanaged = display
    unmanaged.unmanagedReason = "No desktop pair"
    #expect(ReconcilePlan.moves(scene: scene, displays: [unmanaged], known: [1, 2, 3], spaces: [:]).isEmpty)
}

@Test func nativeArrowFlagsDoNotChangeBindings() {
    let flags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad, .maskAlphaShift]
    #expect(KeyRouter.modifiers(flags) == .ctrl)
    var router = KeyRouter(bindings: Config.defaultBindings, names: [123: "left"])
    #expect(router.key(123, modifiers: KeyRouter.modifiers(flags), down: true) == .command(["page", "prev"]))
    #expect(router.key(123, modifiers: [], down: false) == .swallow)
}

@Test func smokeConfigRoutesEveryControlShiftArrowAndRetainsKeyUp() throws {
    let config = try Config.parse("only_apps = [\"com.apple.TextEdit\"]\npadding = 8\ngaps = 8\n")
    let arrows: [(UInt16, String, [String])] = [
        (123, "left", ["window", "nudge", "left"]),
        (124, "right", ["window", "nudge", "right"]),
        (125, "down", ["window", "move", "workspace", "next"]),
        (126, "up", ["window", "move", "workspace", "prev"]),
    ]
    let flags: CGEventFlags = [.maskControl, .maskShift, .maskSecondaryFn, .maskNumericPad, .maskAlphaShift]
    #expect(KeyRouter.modifiers(flags) == [.ctrl, .shift])
    for (code, name, expected) in arrows {
        for releasedFlags: CGEventFlags in [[.maskControl, .maskSecondaryFn, .maskNumericPad], []] {
            var router = KeyRouter(bindings: config.bindings, names: [code: name])
            #expect(router.key(code, modifiers: KeyRouter.modifiers(flags), down: true) == .command(expected, grab: 1))
            #expect(router.key(code, modifiers: KeyRouter.modifiers(releasedFlags), down: false) == .swallow)
            #expect(router.key(code, modifiers: [], down: false) == .pass)
            #expect(router.key(code, modifiers: [], down: true) == .pass)
        }
    }
}

@Test func keyTraceExcludesTypingAndTracksArrowReleaseAfterModifiers() {
    var filter = KeyTraceFilter()
    let events: [(UInt16, Modifiers, Bool, Bool)] = [
        (0, [], true, false),
        (0, [.ctrl, .shift], true, false),
        (124, [], true, false),
        (124, [], false, false),
        (124, [.ctrl, .shift], true, true),
        (124, [], true, true),
        (0, [], true, false),
        (124, [], false, true),
        (124, [], false, false),
        (124, [], true, false),
        (123, .ctrl, false, true),
    ]
    for (code, modifiers, down, expected) in events {
        let traced = filter.includes(code, modifiers: modifiers, down: down)
        #expect(traced == expected)
    }
}

@Test func swallowedKeyUpSurvivesConfigAndModifierChanges() {
    var router = KeyRouter(bindings: Config.defaultBindings, names: [124: "right"])
    #expect(router.key(124, modifiers: .ctrl, down: true) == .command(["page", "next"]))
    router.bindings = [:]
    #expect(router.key(124, modifiers: [], down: false) == .swallow)
    #expect(router.key(124, modifiers: [], down: false) == .pass)
    #expect(router.key(124, modifiers: .ctrl, down: true) == .pass)
}

@Test(arguments: ["left", "right", "up", "down"])
func dragCommandsAddressDraggedWindow(_ direction: String) {
    var router = KeyRouter(bindings: Config.defaultBindings, names: [123: direction], dragged: 42)
    let expected = ["left", "right"].contains(direction)
        ? ["window", "nudge", "42", direction]
        : ["window", "move", "42", "workspace", direction == "up" ? "prev" : "next"]
    #expect(router.key(123, modifiers: .ctrl, down: true) == .command(expected))
    #expect(router.key(123, modifiers: .ctrl, down: false) == .swallow)
}

@Test func heldResizeBindingRepeatsWhileOtherBindingsFireOnce() {
    let arrows: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up"]
    let resize: (String) -> KeyDecision = { .command(["window", "resize", $0], grab: 1) }
    var router = KeyRouter(bindings: Config.defaultBindings, names: arrows)
    for (code, name) in arrows {
        #expect(router.key(code, modifiers: [.ctrl, .alt], down: true) == resize(name))
        for _ in 0..<3 { #expect(router.key(code, modifiers: [.ctrl, .alt], down: true, autorepeat: true) == resize(name)) }
        #expect(router.key(code, modifiers: [.ctrl, .alt], down: false) == .swallow)
        #expect(router.key(code, modifiers: [.ctrl, .alt], down: false) == .pass)
    }
    // While the key stays held, a chord that is not a resize binding is swallowed without running anything.
    #expect(router.key(124, modifiers: [.ctrl, .alt], down: true) == resize("right"))
    #expect(router.key(124, modifiers: .ctrl, down: true, autorepeat: true) == .swallow)
    #expect(router.key(124, modifiers: [.ctrl, .alt, .shift], down: true, autorepeat: true) == .swallow)
    #expect(router.key(124, modifiers: [], down: true, autorepeat: true) == .swallow)
    #expect(router.key(124, modifiers: [.ctrl, .alt], down: true, autorepeat: true) == resize("right"))
    #expect(router.key(124, modifiers: .ctrl, down: false) == .swallow)
    // Other bindings still fire once, and their repeats never turn into a resize.
    #expect(router.key(124, modifiers: .ctrl, down: true) == .command(["page", "next"]))
    #expect(router.key(124, modifiers: .ctrl, down: true, autorepeat: true) == .swallow)
    #expect(router.key(124, modifiers: [.ctrl, .alt], down: true, autorepeat: true) == .swallow)
    #expect(router.key(124, modifiers: .ctrl, down: false) == .swallow)
    // A repeat without its press, as when the tap starts mid-press, or after a reset, does not resize.
    #expect(router.key(126, modifiers: [.ctrl, .alt], down: true, autorepeat: true) == .swallow)
    #expect(router.key(126, modifiers: [.ctrl, .alt], down: false) == .swallow)
    #expect(router.key(125, modifiers: [.ctrl, .alt], down: true) == resize("down"))
    router.resetHeld()
    #expect(router.key(125, modifiers: [.ctrl, .alt], down: true, autorepeat: true) == .swallow)
    // A custom binding naming a window repeats too; resize by share does not.
    var custom = KeyRouter(bindings: [Chord(modifiers: .alt, key: "left"): ["window", "resize", "42", "left"],
                                      Chord(modifiers: .alt, key: "right"): ["window", "resize", "0.6"]], names: arrows)
    #expect(custom.key(123, modifiers: .alt, down: true) == .command(["window", "resize", "42", "left"], grab: 1))
    #expect(custom.key(123, modifiers: .alt, down: true, autorepeat: true) == .command(["window", "resize", "42", "left"], grab: 1))
    #expect(custom.key(124, modifiers: .alt, down: true) == .command(["window", "resize", "0.6"]))
    #expect(custom.key(124, modifiers: .alt, down: true, autorepeat: true) == .swallow)
    // The open switcher takes the arrows whatever the modifiers.
    let session = router.open(.switcher)
    #expect(router.key(123, modifiers: [.ctrl, .alt], down: true) == .switcher(.move(.left), session: session))
    #expect(router.key(123, modifiers: [.ctrl, .alt], down: true, autorepeat: true) == .switcher(.move(.left), session: session))
}

@Test func stashShortcutOnlyBlocksItsExactSemanticChord() {
    var router = KeyRouter(blocked: [NativeChord(keycode: 19, modifiers: .ctrl)])
    #expect(router.key(19, modifiers: [.ctrl, .shift], down: true) == .pass)
    #expect(router.key(19, modifiers: .ctrl, down: true) == .swallow)
    #expect(router.key(19, modifiers: [], down: false) == .swallow)
    #expect(router.key(18, modifiers: .ctrl, down: true) == .pass)
}

@Test func unboundAndOrdinaryTypingPassThrough() {
    var router = KeyRouter(bindings: [Chord(modifiers: .ctrl, key: "a"): []], names: [0: "a"])
    #expect(router.key(0, modifiers: [], down: true) == .pass)
    #expect(router.key(0, modifiers: [], down: false) == .pass)
    #expect(router.key(0, modifiers: .ctrl, down: true) == .pass)
}

@Test func smokeScopeExcludesOtherDocumentsAndUnknownStashWindows() {
    #expect(SmokeScope(environment: [:]).allows(document: nil))
    let scope = SmokeScope(environment: ["MINITILE_SMOKE_DIRECTORY": "/tmp/minitile-smoke-test",
                                         "MINITILE_SMOKE_WINDOWS": "42:100,43:101"])
    #expect(scope.allows(document: "file:///tmp/minitile-smoke-test/document.txt"))
    #expect(!scope.allows(document: nil))
    #expect(!scope.allows(document: "file:///tmp/minitile-smoke-test-other/document.txt"))
    #expect(!scope.allows(document: "file:///tmp/minitile-smoke-test/../personal.txt"))
    #expect(!scope.allows(document: "https://example.com/document.txt"))
    #expect(scope.allowsStash(id: 42, pid: 100))
    #expect(!scope.allowsStash(id: 42, pid: 101))
    #expect(!scope.allowsStash(id: 99, pid: 100))
}

@MainActor @Test func watcherSeesWritesAndAtomicReplacements() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minitile-watcher-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("minitile.toml")
    try "padding = 1".write(to: file, atomically: true, encoding: .utf8)
    let watcher = ConfigWatcher(file: file)
    var observed = ""
    watcher.changed = { observed = (try? String(contentsOf: file, encoding: .utf8)) ?? "missing" }
    watcher.start()
    defer { watcher.stop() }
    for (text, atomic) in [("padding = 2", false), ("padding = 3", true), ("padding = 4", false)] {
        try text.write(to: file, atomically: atomic, encoding: .utf8)
        for _ in 0..<100 {
            if observed == text { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(observed == text)
    }
    try FileManager.default.removeItem(at: file)
    for _ in 0..<100 {
        if observed == "missing" { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(observed == "missing")
    try "padding = 5".write(to: file, atomically: true, encoding: .utf8)
    for _ in 0..<100 {
        if observed == "padding = 5" { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(observed == "padding = 5")
}

@MainActor @Test func stateWritesAreOrderedAndRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minitile-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = StateWriter(file: directory.appendingPathComponent("state.json"))
    #expect(try writer.read() == nil)
    for serial in 1...10 {
        var state = SavedState()
        state.serial = UInt64(serial)
        writer.save(state) { _ in }
    }
    writer.flush()
    #expect(try writer.read()?.serial == 10)
}
