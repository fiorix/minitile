import MinitileCore
import Testing
@testable import minitile

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
