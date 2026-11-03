import Testing
@testable import MinitileCore

private struct LayoutCase: Sendable {
    var count: Int
    var variant: Variant
    var expected: [Rect]
}
private let layouts: [LayoutCase] = [
    LayoutCase(count: 1, variant: .standard, expected: [Rect(x: 130, y: 90, width: 980, height: 780)]),
    LayoutCase(count: 1, variant: .alternate, expected: [Rect(x: 130, y: 90, width: 980, height: 780)]),
    LayoutCase(count: 2, variant: .standard, expected: [Rect(x: 130, y: 90, width: 485, height: 780), Rect(x: 625, y: 90, width: 485, height: 780)]),
    LayoutCase(count: 2, variant: .alternate, expected: [Rect(x: 130, y: 90, width: 980, height: 385), Rect(x: 130, y: 485, width: 980, height: 385)]),
    LayoutCase(count: 3, variant: .standard, expected: [Rect(x: 130, y: 90, width: 485, height: 780), Rect(x: 625, y: 90, width: 485, height: 385), Rect(x: 625, y: 485, width: 485, height: 385)]),
    LayoutCase(count: 3, variant: .alternate, expected: [Rect(x: 130, y: 90, width: 322, height: 780), Rect(x: 462, y: 90, width: 316, height: 780), Rect(x: 788, y: 90, width: 322, height: 780)]),
    LayoutCase(count: 4, variant: .standard, expected: [Rect(x: 130, y: 90, width: 485, height: 385), Rect(x: 625, y: 90, width: 485, height: 385), Rect(x: 130, y: 485, width: 485, height: 385), Rect(x: 625, y: 485, width: 485, height: 385)]),
    LayoutCase(count: 4, variant: .alternate, expected: [Rect(x: 130, y: 90, width: 485, height: 385), Rect(x: 625, y: 90, width: 485, height: 385), Rect(x: 130, y: 485, width: 485, height: 385), Rect(x: 625, y: 485, width: 485, height: 385)]),
]

@Test(arguments: layouts, [false, true])
private func exactFrames(_ item: LayoutCase, portrait: Bool) {
    let frame = Rect(x: 120, y: 80, width: portrait ? 800 : 1000, height: portrait ? 1000 : 800)
    let frames = Layout.frames(frame: frame, count: item.count, variant: item.variant, gaps: 10, padding: 10)
    let expected = portrait ? item.expected.map { Rect(x: 130 + $0.y - 90, y: 90 + $0.x - 130, width: $0.height, height: $0.width) } : item.expected
    #expect(frames == expected)
}

@Test func ratiosClampAndResetOnCountAndVariantChanges() {
    var e = engine(3)
    command(&e, "page ratio -1 2")
    #expect(e.page(e.currentLocation(display: 0)!).r1 == 0.2)
    #expect(e.page(e.currentLocation(display: 0)!).r2 == 0.8)
    command(&e, "page variant")
    #expect(e.page(e.currentLocation(display: 0)!).r1 == 1.0 / 3)
    #expect(e.page(e.currentLocation(display: 0)!).r2 == 2.0 / 3)
    command(&e, "page ratio 0.8 0.2")
    let p = e.page(e.currentLocation(display: 0)!)
    #expect(abs(p.r1 - 0.6) < 0.00001)
    #expect(abs(p.r2 - p.r1 - 0.2) < 0.00001)
    _ = e.handle(.windowGone(3))
    #expect(e.page(e.currentLocation(display: 0)!).r1 == 0.5)
    #expect(e.page(e.currentLocation(display: 0)!).r2 == 0.5)
}

@Test func usesVisibleFrameAndRoundsWholeCoordinates() {
    var e = Engine(config: Config(gaps: 7, padding: 9))
    var display = testDisplay
    display.visibleFrame = Rect(x: -101.5, y: 111.5, width: 901, height: 701)
    let out = e.handle(.started(saved: nil, windows: [window(1), window(2)], displays: [display], focus: nil))
    let frames = out.scene.displays["primary"]!.frames
    #expect(frames[1] == Rect(x: -93, y: 121, width: 439, height: 683))
    #expect(frames[2] == Rect(x: 353, y: 121, width: 438, height: 683))
}

@Test func excessiveInsetsNeverProduceNegativeSizes() {
    for count in 1...4 {
        let frames = Layout.frames(frame: testDisplay.frame, count: count, gaps: 2000, padding: 2000)
        #expect(frames.allSatisfy { $0.width >= 0 && $0.height >= 0 })
    }
}
