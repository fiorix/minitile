import Testing
@testable import MinitileCore

private func currentPage(_ e: Engine) -> PageState { e.page(e.currentLocation(display: 0)!) }

@Test func layoutsPerCountFollowCyclingOrder() {
    #expect(Layout.variants(count: 0) == [])
    #expect(Layout.variants(count: 1) == [.standard])
    #expect(Layout.variants(count: 2) == [.standard, .alternate])
    #expect(Layout.variants(count: 3) == [.standard, .mirrored, .alternate, .stacked])
    #expect(Layout.variants(count: 4) == [.standard])
    #expect(Layout.variants(count: 5) == [])
    for count in 0...5 {
        let order = Layout.variants(count: count)
        for variant in Variant.allCases {
            let effective = Layout.effective(variant, count: count)
            #expect(effective == (order.contains(variant) ? variant : .standard))
            let index = order.firstIndex(of: effective)
            #expect(Layout.next(variant, count: count) == (order.count > 1 ? order[(index! + 1) % order.count] : nil))
        }
    }
}

@Test(arguments: [(3, 0, [3, 1, 2]), (3, 1, [1, 3, 2]), (1, 2, [2, 3, 1]), (1, 1, [2, 1, 3]), (2, 0, [2, 1, 3])])
func placeMovesWindowAndKeepsOthersInOrder(_ id: WindowID, _ slot: Int, _ expected: [WindowID]) {
    var e = engine(3)
    command(&e, "window place \(id) standard \(slot)")
    #expect(grid(e) == [[expected]])
}

@Test func placeChangingVariantResetsRatiosAndSlotOnlyKeepsThem() {
    var e = engine(3)
    command(&e, "page ratio 0.6 0.7")
    command(&e, "window place 3 standard 0")
    #expect(currentPage(e).variant == .standard)
    #expect((currentPage(e).r1, currentPage(e).r2) == (0.6, 0.7))
    command(&e, "window place 1 stacked 2")
    #expect(grid(e) == [[[3, 2, 1]]])
    #expect(currentPage(e).variant == .stacked)
    #expect((currentPage(e).r1, currentPage(e).r2) == Layout.defaults(count: 3, variant: .stacked))
    let frames = e.makeScene().displays["primary"]!.frames
    let expected = Layout.frames(frame: testDisplay.visibleFrame, count: 3, variant: .stacked)
    #expect([frames[3]!, frames[2]!, frames[1]!] == expected)
}

@Test func placeKeepsRatiosWhenTheCountAlreadyLaysOutThatVariant() {
    var e = engine(3)
    command(&e, "page variant")
    #expect(currentPage(e).variant == .mirrored)
    _ = e.handle(.windowGone(3))
    command(&e, "page ratio 0.6")
    command(&e, "window place 1 standard 1")
    #expect(grid(e) == [[[2, 1]]])
    #expect(currentPage(e).variant == .standard)
    #expect(currentPage(e).r1 == 0.6)
}

@Test(arguments: [
    (2, "window place 1 mirrored 0"), (2, "window place 1 stacked 1"), (2, "window place 1 standard 2"),
    (2, "window place 1 alternate -1"), (2, "window place 1 wat 0"), (2, "window place 1 standard x"),
    (2, "window place 1 standard"), (2, "window place 1 standard 0 extra"), (2, "window place 99 standard 0"),
    (4, "window place 1 alternate 0"), (4, "window place 1 standard 4"), (1, "window place 1 alternate 0"),
    (1, "window place 1 standard 1"),
])
func placeRejectsLayoutsAndSlotsTheCountLacks(_ count: Int, _ text: String) {
    var e = engine(count)
    command(&e, "window focus 1")
    let before = e.savedState()
    let out = e.handle(.command(text.split(separator: " ").map(String.init)))
    #expect(out.reply?.ok == false)
    #expect(out.actions.isEmpty)
    #expect(out.rewrite.isEmpty)
    #expect(e.savedState() == before)
}

@Test func placeCountsActiveTilesAndLeavesReservedAndFloatingWindowsInPlace() {
    var e = engine(4)
    _ = e.handle(.windowGone(4))
    _ = e.handle(.windowAppeared(WindowInfo(id: 9, pid: 9, tileable: false, display: "primary")))
    var minimized = window(2)
    minimized.minimized = true
    _ = e.handle(.windowUpdated(minimized))
    #expect(grid(e) == [[[1, 2, 3, 9]]])
    for text in ["window place 9 standard 0", "window place 2 standard 0", "window place 1 mirrored 0", "window place 1 standard 2"] {
        #expect(e.handle(.command(text.split(separator: " ").map(String.init))).reply?.ok == false)
    }
    command(&e, "window place 3 alternate 0")
    #expect(grid(e) == [[[3, 1, 2, 9]]])
    command(&e, "window place 3 standard 1")
    #expect(grid(e) == [[[1, 3, 2, 9]]])
    #expect(currentPage(e).variant == .standard)
    _ = e.handle(.windowUpdated(window(2)))
    command(&e, "window place 2 mirrored 0")
    #expect(grid(e) == [[[2, 1, 3, 9]]])
    _ = e.handle(.windowAppeared(window(5)))
    let frames = e.makeScene().displays["primary"]!.frames
    #expect([frames[2]!, frames[1]!, frames[3]!, frames[5]!] == Layout.frames(frame: testDisplay.visibleFrame, count: 4))
    minimized = window(1)
    minimized.minimized = true
    _ = e.handle(.windowUpdated(minimized))
    command(&e, "page ratio 0.6 0.7")
    command(&e, "window place 5 mirrored 1")
    #expect(grid(e) == [[[2, 1, 5, 3, 9]]])
    #expect((currentPage(e).r1, currentPage(e).r2) == (0.6, 0.7))
}

@Test func placeFocusesTheWindowAndReportsWindowsWhoseSlotChanged() {
    var e = engine(3)
    command(&e, "window focus 1")
    let moved = command(&e, "window place 3 standard 0")
    #expect(moved.actions == [.focus(3)])
    #expect(moved.rewrite == [3])
    #expect(e.savedState().focus == 3)
    #expect(moved.events.filter { $0.type == "window_moved" }.map(\.data) == [.number(3), .number(1), .number(2)])
    let variant = command(&e, "window place 3 alternate 0")
    #expect(variant.actions == [.focus(3)])
    #expect(!variant.events.contains { $0.type == "window_moved" })
    let unchanged = command(&e, "window place 3 alternate 0")
    #expect(unchanged.actions.isEmpty)
    #expect(unchanged.events.isEmpty)
    #expect(unchanged.rewrite == [3])
    #expect(!unchanged.stateChanged)
}

@Test func placeShowsTheWindowsPageAndDefaultsToTheFocusedWindow() {
    var e = engine(6)
    command(&e, "window place 6 alternate 0")
    #expect(grid(e) == [[[1, 2, 3, 4], [6, 5]]])
    let scene = e.makeScene().displays["primary"]!
    #expect(scene.visible == [6, 5])
    #expect([scene.frames[6]!, scene.frames[5]!] == Layout.frames(frame: testDisplay.visibleFrame, count: 2, variant: .alternate))
    command(&e, "window place standard 1")
    #expect(grid(e) == [[[1, 2, 3, 4], [5, 6]]])
    #expect(Engine.help.contains("window place [ID] standard|alternate|mirrored|stacked SLOT"))
}
