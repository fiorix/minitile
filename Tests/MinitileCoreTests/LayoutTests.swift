import Foundation
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
    LayoutCase(count: 3, variant: .twoByOneTall, expected: [Rect(x: 625, y: 90, width: 485, height: 780), Rect(x: 130, y: 90, width: 485, height: 385), Rect(x: 130, y: 485, width: 485, height: 385)]),
    LayoutCase(count: 3, variant: .stacked, expected: [Rect(x: 130, y: 90, width: 980, height: 255), Rect(x: 130, y: 355, width: 980, height: 250), Rect(x: 130, y: 615, width: 980, height: 255)]),
    LayoutCase(count: 3, variant: .oneByTwoWide, expected: [Rect(x: 130, y: 90, width: 980, height: 385), Rect(x: 130, y: 485, width: 485, height: 385), Rect(x: 625, y: 485, width: 485, height: 385)]),
    LayoutCase(count: 3, variant: .twoByOneWide, expected: [Rect(x: 130, y: 485, width: 980, height: 385), Rect(x: 130, y: 90, width: 485, height: 385), Rect(x: 625, y: 90, width: 485, height: 385)]),
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
    while e.page(e.currentLocation(display: 0)!).variant != .alternate { command(&e, "page variant") }
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

@Test(arguments: [false, true])
func variantsUndefinedForACountUseItsStandardLayout(portrait: Bool) {
    let frame = Rect(x: 120, y: 80, width: portrait ? 800 : 1000, height: portrait ? 1000 : 800)
    for count in [1, 2, 4] {
        let standard = Layout.frames(frame: frame, count: count, variant: .standard)
        for variant in [Variant.twoByOneTall, .stacked, .oneByTwoWide, .twoByOneWide] {
            #expect(Layout.frames(frame: frame, count: count, variant: variant) == standard)
            #expect(Layout.defaults(count: count, variant: variant) == (0.5, 0.5))
        }
    }
    #expect(Layout.defaults(count: 3, variant: .twoByOneTall) == (0.5, 0.5))
    #expect(Layout.defaults(count: 3, variant: .oneByTwoWide) == (0.5, 0.5))
    #expect(Layout.defaults(count: 3, variant: .stacked) == (1.0 / 3, 2.0 / 3))
    let spaced = Layout.ratios(0.5, 0.55, count: 3, variant: .stacked)
    #expect(abs(spaced.0 - 0.5) < 0.00001 && abs(spaced.1 - 0.7) < 0.00001)
    #expect(Layout.ratios(0.5, 0.55, count: 3, variant: .twoByOneTall) == (0.5, 0.55))
    #expect(Layout.ratios(0.5, 0.55, count: 3, variant: .twoByOneWide) == (0.5, 0.55))
}

@Test func variantCyclesThroughItsCountsLayoutsAndResetsRatios() {
    func cycle(_ count: Int) -> [Variant] {
        var e = engine(count)
        return (0..<6).map { _ in
            command(&e, "page ratio 0.6 0.75")
            command(&e, "page variant")
            let page = e.page(e.currentLocation(display: 0)!)
            if count == 2 || count == 3 { #expect((page.r1, page.r2) == Layout.defaults(count: count, variant: page.variant)) }
            return page.variant
        }
    }
    #expect(cycle(3) == [.twoByOneTall, .oneByTwoWide, .twoByOneWide, .alternate, .stacked, .oneByTwoTall])
    #expect(cycle(2) == [.alternate, .standard, .alternate, .standard, .alternate, .standard])
    for count in [1, 4] {
        var e = engine(count)
        let before = e.savedState()
        let out = command(&e, "page variant")
        #expect(!out.stateChanged)
        #expect(e.savedState() == before)
    }
}

@Test(arguments: [Variant.twoByOneTall, .stacked, .oneByTwoWide, .twoByOneWide])
func pageKeepsItsVariantAcrossCountChangesAndCyclesOnFromStandard(_ variant: Variant) {
    var e = engine(3)
    while e.page(e.currentLocation(display: 0)!).variant != variant { command(&e, "page variant") }
    _ = e.handle(.windowGone(3))
    let page = e.page(e.currentLocation(display: 0)!)
    #expect(page.variant == variant)
    #expect((page.r1, page.r2) == (0.5, 0.5))
    let frames = e.makeScene().displays["primary"]!.frames
    #expect([frames[1]!, frames[2]!] == Layout.frames(frame: testDisplay.visibleFrame, count: 2))
    if case .object(let fields) = command(&e, "page info").reply!.data { #expect(fields["variant"] == .string(variant.rawValue)) }
    else { Issue.record("Expected page object") }
    _ = e.handle(.windowAppeared(window(3)))
    let restored = e.page(e.currentLocation(display: 0)!)
    #expect((restored.r1, restored.r2) == Layout.defaults(count: 3, variant: variant))
    _ = e.handle(.windowGone(3))
    command(&e, "page variant")
    #expect(e.page(e.currentLocation(display: 0)!).variant == .alternate)
}

@Test func savedVariantsDecodeByName() throws {
    let names = ["standard", "alternate", "stacked", "1x2-tall", "2x1-tall", "1x2-wide", "2x1-wide"]
    let data = try JSONEncoder().encode(names)
    #expect(try JSONDecoder().decode([Variant].self, from: data) == Variant.allCases)
    #expect(Variant.allCases.map(\.rawValue) == names)
    #expect(try JSONEncoder().encode(Variant.allCases) == data)
    #expect(try JSONDecoder().decode([Variant].self, from: Data(#"["mirrored"]"#.utf8)) == [.twoByOneTall])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([Variant].self, from: Data(#"["sideways"]"#.utf8)) }
}
