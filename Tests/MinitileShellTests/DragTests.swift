import MinitileCore
import Testing
@testable import minitile

@Test func dragGenerationTracksStateSceneConfigAndDisplayChanges() {
    var generation = DragGeneration()
    let input = Input.command(["state"])
    generation.update(input, output: Output())
    #expect(generation.value == 0)
    generation.update(.windowGone(1), output: Output(stateChanged: true))
    #expect(generation.value == 1)
    let scene = Scene(displays: ["d": DisplayScene(visible: [1])])
    generation.update(input, output: Output(scene: scene))
    #expect(generation.value == 2)
    // A held reconcile does not make an unchanged engine scene a new generation on each input.
    generation.update(input, output: Output(scene: scene))
    #expect(generation.value == 2)
    generation.update(.configLoaded(.default), output: Output(scene: scene))
    #expect(generation.value == 3)
    generation.update(.displaysChanged([]), output: Output(scene: scene))
    #expect(generation.value == 4)
    generation.update(.windowGone(1), output: Output(stateChanged: true))
    #expect(generation.value == 5) // State and scene together invalidate once.
}

@Test func dragCacheReusesValuesAndMissesUntilItsWindowOrGenerationChanges() {
    var cache = DragCache<Int>()
    var builds = 0
    func value(_ window: WindowID = 1, _ generation: UInt64 = 0, result: Int? = 7) -> Int? {
        cache.value(window: window, generation: generation) { builds += 1; return result }
    }
    for _ in 0..<30 { #expect(value() == 7) }
    #expect(builds == 1)
    #expect(value(1, 1, result: nil) == nil)
    for _ in 0..<30 { #expect(value(1, 1) == nil) }
    #expect(builds == 2)
    #expect(value(2, 1) == 7)
    #expect(builds == 3)
    cache = DragCache() // A later drag of the same window cannot inherit the cache.
    #expect(value(2, 1, result: 8) == 8)
    #expect(builds == 4)
}

@Test func realDragOverridesRecentWritesButEchoesDoNot() {
    let target = Rect(x: 8, y: 38, width: 500, height: 600)
    for actual in [Rect(x: 29, y: 38, width: 500, height: 600),
                   Rect(x: 8, y: 38, width: 521, height: 600)] {
        #expect(ReconcilePlan.acceptsMove(suppressed: true, mouseDown: true, actual: actual, lastWrite: target))
        #expect(!ReconcilePlan.acceptsMove(suppressed: true, mouseDown: false, actual: actual, lastWrite: target))
    }
    #expect(!ReconcilePlan.acceptsMove(suppressed: true, mouseDown: true, actual: target, lastWrite: target))
    #expect(!ReconcilePlan.acceptsMove(suppressed: true, mouseDown: true,
                                      actual: Rect(x: 28, y: 38, width: 480, height: 600), lastWrite: target))
    #expect(!ReconcilePlan.acceptsMove(suppressed: true, mouseDown: true, actual: nil, lastWrite: target))
    #expect(!ReconcilePlan.acceptsMove(suppressed: true, mouseDown: true, actual: target, lastWrite: nil))
    #expect(ReconcilePlan.acceptsMove(suppressed: false, mouseDown: true, actual: nil, lastWrite: nil))
    #expect(ReconcilePlan.acceptsMove(suppressed: false, mouseDown: false, actual: nil, lastWrite: nil))
}
