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
