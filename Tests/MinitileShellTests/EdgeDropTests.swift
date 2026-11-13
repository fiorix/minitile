import AppKit
import MinitileCore
import Testing
@testable import minitile

private let bounds = Rect(x: 0, y: 0, width: 1000, height: 800)
private let origin = Rect(x: 200, y: 100, width: 500, height: 400)
private let moved = Rect(x: 220, y: 120, width: 500, height: 400)
private let down = Point(x: 400, y: 110)

private func owner(bounds: Rect = bounds, origin: Rect = origin, frame: Rect = moved,
                   edit: (inout WindowState, inout DisplayInfo) -> Void = { _, _ in }) -> EdgeDropOwner? {
    var window = WindowState(info: WindowInfo(id: 42, pid: 123, frame: frame, display: "d"), display: "d", floating: false)
    var display = DisplayInfo(id: "d", frame: bounds, visibleSpace: 4, stashSpace: 5)
    edit(&window, &display)
    return EdgeDropOwner(window: window, display: display, origin: origin, frame: frame, currentSpace: 4, visible: true)
}

@Test(arguments: [
    (DropEdge.left, Point(x: 0, y: 400), Point(x: 60, y: 400), ["window", "nudge", "42", "left"]),
    (.right, Point(x: 999, y: 400), Point(x: 940, y: 400), ["window", "nudge", "42", "right"]),
    (.top, Point(x: 500, y: 0), Point(x: 500, y: 60), ["window", "move", "42", "workspace", "prev"]),
    (.bottom, Point(x: 500, y: 799), Point(x: 500, y: 740), ["window", "move", "42", "workspace", "next"]),
])
func edgeDropClampsDragAndReleaseAndCommitsOnce(_ edge: DropEdge, _ raw: Point, _ clamped: Point, _ command: [String]) throws {
    let owner = try #require(owner())
    var tracker = EdgeDropTracker()
    tracker.begin(at: down)
    tracker.update(owner, moved: true, press: tracker.sequence)
    #expect(tracker.drag(to: raw) == clamped)
    #expect(tracker.hovered == edge)
    #expect(tracker.end(at: raw) == clamped)
    let release = EdgeDropRelease(owner: owner, edge: edge, location: raw)
    #expect(tracker.finish(now: 1) == .ready(release))
    #expect(tracker.finish(now: 2) == .ready(nil))
    #expect(edge.command(42) == command)
}

@Test func edgeDropWaitsForAConfirmedMoveInsideThePressedWindow() throws {
    let owner = try #require(owner()), edge = Point(x: 999, y: 400)
    var tracker = EdgeDropTracker()
    tracker.update(owner, moved: true, press: tracker.sequence)
    #expect(tracker.drag(to: edge) == edge) // Starting the tap during a drag does not acquire it.
    tracker.begin(at: down)
    tracker.update(owner, moved: false, press: tracker.sequence)
    #expect(tracker.drag(to: edge) == edge) // Clicking, selecting text and stationary drags pass through.
    tracker.update(nil, moved: false, press: tracker.sequence)
    tracker.update(owner, moved: true, press: tracker.sequence)
    #expect(tracker.drag(to: edge).x == 940)
    tracker.begin(at: Point(x: 900, y: 110))
    tracker.update(owner, moved: true, press: tracker.sequence)
    #expect(tracker.end(at: edge) == edge) // A different window moved during this press.
    #expect(tracker.finish(now: 1) == .ready(nil))
}

@Test func edgeDropCanLeaveTheBandOrChangeEdgesBeforeRelease() throws {
    let owner = try #require(owner())
    var tracker = EdgeDropTracker()
    tracker.begin(at: down)
    tracker.update(owner, moved: true, press: tracker.sequence)
    _ = tracker.drag(to: Point(x: 999, y: 400))
    #expect(tracker.hovered == .right)
    _ = tracker.drag(to: Point(x: 500, y: 0))
    #expect(tracker.hovered == .top)
    let center = Point(x: 500, y: 400)
    #expect(tracker.end(at: center) == center)
    #expect(tracker.finish(now: 1) == .ready(EdgeDropRelease(owner: owner, edge: nil, location: center)))
}

@Test func edgeDropKeepsItsBandOnAClampedReleaseAndResolvesCorners() throws {
    let owner = try #require(owner())
    #expect(owner.edge(at: Point(x: 940, y: 400)) == .right)
    #expect(owner.edge(at: Point(x: 939, y: 200)) == nil)
    #expect(owner.edge(at: Point(x: 0, y: 0)) == .left)
    #expect(owner.edge(at: Point(x: 0, y: 0), previous: .top) == .top)
    #expect(owner.edge(at: Point(x: 10, y: 0), previous: .left) == .top)
    #expect(owner.clamp(Point(x: 1200, y: -100)) == Point(x: 940, y: 60))
}

