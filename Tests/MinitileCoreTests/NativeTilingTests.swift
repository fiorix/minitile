import Foundation
import Testing
@testable import MinitileCore

private let nativeArea = testDisplay.visibleFrame

@Test func nativeZeroMarginRoundingUsesConfiguredSpacing() {
    let area = Rect(x: 0, y: 39, width: 2056, height: 1290)
    var e = engine(3)
    _ = e.handle(.displaysChanged([DisplayInfo(id: "primary", frame: area)]))
    // Observed native right half: its left edge overlaps the left quarters by one point.
    let out = e.handle(.nativeTiled(1, frame: Rect(x: 1027, y: 39, width: 1029, height: 1290)))
    #expect(out.scene.displays["primary"]?.frames == [
        1: Rect(x: 1032, y: 47, width: 1016, height: 1274),
        2: Rect(x: 8, y: 47, width: 1016, height: 633),
        3: Rect(x: 8, y: 688, width: 1016, height: 633),
    ])
    var restored = Engine()
    let restarted = restored.handle(.started(saved: e.savedState(), windows: (1...3).map { window(WindowID($0)) },
                                             displays: [DisplayInfo(id: "primary", frame: area)], focus: 1))
    #expect(restarted.scene == out.scene)
}

private func half(_ side: String, area: Rect = nativeArea, margin: Double = 0) -> Rect {
    switch side {
    case "left": Rect(x: area.x + margin, y: area.y + margin, width: area.width / 2 - 2 * margin, height: area.height - 2 * margin)
    case "right": Rect(x: area.center.x + margin, y: area.y + margin, width: area.width / 2 - 2 * margin, height: area.height - 2 * margin)
    case "top": Rect(x: area.x + margin, y: area.y + margin, width: area.width - 2 * margin, height: area.height / 2 - 2 * margin)
    default: Rect(x: area.x + margin, y: area.center.y + margin, width: area.width - 2 * margin, height: area.height / 2 - 2 * margin)
    }
}

private func spacedHalf(_ side: String, area: Rect = nativeArea, config: Config = .default) -> Rect {
    let padding = config.padding, gap = config.gaps / 2
    switch side {
    case "left": return Rect(x: area.x + padding, y: area.y + padding,
                             width: area.width / 2 - padding - gap, height: area.height - 2 * padding)
    case "right": return Rect(x: area.center.x + gap, y: area.y + padding,
                              width: area.width / 2 - padding - gap, height: area.height - 2 * padding)
    case "top": return Rect(x: area.x + padding, y: area.y + padding,
                            width: area.width - 2 * padding, height: area.height / 2 - padding - gap)
    default: return Rect(x: area.x + padding, y: area.center.y + gap,
                         width: area.width - 2 * padding, height: area.height / 2 - padding - gap)
    }
}

@Test(arguments: ["left", "right", "top", "bottom"], [0.0, 8.0, 16.0])
func nativeHalfKeepsSelectionAndSpillsFourthToOwnWorkspace(_ side: String, _ margin: Double) throws {
    var e = engine(5)
    command(&e, "window focus 4")
    let frame = half(side, margin: margin)
    let out = e.handle(.nativeTiled(4, frame: frame))
    let scene = try #require(out.scene.displays["primary"])
    let expected = spacedHalf(side)
    #expect(scene.frames[4] == expected)
    #expect(Set(scene.visible) == [1, 2, 4])
    #expect(scene.stashed == [3, 5])
    #expect(grid(e)[0][1] == [5])
    #expect(grid(e)[1] == [[3]])
    #expect(e.savedState().focus == 4)
    #expect(e.currentLocation(display: 0)?.workspace == 0)
    #expect(out.actions.isEmpty)
    #expect(out.events.contains { $0.type == "window_moved" && $0.data == .number(3) })
    for id: WindowID in [1, 2] {
        let other = try #require(scene.frames[id])
        #expect(other.maxX + 8 <= expected.x || other.x >= expected.maxX + 8 || other.maxY + 8 <= expected.y || other.y >= expected.maxY + 8)
    }
    let again = e.handle(.windowUpdated(window(4)))
    #expect(again.scene.displays["primary"]?.frames[4] == expected)
    command(&e, "workspace next")
    #expect(e.makeScene().displays["primary"]?.visible == [3])
    command(&e, "workspace prev")
    #expect(e.makeScene().displays["primary"]?.frames[4] == expected)
}

