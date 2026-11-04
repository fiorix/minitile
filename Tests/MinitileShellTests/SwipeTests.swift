import CoreGraphics
import MinitileCore
import Testing
@testable import minitile

private let left = SwipePolicy.Display(id: "left", frame: Rect(x: 0, y: 0, width: 1000, height: 800), owned: true)
private let right = SwipePolicy.Display(id: "right", frame: Rect(x: 1000, y: -100, width: 1200, height: 900), owned: true)
private let policy = SwipePolicy(started: true, suspended: false, displays: [left, right])
private let onLeft = Point(x: 500, y: 400)
private let onRight = Point(x: 1500, y: 400)

private func event(_ phase: Int64, axis: Int64 = SwipeEvent.sideways, progress: Double = 0, velocity: Double = 0,
                   at location: Point = onLeft, hid: Int64 = SwipeEvent.dockSwipe) -> SwipeEvent {
    SwipeEvent(hidType: hid, phase: phase, axis: axis, progress: progress, velocity: velocity, location: location)
}

/// One whole swipe: began, a few changes, then ended with the given progress and velocity.
private func swipe(_ tracker: inout SwipeTracker, axis: Int64 = SwipeEvent.sideways, progress: Double, velocity: Double = 0,
                   at location: Point = onLeft, policy: SwipePolicy = policy) -> [SwipeDecision] {
    [event(SwipeEvent.began, axis: axis, progress: progress / 10, at: location),
     event(2, axis: axis, progress: progress / 2, at: location),
     event(2, axis: axis, progress: progress, at: location),
     event(SwipeEvent.ended, axis: axis, progress: progress, velocity: velocity, at: location)].map { tracker.receive($0, policy: policy) }
}

@Test func policyHitTestsTheDisplayUnderThePointer() {
    #expect(policy.owner(at: onLeft) == "left")
    #expect(policy.owner(at: onRight) == "right")
    #expect(policy.owner(at: Point(x: 999.5, y: 0)) == "left")
    #expect(policy.owner(at: Point(x: 1000, y: -100)) == "right")
    #expect(policy.owner(at: Point(x: 500, y: -50)) == nil)
    #expect(policy.owner(at: Point(x: 2200, y: 400)) == nil)
    var unowned = policy
    unowned.displays[1].owned = false
    #expect(unowned.owner(at: onRight) == nil)
    #expect(unowned.owner(at: onLeft) == "left")
}

@Test func policyOwnsNothingUntilStartedOrWhileSuspended() {
    #expect(SwipePolicy().owner(at: onLeft) == nil)
    var stopped = policy
    stopped.started = false
    #expect(stopped.owner(at: onLeft) == nil)
    var suspended = policy
    suspended.suspended = true
    #expect(suspended.owner(at: onLeft) == nil)
}

@Test func displayIsOwnedOnlyWhenManagedAndShowingItsVisibleDesktop() {
    let info = DisplayInfo(id: "a", frame: Rect(x: 0, y: 0, width: 10, height: 10), visibleSpace: 1, stashSpace: 9)
    #expect(SwipePolicy.Display(info, currentSpace: 1).owned)
    #expect(SwipePolicy.Display(info, currentSpace: 1).frame == info.frame)
    #expect(!SwipePolicy.Display(info, currentSpace: 9).owned)
    // A fullscreen Space or an extra desktop between the visible desktop and the stash.
    #expect(!SwipePolicy.Display(info, currentSpace: 5).owned)
    var unmanaged = info
    unmanaged.unmanagedReason = DisplayNeed.secondDesktop.reason
    #expect(!SwipePolicy.Display(unmanaged, currentSpace: 1).owned)
    let unknown = DisplayInfo(id: "b", frame: info.frame)
    #expect(!SwipePolicy.Display(unknown, currentSpace: 0).owned)
}

@Test func ownedSwipeIsSwallowedWholeAndActsOnItsDisplay() {
    var tracker = SwipeTracker()
    #expect(swipe(&tracker, progress: 0.8) == [.swallow, .swallow, .swallow, .command(["page", "next", "display", "left"])])
    #expect(tracker.last == SwipeRecord(location: onLeft, display: "left", command: ["page", "next", "display", "left"]))
    #expect(swipe(&tracker, progress: 0.8, at: onRight).last == .command(["page", "next", "display", "right"]))
}

