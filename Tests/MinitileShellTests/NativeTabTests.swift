import Testing
@testable import minitile

@Test func tabSelectionWaitsForWindowServerBeforeConsumingTheSwitch() {
    var tabs = TabSelection(1)
    #expect(tabs.select(2, now: 0, previousInactive: false) == .waiting)
    #expect(tabs.selected == 1)
    #expect(tabs.select(2, now: 0.05, previousInactive: false) == .waiting)
    #expect(tabs.selected == 1)
    #expect(tabs.select(2, now: 0.1, previousInactive: true) == .selected(previous: 1))
    #expect(tabs.selected == 2)
    #expect(tabs.select(2, now: 0.2, previousInactive: true) == nil)
}

@Test func tabSelectionDoesNotCarryTheSlotOfADetachedVisibleWindow() {
    var tabs = TabSelection(1)
    #expect(tabs.select(2, now: 0, previousInactive: false) == .waiting)
    #expect(tabs.select(2, now: 0.2, previousInactive: false) == .detached)
    #expect(tabs.selected == 2)
}

@Test func tabSelectionCanReturnToTheOriginalTabWhileSettling() {
    var tabs = TabSelection(1)
    #expect(tabs.select(2, now: 0, previousInactive: false) == .waiting)
    #expect(tabs.select(1, now: 0.02, previousInactive: false) == nil)
    #expect(tabs.select(2, now: 0.2, previousInactive: false) == .waiting)
    #expect(tabs.select(2, now: 0.25, previousInactive: true) == .selected(previous: 1))
}