@Test(arguments: [1, 2, 3, 4], [0, 1, 2, 3])
func nativeQuartersKeepChosenSlotAndSpacingWithSparsePages(_ count: Int, _ corner: Int) throws {
    var e = engine(count)
    let x = nativeArea.x + (corner % 2 == 0 ? 0 : nativeArea.width / 2)
    let y = nativeArea.y + (corner < 2 ? 0 : nativeArea.height / 2)
    let frame = Rect(x: x + 8, y: y + 8, width: nativeArea.width / 2 - 16, height: nativeArea.height / 2 - 16)
    let out = e.handle(.nativeTiled(1, frame: frame))
    let scene = try #require(out.scene.displays["primary"])
    let expected = Layout.frames(frame: nativeArea, count: 4)[corner]
    #expect(scene.frames[1] == expected)
    #expect(scene.visible.count == count)
    #expect(scene.stashed.isEmpty)
    #expect(e.savedState().displays[0].workspaces.count == 1)
    for id in scene.visible where id != 1 {
        let other = try #require(scene.frames[id])
        #expect(other.maxX + 8 <= expected.x || other.x >= expected.maxX + 8 || other.maxY + 8 <= expected.y || other.y >= expected.maxY + 8)
    }
}

@Test func nativeFillMovesEachNeighbourToItsOwnWorkspace() {
    var e = engine(4)
    let out = e.handle(.nativeTiled(2, frame: nativeArea))
    #expect(grid(e) == [[[2]], [[1]], [[3]], [[4]]])
    #expect(out.scene.displays["primary"]?.frames[2] == Layout.frames(frame: nativeArea, count: 1)[0])
    #expect(out.scene.displays["primary"]?.visible == [2])
    #expect(e.savedState().focus == 2)
}

@Test func nativeArrangeTwoHalvesKeepsBothSelectionsAndSpillsTheOthers() {
    var e = engine(4)
    let left = half("left", margin: 8), right = half("right", margin: 8)
    let out = e.handle(.nativeTiled(4, frame: left, companions: [2: right]))
    #expect(grid(e) == [[[4, 2]], [[1]], [[3]]])
    #expect(out.scene.displays["primary"]?.frames[4] == spacedHalf("left"))
    #expect(out.scene.displays["primary"]?.frames[2] == spacedHalf("right"))
    #expect(e.savedState().focus == 4)
    #expect(out.actions.isEmpty)
}

@Test func nativeArrangeQuartersPreservesTheNativeWindowOrder() {
    var e = engine(4)
    let frames = [Rect(x: 120, y: 80, width: 500, height: 400), Rect(x: 620, y: 80, width: 500, height: 400),
                  Rect(x: 120, y: 480, width: 500, height: 400), Rect(x: 620, y: 480, width: 500, height: 400)]
    let out = e.handle(.nativeTiled(4, frame: frames[0], companions: [3: frames[1], 2: frames[2], 1: frames[3]]))
    #expect(grid(e) == [[[4, 3, 2, 1]]])
    let expected = Layout.frames(frame: nativeArea, count: 4)
    #expect(out.scene.displays["primary"]?.frames == [4: expected[0], 3: expected[1], 2: expected[2], 1: expected[3]])
}

@Test func nativeArrangeRejectsOverlappingSelectionsWithoutMovingAnything() {
    var e = engine(4)
    let before = e.savedState()
    _ = e.handle(.nativeTiled(1, frame: half("left"), companions: [2: half("left")]))
    #expect(e.savedState() == before)
}

@Test func nativeArrangementKeepsObservedFocusOnAnUnchangedTile() {
    var e = engine(4)
    command(&e, "window focus 1")
    let out = e.handle(.nativeTiled(4, frame: half("left")))
    #expect(e.savedState().focus == 1)
    #expect(out.actions.isEmpty)
}

@Test func nativeLayoutDoesNotSurviveEnteringFullScreen() {
    var e = engine(1)
    _ = e.handle(.nativeTiled(1, frame: half("left")))
    var full = window(1)
    full.fullscreen = true
    _ = e.handle(.windowUpdated(full))
    #expect(e.page(e.currentLocation(display: 0)!).nativeLayout == nil)
    let out = e.handle(.windowUpdated(window(1)))
    #expect(out.scene.displays["primary"]?.frames[1] == Layout.frames(frame: nativeArea, count: 1)[0])
}

@Test(arguments: ["left", "right", "top", "bottom"])
func nativeHalvesUsePhysicalAxesOnPortraitDisplays(_ side: String) {
    let area = Rect(x: -800, y: -400, width: 800, height: 1200)
    var e = engine(4)
    _ = e.handle(.displaysChanged([DisplayInfo(id: "primary", frame: area)]))
    let frame = half(side, area: area, margin: 8)
    let out = e.handle(.nativeTiled(1, frame: frame))
    #expect(out.scene.displays["primary"]?.frames[1] == spacedHalf(side, area: area))
    #expect(Set(out.scene.displays["primary"]!.visible) == [1, 2, 3])
    #expect(grid(e)[1] == [[4]])
}