@Test func edgeDropCornerIgnoresSubpixelJitterButAllowsDeliberateDirectionChanges() throws {
    let owner = try #require(owner())
    var previous: DropEdge? = .right
    // A physical top-right hold alternated y=0 with fractions of a point while x stayed just below the maximum.
    for y in [0.0, 0.65625, 0, 0.21875, 0] {
        previous = owner.edge(at: Point(x: 999.98046875, y: y), previous: previous)
        #expect(previous == .right)
    }
    #expect(owner.edge(at: Point(x: 991, y: 0), previous: previous) == .top)
    #expect(owner.edge(at: Point(x: 999.98, y: 9), previous: .top) == .right)
    #expect(owner.edge(at: Point(x: 0.02, y: 0), previous: .left) == .left)
    #expect(owner.edge(at: Point(x: 999.98, y: 800), previous: .bottom) == .bottom)
    #expect(owner.edge(at: Point(x: 0.02, y: 800), previous: .left) == .left)
    #expect(owner.edge(at: Point(x: 61, y: 0), previous: .left) == .top)
    #expect(owner.edge(at: Point(x: 500, y: 400), previous: .top) == nil)
}

@Test func edgeDropUsesGlobalCoordinatesAndCapsTheInsetOnSmallDisplays() throws {
    let shifted = try #require(owner(bounds: Rect(x: -1000, y: -800, width: 1000, height: 800)))
    #expect(shifted.clamp(Point(x: -1001, y: -400)) == Point(x: -940, y: -400))
    #expect(shifted.edge(at: Point(x: -500, y: -1)) == .bottom)
    let tiny = try #require(owner(bounds: Rect(x: -40, y: 0, width: 80, height: 40)))
    #expect(tiny.clamp(Point(x: -40, y: 0)) == Point(x: -20, y: 10))
    #expect(tiny.clamp(Point(x: 40, y: 40)) == Point(x: 20, y: 30))
    #expect(tiny.edge(at: Point(x: 0, y: 20)) == nil)
    #expect(owner(bounds: Rect(x: 0, y: 0, width: 0, height: 800)) == nil)
}

@Test func edgeDropRejectsResizesAndIneligibleWindowsButAllowsFloating() {
    #expect(owner(frame: Rect(x: 220, y: 120, width: 510, height: 400)) == nil)
    #expect(owner { window, _ in window.hidden = true } == nil)
    #expect(owner { window, _ in window.info.minimized = true } == nil)
    #expect(owner { window, _ in window.info.appHidden = true } == nil)
    #expect(owner { window, _ in window.info.fullscreen = true } == nil)
    #expect(owner { window, _ in window.info.orderedOut = true } == nil)
    #expect(owner { window, _ in window.info.onStash = true } == nil)
    #expect(owner { window, _ in window.display = "other" } == nil)
    #expect(owner { _, display in display.unmanagedReason = "no stash" } == nil)
    #expect(owner { _, display in display.visibleSpace = 6 } == nil)
    #expect(owner { _, display in display.visibleSpace = nil } == nil)
    #expect(owner { window, _ in window.floating = true } != nil)
}

@Test func edgeDropCancellationAndOwnerChangesCannotRearmTheSamePress() throws {
    let original = try #require(owner())
    var replaced = original; replaced.pid += 1
    var otherWindow = original; otherWindow.window += 1
    var otherDisplay = original; otherDisplay.display = "other"
    var resizedDisplay = original; resizedDisplay.bounds.width += 1
    for candidate in [nil, replaced, otherWindow, otherDisplay, resizedDisplay] {
        var tracker = EdgeDropTracker()
        tracker.begin(at: down)
        tracker.update(original, moved: true, press: tracker.sequence)
        _ = tracker.drag(to: Point(x: 999, y: 400))
        tracker.update(candidate, moved: true, press: tracker.sequence)
        tracker.update(original, moved: true, press: tracker.sequence)
        #expect(tracker.end(at: Point(x: 999, y: 400)).x == 999)
        #expect(tracker.finish(now: 1) == .ready(nil))
    }
    var tracker = EdgeDropTracker()
    tracker.begin(at: down)
    tracker.update(original, moved: true, press: tracker.sequence)
    tracker.cancel() // Escape, suspension, native Space change, tap disable or config reload.
    tracker.update(original, moved: true, press: tracker.sequence)
    #expect(tracker.owner == nil)
    tracker.begin(at: down)
    tracker.update(original, moved: true, press: tracker.sequence)
    #expect(tracker.owner == original)
}