@Test func swipeLeftToMacOSPassesWhole() {
    var tracker = SwipeTracker()
    var stopped = policy
    stopped.started = false
    #expect(swipe(&tracker, progress: 0.8, policy: stopped) == [.pass, .pass, .pass, .pass])
    var suspended = policy
    suspended.suspended = true
    #expect(swipe(&tracker, progress: 0.8, policy: suspended) == [.pass, .pass, .pass, .pass])
    var unowned = policy
    unowned.displays[0].owned = false
    #expect(swipe(&tracker, progress: 0.8, policy: unowned) == [.pass, .pass, .pass, .pass])
    #expect(tracker.last == SwipeRecord(location: onLeft, display: nil, command: nil))
    #expect(swipe(&tracker, progress: 0.8, at: Point(x: -10, y: 0)) == [.pass, .pass, .pass, .pass])
    #expect(swipe(&tracker, progress: 0.8) == [.swallow, .swallow, .swallow, .command(["page", "next", "display", "left"])])
}

@Test func decisionAtBeganHoldsWhenThePolicyChangesMidSwipe() {
    var tracker = SwipeTracker()
    var suspended = policy
    suspended.suspended = true
    #expect(tracker.receive(event(SwipeEvent.began), policy: policy) == .swallow)
    #expect(tracker.receive(event(2, progress: 0.5), policy: suspended) == .swallow)
    #expect(tracker.receive(event(SwipeEvent.ended, progress: 0.5), policy: suspended) == .command(["page", "next", "display", "left"]))
    #expect(tracker.receive(event(SwipeEvent.began), policy: suspended) == .pass)
    #expect(tracker.receive(event(2, progress: 0.5), policy: policy) == .pass)
    #expect(tracker.receive(event(SwipeEvent.ended, progress: 0.5), policy: policy) == .pass)
}

@Test func eventsWithoutABeganPass() {
    var tracker = SwipeTracker()
    #expect(tracker.receive(event(2, progress: 0.5), policy: policy) == .pass)
    #expect(tracker.receive(event(SwipeEvent.ended, progress: 0.9, velocity: 4), policy: policy) == .pass)
    #expect(tracker.receive(event(SwipeEvent.cancelled), policy: policy) == .pass)
    #expect(tracker.last == nil)
}

@Test func otherHIDTypesPassWithoutDisturbingASwipe() {
    var tracker = SwipeTracker()
    #expect(tracker.receive(event(SwipeEvent.began, hid: 0), policy: policy) == .pass)
    #expect(tracker.receive(event(2, hid: 23), policy: policy) == .pass)
    #expect(tracker.receive(event(SwipeEvent.began), policy: policy) == .swallow)
    #expect(tracker.receive(event(2, hid: 0), policy: policy) == .pass)
    #expect(tracker.receive(event(SwipeEvent.ended, hid: 6), policy: policy) == .pass)
    #expect(tracker.receive(event(2, progress: -0.6), policy: policy) == .swallow)
    #expect(tracker.receive(event(SwipeEvent.ended, progress: -0.6), policy: policy) == .command(["page", "prev", "display", "left"]))
}

@Test func unknownAxisLeavesTheSwipeToMacOS() {
    var tracker = SwipeTracker()
    for axis: Int64 in [0, 3] {
        #expect(swipe(&tracker, axis: axis, progress: 0.8) == [.pass, .pass, .pass, .pass])
    }
}

@Test func cancelledSwipeIsSwallowedAndDoesNothing() {
    var tracker = SwipeTracker()
    #expect(tracker.receive(event(SwipeEvent.began), policy: policy) == .swallow)
    #expect(tracker.receive(event(2, progress: 0.9), policy: policy) == .swallow)
    #expect(tracker.receive(event(SwipeEvent.cancelled, progress: 0.9, velocity: 5), policy: policy) == .swallow)
    #expect(tracker.receive(event(2, progress: 0.9), policy: policy) == .pass)
    #expect(tracker.last?.command == nil)
}

