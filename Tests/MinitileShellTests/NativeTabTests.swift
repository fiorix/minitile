import ApplicationServices
import MinitileCore
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

/// Drives tab groups without a live app: any distinct AX element stands for a tab bar, `bar` names the window that
/// holds it now, and `gone` lists the windows WindowServer no longer shows on any Space.
@MainActor
private struct TabGroups {
    static let pid: Int32 = 7
    var tabs = NativeTabs()
    let element = AXRef(AXUIElementCreateApplication(9001))
    private let holder = Holder()

    private final class Holder { var window: WindowID? }

    var bar: WindowID? {
        get { holder.window }
        nonmutating set { holder.window = newValue }
    }

    init() { tabs.owner = { [holder] _ in holder.window } }

    mutating func select(_ id: WindowID, barred: Bool = true, after focus: WindowID? = nil, now: TimeInterval,
                         gone: Set<WindowID> = []) -> NativeTabs.Selection? {
        tabs.select(id, pid: Self.pid, group: barred ? element : nil, previousFocus: focus, now: now, inactive: gone.contains)
    }

    /// Windows 1, 2 and 3 as one group with 3 selected.
    static func threeTabs() -> TabGroups {
        var groups = TabGroups()
        groups.bar = 2
        _ = groups.select(2, after: 1, now: 0, gone: [1])
        groups.bar = 3
        _ = groups.select(3, now: 1, gone: [1, 2])
        return groups
    }
}

@Test @MainActor func aNewTabTakesThePreviousFocusSlotOnlyOnceThatWindowLeavesEverySpace() {
    var groups = TabGroups()
    #expect(groups.select(2, barred: false, now: 0) == nil) // No group in this app yet.
    groups.bar = 2
    #expect(groups.select(2, after: 1, now: 0)?.waiting == true)
    #expect(groups.tabs.changing == [1, 2]) // Presence checks leave both alone meanwhile.
    let created = groups.select(2, now: 0.05, gone: [1])
    #expect(created?.previous == 1 && created?.waiting == false)
    #expect(groups.tabs.changing.isEmpty)
    #expect(groups.select(2, now: 0.1, gone: [1]) == nil) // The settled selection is an ordinary window update.
    groups.bar = 1
    #expect(groups.select(1, now: 1, gone: [2])?.previous == 2)
    #expect(groups.tabs.select(9, pid: 8, group: nil, previousFocus: nil, now: 1, inactive: { _ in false }) == nil)
}

@Test @MainActor func aNewWindowThatStaysBesideThePreviousFocusKeepsItsOwnSlot() {
    var groups = TabGroups()
    groups.bar = 2
    #expect(groups.select(2, after: 1, now: 0)?.waiting == true)
    #expect(groups.select(2, now: 0.1)?.waiting == true)
    let settled = groups.select(2, now: 0.2)
    #expect(settled?.previous == nil && settled?.waiting == false)
    #expect(groups.select(2, now: 0.3) == nil)
    // Window 1 no longer shares the group, so it cannot inherit the slot when window 2 goes away.
    groups.bar = nil
    #expect(groups.select(1, barred: false, now: 1, gone: [2]) == nil)
}

@Test @MainActor func closingTheSelectedTabHandsItsSlotToTheWindowLeftWithoutATabBar() {
    var groups = TabGroups()
    groups.bar = 2
    _ = groups.select(2, after: 1, now: 0, gone: [1])
    groups.bar = nil
    #expect(groups.select(1, barred: false, now: 2, gone: [2])?.previous == 2)
}

@Test @MainActor func aClosingSelectionStillOnScreenDoesNotDissolveItsGroup() {
    var groups = TabGroups()
    groups.bar = 2
    _ = groups.select(2, after: 1, now: 0, gone: [1])
    // Window 1 shows and the bar goes before WindowServer drops the closed window 2.
    groups.bar = nil
    #expect(groups.select(1, barred: false, now: 2)?.waiting == true)
    #expect(groups.tabs.changing == [1, 2]) // Neither is taken for an ordinary reappearance meanwhile.
    #expect(groups.select(2, barred: false, now: 2.02) == nil) // A read of the closing window changes nothing.
    #expect(groups.select(1, barred: false, now: 2.05, gone: [2])?.previous == 2)
    #expect(groups.tabs.changing.isEmpty)
}

@Test @MainActor func aDetachedTabStopsSharingItsGroup() {
    var pair = TabGroups()
    pair.bar = 2
    _ = pair.select(2, after: 1, now: 0, gone: [1])
    pair.bar = nil // Two separate windows: neither has a tab bar.
    #expect(pair.select(1, barred: false, now: 2)?.waiting == true)
    let split = pair.select(1, barred: false, now: 2.2)
    #expect(split?.previous == nil && split?.waiting == false) // Both stayed, so window 1 is an ordinary window.
    #expect(!pair.tabs.hasGroups(pid: TabGroups.pid))

    var trio = TabGroups.threeTabs()
    #expect(trio.select(1, barred: false, now: 2, gone: [2]) == nil) // The bar stays on window 3.
    trio.bar = nil
    #expect(trio.select(1, barred: false, now: 3, gone: [2, 3]) == nil)
    #expect(trio.select(2, barred: false, now: 3, gone: [3])?.previous == 3)
}

