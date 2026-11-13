import MinitileCore
import Testing
@testable import minitile

@Test func lostKeyUpDoesNotSwallowTheNextUnboundPress() {
    var router = KeyRouter(bindings: Config.defaultBindings, names: [124: "right"])
    #expect(router.key(124, modifiers: .ctrl, down: true) == .command(["page", "next"]))
    #expect(router.key(124, modifiers: [], down: true) == .pass)
    #expect(router.key(124, modifiers: [], down: true, autorepeat: true) == .pass)
    #expect(router.key(124, modifiers: [], down: false) == .pass)
}

@Test func heldBindingFiresOnceAcrossModifierAndConfigChanges() {
    var router = KeyRouter(bindings: Config.defaultBindings, names: [124: "right"])
    #expect(router.key(124, modifiers: .ctrl, down: true) == .command(["page", "next"]))
    #expect(router.key(124, modifiers: .ctrl, down: true, autorepeat: true) == .swallow)
    router.bindings = [:]
    #expect(router.key(124, modifiers: [], down: true, autorepeat: true) == .swallow)
    #expect(router.key(124, modifiers: [], down: false) == .swallow)
    router.bindings = Config.defaultBindings
    #expect(router.key(124, modifiers: .ctrl, down: true) == .command(["page", "next"]))
}

@Test func tapResetClearsHeldKeysAndOrphanRepeatsNeverRunCommands() {
    var router = KeyRouter(bindings: Config.defaultBindings, names: [124: "right"])
    #expect(router.key(124, modifiers: .ctrl, down: true) == .command(["page", "next"]))
    router.resetHeld()
    #expect(router.key(124, modifiers: [], down: false) == .pass)
    #expect(router.key(124, modifiers: .ctrl, down: true, autorepeat: true) == .swallow)
    #expect(router.key(124, modifiers: [], down: false) == .swallow)
    #expect(router.key(124, modifiers: .ctrl, down: true) == .command(["page", "next"]))
}

@Test func escapeSignalsAnEdgeDropCancelOnlyOnKeyDownDuringADrag() {
    var router = KeyRouter(names: [53: "escape", 124: "right"])
    #expect(!router.cancelsEdgeDrop(53, down: true))
    router.dragged = 42
    #expect(router.cancelsEdgeDrop(53, down: true))
    #expect(!router.cancelsEdgeDrop(53, down: false))
    #expect(!router.cancelsEdgeDrop(124, down: true))
    router.dragged = nil
    #expect(!router.cancelsEdgeDrop(53, down: true))
}

@Test(arguments: [Modifiers(), .ctrl, .cmd, [.ctrl, .shift]])
func dragEscapePreservesAppHelpSwitcherAndBindingRoutes(_ modifiers: Modifiers) {
    var router = KeyRouter(names: [53: "escape"], dragged: 42)
    for autorepeat in [false, true] {
        #expect(router.cancelsEdgeDrop(53, down: true))
        #expect(router.key(53, modifiers: modifiers, down: true, autorepeat: autorepeat) == .pass)
    }
    #expect(router.key(53, modifiers: modifiers, down: false) == .pass)
    let help = router.open(.help)
    #expect(router.cancelsEdgeDrop(53, down: true))
    #expect(router.key(53, modifiers: modifiers, down: true) == .help(.close, session: help))
    #expect(router.key(53, modifiers: modifiers, down: false) == .swallow)
    let switcher = router.open(.switcher)
    #expect(router.cancelsEdgeDrop(53, down: true))
    #expect(router.key(53, modifiers: modifiers, down: true) == .switcher(.cancel, session: switcher))
    #expect(router.key(53, modifiers: modifiers, down: false) == .swallow)
    router.bindings = [Chord(modifiers: modifiers, key: "escape"): ["page", "next"]]
    #expect(router.cancelsEdgeDrop(53, down: true))
    #expect(router.key(53, modifiers: modifiers, down: true) == .command(["page", "next"]))
    #expect(router.key(53, modifiers: modifiers, down: true, autorepeat: true) == .swallow)
    #expect(router.key(53, modifiers: modifiers, down: false) == .swallow)
}