@Test func shortSlowSwipeIsSwallowedWithoutACommand() {
    var tracker = SwipeTracker()
    #expect(swipe(&tracker, progress: 0.29, velocity: 1.9) == [.swallow, .swallow, .swallow, .swallow])
    #expect(swipe(&tracker, progress: -0.29, velocity: -1.9) == [.swallow, .swallow, .swallow, .swallow])
}

@Test(arguments: [
    (0.3, 0.0, true), (0.2999, 1.999, false), (-0.3, 0.0, true), (-0.2999, -1.999, false),
    (0.1, 2.0, true), (-0.1, -2.0, true), (0.1, -2.0, true), (0.0, 0.0, false), (0.0, 1.999, false),
])
func swipeActsFromThirtyPercentOrAnEndVelocityOfTwo(_ test: (Double, Double, Bool)) {
    #expect((SwipeTracker.command(axis: SwipeEvent.sideways, progress: test.0, velocity: test.1) != nil) == test.2)
    #expect((SwipeTracker.command(axis: SwipeEvent.vertical, progress: test.0, velocity: test.1) != nil) == test.2)
}

@Test func swipeDirectionsMatchTheNativeDesktopSwipe() {
    let sideways = SwipeEvent.sideways, vertical = SwipeEvent.vertical
    #expect(SwipeTracker.command(axis: sideways, progress: 0.5, velocity: 3) == ["page", "next"])
    #expect(SwipeTracker.command(axis: sideways, progress: -0.5, velocity: -3) == ["page", "prev"])
    #expect(SwipeTracker.command(axis: vertical, progress: -0.5, velocity: -3) == ["workspace", "next"])
    #expect(SwipeTracker.command(axis: vertical, progress: 0.5, velocity: 3) == ["workspace", "prev"])
    // Progress decides; velocity only breaks a tie at zero.
    #expect(SwipeTracker.command(axis: sideways, progress: 0.35, velocity: -3) == ["page", "next"])
    #expect(SwipeTracker.command(axis: sideways, progress: 0, velocity: 2.5) == ["page", "next"])
    #expect(SwipeTracker.command(axis: sideways, progress: 0, velocity: -2.5) == ["page", "prev"])
    #expect(SwipeTracker.command(axis: vertical, progress: 0, velocity: -2.5) == ["workspace", "next"])
    #expect(SwipeTracker.command(axis: vertical, progress: 0, velocity: 2.5) == ["workspace", "prev"])
}

@Test func verticalSwipeUsesTheAxisFromItsBeganEvent() {
    var tracker = SwipeTracker()
    #expect(swipe(&tracker, axis: SwipeEvent.vertical, progress: -0.6, at: onRight).last
            == .command(["workspace", "next", "display", "right"]))
    #expect(tracker.receive(event(SwipeEvent.began, axis: SwipeEvent.vertical), policy: policy) == .swallow)
    #expect(tracker.receive(event(SwipeEvent.ended, axis: SwipeEvent.sideways, progress: 0.6), policy: policy)
            == .command(["workspace", "prev", "display", "left"]))
}

@Test func swipeEventReadsTheSpikeFieldsFromACGEvent() throws {
    let cg = try #require(CGEvent(source: nil))
    cg.type = try #require(CGEventType(rawValue: SwipeEvent.eventType))
    for (field, value) in [(110, 23), (132, 4), (123, 2)] as [(UInt32, Int64)] {
        cg.setIntegerValueField(try #require(CGEventField(rawValue: field)), value: value)
    }
    for (field, value) in [(124, -0.375), (129, -2.5)] as [(UInt32, Double)] {
        cg.setDoubleValueField(try #require(CGEventField(rawValue: field)), value: value)
    }
    cg.location = CGPoint(x: 1500, y: -20)
    #expect(SwipeEvent(cg) == SwipeEvent(hidType: 23, phase: 4, axis: 2, progress: -0.375, velocity: -2.5, location: Point(x: 1500, y: -20)))
}