@Test @MainActor func aClosedTabLeavesItsGroupSoAReusedWindowIDIsUnrelated() {
    var groups = TabGroups.threeTabs()
    groups.tabs.forget(2)
    groups.bar = nil
    // A new window reusing ID 2 appears as the selected tab closes. It neither dissolves the group nor inherits a slot.
    #expect(groups.select(2, barred: false, now: 5, gone: [3]) == nil)
    #expect(groups.select(1, barred: false, now: 5, gone: [3])?.previous == 3)
}

@Test @MainActor func closingTheSelectionOrItsAppEndsTheGroup() {
    var groups = TabGroups.threeTabs()
    groups.tabs.forget(3)
    #expect(!groups.tabs.hasGroups(pid: TabGroups.pid))
    groups = TabGroups.threeTabs()
    groups.tabs.forget(pid: TabGroups.pid)
    #expect(!groups.tabs.hasGroups(pid: TabGroups.pid))
}

@Test func aWindowFocusedBeforeItIsDiscoveredBecomesTheCandidateOnceDiscovered() {
    var focus = FocusMemory()
    focus.focused(1, pid: 7, discovered: true)
    // A new window is focused before discovery knows it, and no later focus change follows.
    focus.focused(2, pid: 7, discovered: false)
    #expect(focus.last(pid: 7) == 1)
    focus.discovered(2, pid: 7)
    #expect(focus.last(pid: 7) == 2)
}

@Test func aNewTabNeverNamesItselfAsThePreviousFocus() {
    var focus = FocusMemory()
    focus.focused(2, pid: 7, discovered: true)
    focus.focused(3, pid: 7, discovered: false) // The new tab, focused before it is discovered.
    #expect(focus.last(pid: 7) == 2)            // Its tab selection is decided against window 2.
    focus.discovered(3, pid: 7)
    #expect(focus.last(pid: 7) == 3)
    // Focus moved on before another new window was discovered, so that window is not the candidate.
    focus.focused(4, pid: 7, discovered: false)
    focus.focused(2, pid: 7, discovered: true)
    focus.discovered(4, pid: 7)
    #expect(focus.last(pid: 7) == 2)
    focus.forget(pid: 7)
    #expect(focus.last(pid: 7) == nil && focus.last(pid: 8) == nil)
}

@Test @MainActor func theWindowThatTakesTheBarFromADetachedSelectionIsNamedAndSettlesOnItsOwn() {
    var groups = TabGroups.threeTabs()
    // Tab 3 moved to a window of its own; the group's window now shows tab 2 under the bar.
    groups.bar = 2
    #expect(groups.select(3, barred: false, now: 2, gone: [1]) == nil) // The detached selection decides nothing.
    #expect(groups.tabs.changing == [2, 3]) // Window 2 is shielded from the ordinary reappearance check meanwhile.
    #expect(groups.tabs.successor(of: 3, pid: TabGroups.pid) == 2)
    #expect(groups.select(2, now: 2.05, gone: [1])?.waiting == true)
    let settled = groups.select(2, now: 2.25, gone: [1])
    #expect(settled?.previous == nil && settled?.waiting == false) // Both stayed: 3 keeps its slot, 2 is placed anew.
    #expect(groups.tabs.changing.isEmpty)
    #expect(groups.tabs.successor(of: 3, pid: TabGroups.pid) == nil)
    // The group goes on with tabs 1 and 2.
    groups.bar = 1
    #expect(groups.select(1, now: 3, gone: [2])?.previous == 2)
}

@Test @MainActor func aSelectionsSuccessorIsNamedOnlyAFewTimesAndOnlyForALostBar() {
    var groups = TabGroups.threeTabs()
    #expect(groups.tabs.successor(of: 3, pid: TabGroups.pid) == nil) // The selection still holds its bar.
    groups.bar = 2
    #expect(groups.tabs.successor(of: 1, pid: TabGroups.pid) == nil) // Not a recorded selection.
    #expect(groups.tabs.successor(of: 3, pid: 8) == nil)             // Another app.
    for _ in 0..<NativeTabs.successorPrompts { #expect(groups.tabs.successor(of: 3, pid: TabGroups.pid) == 2) }
    // A bar owner that never settles is left to the periodic scan.
    #expect(groups.tabs.successor(of: 3, pid: TabGroups.pid) == nil)
    groups.bar = 1 // Another owner is a new question.
    #expect(groups.tabs.successor(of: 3, pid: TabGroups.pid) == 1)
    groups.bar = nil // A bar that is gone has no owner to read.
    #expect(groups.tabs.successor(of: 3, pid: TabGroups.pid) == nil)
}

@Test func aWindowShownAgainTakesFocusOnlyIfItsActiveAppDoesNotFocusAnother() {
    #expect(OrderedOutChecks.takesFocus(2, active: true, focus: .known(2)))
    #expect(!OrderedOutChecks.takesFocus(2, active: true, focus: .known(1)))  // The tab left behind by a detach.
    #expect(!OrderedOutChecks.takesFocus(2, active: true, focus: .known(nil)))
    #expect(OrderedOutChecks.takesFocus(2, active: true, focus: .unknown))    // Unreadable focus keeps the window's claim.
    #expect(!OrderedOutChecks.takesFocus(2, active: false, focus: .known(2)))
}