@Test func edgeDropReleaseWaitsForTheTapAndDoesNotInventMissingEvents() throws {
    let owner = try #require(owner())
    var tracker = EdgeDropTracker()
    tracker.begin(at: down)
    tracker.update(owner, moved: true, press: tracker.sequence)
    _ = tracker.drag(to: Point(x: 999, y: 400))
    #expect(tracker.finish(now: 1) == .waiting)
    _ = tracker.end(at: Point(x: 500, y: 0))
    #expect(tracker.finish(now: 1.03) == .ready(EdgeDropRelease(owner: owner, edge: .top, location: Point(x: 500, y: 0))))
    tracker.begin(at: down)
    tracker.update(owner, moved: true, press: tracker.sequence)
    _ = tracker.drag(to: Point(x: 999, y: 400))
    #expect(tracker.finish(now: 2) == .waiting)
    #expect(tracker.finish(now: 2.2) == .ready(nil))
    #expect(tracker.end(at: Point(x: 999, y: 400)).x == 999)
    #expect(tracker.finish(now: 2.3) == .ready(nil))
}

@Test func edgeDropNeverReusesAReleaseAfterAnotherPressOrInvalidation() throws {
    let owner = try #require(owner())
    for newPress in [false, true] {
        var tracker = EdgeDropTracker()
        tracker.begin(at: down)
        tracker.update(owner, moved: true, press: tracker.sequence)
        _ = tracker.end(at: Point(x: 999, y: 400))
        if newPress { tracker.begin(at: down) } else { tracker.update(nil, moved: false, press: tracker.sequence) }
        #expect(tracker.finish(now: 1) == .ready(nil))
    }
}

@Test func edgeDropOldDragTrackingCannotClaimARapidSecondPress() throws {
    let owner = try #require(owner())
    var tracker = EdgeDropTracker()
    tracker.begin(at: down)
    let first = tracker.sequence
    tracker.update(owner, moved: true, press: first)
    _ = tracker.end(at: Point(x: 999, y: 400))
    tracker.begin(at: down) // Mouse-up was not yet polled by the main thread.
    tracker.update(owner, moved: true, press: first)
    #expect(tracker.drag(to: Point(x: 999, y: 400)).x == 999)
    #expect(tracker.finish(now: 1) == .ready(nil))
}

@Test(arguments: DropEdge.allCases)
func edgeDropUsesTheDefaultKeyboardMoveSemantics(_ edge: DropEdge) throws {
    let display = DisplayInfo(id: "d", frame: bounds, visibleSpace: 4)
    let windows = [WindowInfo(id: 42, pid: 123, frame: origin, display: "d"), WindowInfo(id: 43, pid: 124, frame: origin, display: "d")]
    var mouse = Engine()
    _ = mouse.handle(.started(saved: nil, windows: windows, displays: [display], focus: 42))
    var keyboard = mouse
    let key = edge == .top ? "up" : edge == .bottom ? "down" : edge.rawValue
    let binding = try #require(Config.default.bindings[Chord(modifiers: [.ctrl, .shift], key: key)])
    let expected = keyboard.handle(.command(binding))
    let actual = mouse.handle(.command(edge.command(42)))
    #expect(actual.reply?.ok == true)
    #expect(actual.scene == expected.scene)
    #expect(mouse.savedState() == keyboard.savedState())
}

@Test(arguments: [Rect(x: -1000, y: -761, width: 1000, height: 761), Rect(x: 0, y: 0, width: 60, height: 40)])
func edgeDropPanelsStayInsideTheUsableArea(_ area: Rect) {
    for edge in DropEdge.allCases {
        let frame = edge.target(in: area)
        #expect(area.contains(Point(x: frame.x, y: frame.y)))
        #expect(frame.maxX <= area.maxX && frame.maxY <= area.maxY)
    }
}

@Test func edgeDropAcceptsTheEntireVisibleTargetBeyondTheNativeEdgeBand() throws {
    var owner = try #require(owner())
    owner.area = Rect(x: 80, y: 39, width: 920, height: 700) // A Dock on the left and a menu bar above.
    for edge in DropEdge.allCases {
        let target = edge.target(in: owner.area)
        for point in [target.center, Point(x: target.x, y: target.y), Point(x: target.maxX - 1, y: target.maxY - 1)] {
            #expect(owner.edge(at: point) == edge)
        }
    }
}