@Test func nativeTilingLeavesFloatingAndReservedWindowsInPlace() {
    var e = engine(4)
    var minimized = window(2)
    minimized.minimized = true
    _ = e.handle(.windowUpdated(minimized))
    _ = e.handle(.windowAppeared(WindowInfo(id: 9, pid: 9, tileable: false, display: "primary")))
    let out = e.handle(.nativeTiled(4, frame: half("right")))
    #expect(grid(e) == [[[4, 2, 1, 3, 9]]])
    #expect(out.scene.displays["primary"]?.frames[2] == nil)
    #expect(out.scene.displays["primary"]?.frames[9] == nil)
    #expect(e.savedState().windows[2]?.info.minimized == true)
    #expect(e.savedState().windows[9]?.floating == true)
}

@Test func nativeTilingRejectsUnrelatedGeometryAndIneligibleWindows() {
    for id: WindowID in [1, 2, 5, 99] {
        var e = engine(5)
        command(&e, "window float 1")
        var minimized = window(2)
        minimized.minimized = true
        _ = e.handle(.windowUpdated(minimized))
        let before = e.savedState()
        let out = e.handle(.nativeTiled(id, frame: half("left")))
        #expect(e.savedState() == before)
        #expect(out.actions.isEmpty)
    }
    for frame in [Rect(x: 250, y: 150, width: 510, height: 460),
                  Rect(x: .nan, y: 0, width: 500, height: 800),
                  Rect(x: 120, y: 80, width: 650, height: 800),
                  Rect(x: 120, y: 80, width: 0, height: 800)] {
        var e = engine(4)
        let before = e.savedState()
        _ = e.handle(.nativeTiled(1, frame: frame))
        #expect(e.savedState() == before)
    }
}

@Test func nativeLayoutRoundTripsAndOldStateNeedsNoNewField() throws {
    var e = engine(4)
    let frame = half("bottom", margin: 8)
    _ = e.handle(.nativeTiled(1, frame: frame))
    let saved = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(e.savedState()))
    var restored = Engine()
    let out = restored.handle(.started(saved: saved, windows: (1...4).map { window(WindowID($0)) }, displays: [testDisplay], focus: 1))
    #expect(out.scene.displays["primary"]?.frames[1] == spacedHalf("bottom"))
    #expect(grid(restored) == grid(e))
    let old = #"{"id":1,"windows":[],"variant":"standard","r1":0.5,"r2":0.5,"layoutCount":0}"#
    #expect(try JSONDecoder().decode(PageState.self, from: Data(old.utf8)).nativeLayout == nil)
}

@Test(arguments: ["left", "right", "top", "bottom"])
func nativeTilingUsesCustomGapsAndPadding(_ side: String) {
    let config = Config(gaps: 18, padding: 32)
    var e = engine(3, config: config)
    let out = e.handle(.nativeTiled(1, frame: half(side)))
    #expect(out.scene.displays["primary"]?.frames[1] == spacedHalf(side, config: config))
    let page = e.page(e.currentLocation(display: 0)!)
    let expected = Layout.frames(frame: nativeArea, count: 3, variant: page.variant, gaps: 18, padding: 32)
    #expect(page.windows.compactMap { out.scene.displays["primary"]?.frames[$0] } == expected)
    #expect(page.nativeLayout != nil)
}

@Test(arguments: ["page variant", "page ratio 0.6", "window place 1 standard 0", "window resize 1 0.6"])
func explicitLayoutCommandsReplaceNativeGeometry(_ text: String) {
    var e = engine(4)
    _ = e.handle(.nativeTiled(1, frame: half("left")))
    command(&e, text)
    #expect(e.page(e.currentLocation(display: 0)!).nativeLayout == nil)
}

@Test func nativeLayoutExpiresWhenMembershipOrDisplayChanges() {
    var e = engine(4)
    _ = e.handle(.nativeTiled(1, frame: half("left")))
    _ = e.handle(.windowGone(2))
    #expect(e.page(e.currentLocation(display: 0)!).nativeLayout == nil)
    _ = e.handle(.nativeTiled(1, frame: half("right")))
    var display = testDisplay
    display.visibleFrame.width += 100
    _ = e.handle(.displaysChanged([display]))
    #expect(e.page(e.currentLocation(display: 0)!).nativeLayout == nil)
}
