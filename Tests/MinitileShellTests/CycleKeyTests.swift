import MinitileCore
import Testing
@testable import minitile

@Test func layoutCycleUsesControlOptionAndFiresOncePerPress() {
    var router = KeyRouter(bindings: Config.defaultBindings, names: [49: "space"])
    #expect(router.key(49, modifiers: [.ctrl, .alt], down: true) == .command(["page", "variant"]))
    #expect(router.key(49, modifiers: [.ctrl, .alt], down: true, autorepeat: true) == .swallow)
    #expect(router.key(49, modifiers: [.ctrl, .alt], down: false) == .swallow)
    #expect(router.key(49, modifiers: [.ctrl, .shift], down: true) == .pass)
    #expect(router.key(49, modifiers: [.ctrl, .shift], down: false) == .pass)
    #expect(router.key(49, modifiers: [.ctrl, .alt], down: true) == .command(["page", "variant"]))
}

@Test func cycleKeyFollowsTheNativeShortcutAndFallsBackToKeycode50() {
    #expect(CycleKey.named([:], hotkey: 10) == [10: "`"])
    #expect(CycleKey.named([:], hotkey: nil) == [50: "`"])
    #expect(CycleKey.named([:], hotkey: 0xFFFF) == [50: "`"])
    #expect(CycleKey.named([0: "a"], hotkey: 0) == [0: "a"])
}

@Test func cycleKeyPassesThroughOnlyInUnmanagedApps() {
    var router = KeyRouter(bindings: Config.defaultBindings, names: [50: "`", 124: "right"])
    #expect(router.key(50, modifiers: .cmd, down: true) == .command(["window", "focus", "next"]))
    #expect(router.key(50, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(50, modifiers: [.cmd, .shift], down: true) == .command(["window", "focus", "prev"]))
    #expect(router.key(50, modifiers: [.cmd, .shift], down: false) == .swallow)
    router.frontmostManaged = false
    #expect(router.key(50, modifiers: .cmd, down: true) == .pass)
    #expect(router.key(50, modifiers: .cmd, down: false) == .pass)
    #expect(router.key(50, modifiers: [.cmd, .shift], down: true) == .pass)
    #expect(router.key(124, modifiers: .ctrl, down: true) == .command(["page", "next"]))
}

@Test func heldCycleKeyFiresOnceEvenWhenFocusLeavesManagedApps() {
    var router = KeyRouter(bindings: Config.defaultBindings, names: [50: "`"])
    #expect(router.key(50, modifiers: .cmd, down: true) == .command(["window", "focus", "next"]))
    router.frontmostManaged = false
    #expect(router.key(50, modifiers: .cmd, down: true, autorepeat: true) == .swallow)
    #expect(router.key(50, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(50, modifiers: .cmd, down: true) == .pass)
}