@Test @MainActor func edgeDropTargetsRenderIdleAndHoveredWithoutShowingWindows() throws {
    var bitmaps: [NSBitmapImageRep] = []
    for edge in DropEdge.allCases {
        let view = EdgeDropView(edge: edge)
        view.frame = NSRect(x: 0, y: 0, width: 160, height: 44)
        for hovered in [false, true] {
            view.hovered = hovered
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            bitmaps.append(bitmap)
        }
        #expect(bitmaps[bitmaps.count - 1].tiffRepresentation != bitmaps[bitmaps.count - 2].tiffRepresentation)
    }
    let sheet = try renderBitmap(CGSize(width: 320, height: 176)) {
        for (index, bitmap) in bitmaps.enumerated() {
            let image = NSImage(size: CGSize(width: 160, height: 44))
            image.addRepresentation(bitmap)
            image.draw(in: CGRect(x: (index % 2) * 160, y: (3 - index / 2) * 44, width: 160, height: 44))
        }
    }
    try saveRender(sheet, name: "edge-drop-targets")
}

// A window re-tiled from the left half to the lower right tile, as Terminal accepted it, on a 2056 by 1329 display.
private let screen = Rect(x: 0, y: 0, width: 2056, height: 1329)
private let beforeWrite = Rect(x: 8, y: 47, width: 1016, height: 1274)
private let afterWrite = Rect(x: 1032, y: 688, width: 1014, height: 637)

@Test func aDragBeginsFromTheFrameMinitilesWriteSettledAt() {
    var settled = SettledFrame()
    #expect(settled.origin(reported: beforeWrite) == beforeWrite) // Nothing written: the reported frame stands.
    settled.wrote()
    settled.observe(Rect(x: 1032, y: 688, width: 1016, height: 633), suppressed: true, buttonDown: false)
    settled.observe(afterWrite, suppressed: true, buttonDown: false) // The app rounds the size a moment later.
    #expect(settled.origin(reported: beforeWrite) == afterWrite)
    settled.observe(nil, suppressed: true, buttonDown: false) // A failed read.
    #expect(settled.origin(reported: beforeWrite) == afterWrite)
    // The drag starts inside the echo interval: its first points are not the write's echo.
    var dragged = afterWrite; dragged.y += 15
    settled.observe(dragged, suppressed: true, buttonDown: true)
    #expect(settled.origin(reported: beforeWrite) == afterWrite)
    // Once the drag is tracked its frames are reported, and the next drag begins from what is reported.
    settled.observe(dragged, suppressed: false, buttonDown: true)
    #expect(settled.frame == nil && settled.origin(reported: dragged) == dragged)
}

@Test func aNewWriteOrAReportedFrameDiscardsTheSettledFrame() {
    var settled = SettledFrame()
    settled.observe(afterWrite, suppressed: true, buttonDown: false)
    settled.wrote() // Its echo arrives with the button held, so what the earlier write settled at must not linger.
    settled.observe(beforeWrite, suppressed: true, buttonDown: true)
    #expect(settled.frame == nil)
    settled.observe(afterWrite, suppressed: true, buttonDown: false)
    settled.observe(afterWrite, suppressed: false, buttonDown: false)
    #expect(settled.frame == nil)
}

@Test func aDragBegunRightAfterAWriteIsAcquiredFromTheSettledFrameOnly() throws {
    var dragged = afterWrite; dragged.x -= 30; dragged.y += 40
    let press = Point(x: afterWrite.x + 300, y: afterWrite.y + 14)
    // From the frame before the write the window seems resized and the press seems to miss it.
    #expect(owner(bounds: screen, origin: beforeWrite, frame: dragged) == nil)
    #expect(!beforeWrite.contains(press))
    var settled = SettledFrame()
    settled.wrote()
    settled.observe(afterWrite, suppressed: true, buttonDown: false)
    let origin = settled.origin(reported: beforeWrite)
    let candidate = try #require(owner(bounds: screen, origin: origin, frame: dragged))
    var tracker = EdgeDropTracker()
    tracker.begin(at: press)
    tracker.update(candidate, moved: DragMove.isMove(dragged, from: origin), press: tracker.sequence)
    #expect(tracker.owner == candidate)
    #expect(tracker.drag(to: Point(x: 1000, y: 1328)) == Point(x: 1000, y: 1269))
    #expect(tracker.hovered == .bottom)
    // A resize in the same interval still never acquires the pointer.
    var resized = afterWrite; resized.width -= 40
    #expect(owner(bounds: screen, origin: origin, frame: resized) == nil)
}
