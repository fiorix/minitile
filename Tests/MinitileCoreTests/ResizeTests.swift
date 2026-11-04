import Testing
@testable import MinitileCore

struct LayoutKind: Sendable, CustomTestStringConvertible {
    var count: Int
    var variant: Variant
    var portrait: Bool
    var testDescription: String { "\(count) \(variant)\(portrait ? " portrait" : "")" }
}

let layoutKinds = (1...4).flatMap { count in
    Variant.allCases.flatMap { variant in [false, true].map { LayoutKind(count: count, variant: variant, portrait: $0) } }
}

/// The shown page holds windows 1...count at the variant's default ratios, with no gaps or padding, so tile edges are cuts.
func layoutEngine(_ kind: LayoutKind) -> Engine {
    var e = Engine(config: Config(gaps: 0, padding: 0))
    let display = kind.portrait ? DisplayInfo(id: "primary", frame: Rect(x: -800, y: 200, width: 800, height: 1000), isPrimary: true)
        : testDisplay
    _ = e.handle(.started(saved: nil, windows: (1...kind.count).map { window(WindowID($0)) }, displays: [display], focus: nil))
    let (a, b) = Layout.defaults(count: kind.count, variant: kind.variant)
    e.state.displays[0].workspaces[0].pages[0].variant = kind.variant
    e.state.displays[0].workspaces[0].pages[0].r1 = a
    e.state.displays[0].workspaces[0].pages[0].r2 = b
    return e
}

func tileFrames(_ e: Engine) -> [WindowID: Rect] { e.makeScene().displays["primary"]!.frames }

func near(_ a: Rect, _ b: Rect) -> Bool {
    abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 && abs(a.maxX - b.maxX) <= 1 && abs(a.maxY - b.maxY) <= 1
}

@Test(arguments: layoutKinds)
func edgeAndCornerDragsMoveInnerSidesAndBorderSidesSnapBack(_ kind: LayoutKind) {
    for slot in 0..<kind.count {
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)] {
            var e = layoutEngine(kind)
            let id = WindowID(slot + 1)
            let area = e.state.displays[0].info.visibleFrame
            let f = tileFrames(e)[id]!
            var x0 = f.x, x1 = f.maxX, y0 = f.y, y1 = f.maxY
            if dx < 0 { x0 -= 30 } else if dx > 0 { x1 += 30 }
            if dy < 0 { y0 -= 30 } else if dy > 0 { y1 += 30 }
            let dragged = Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            let out = e.handle(.dragEnded(id, frame: dragged, cursor: dragged.center))
            let ex0 = f.x > area.x ? x0 : f.x, ex1 = f.maxX < area.maxX ? x1 : f.maxX
            let ey0 = f.y > area.y ? y0 : f.y, ey1 = f.maxY < area.maxY ? y1 : f.maxY
            let expected = Rect(x: ex0, y: ey0, width: ex1 - ex0, height: ey1 - ey0)
            let actual = out.scene.displays["primary"]!.frames[id]!
            #expect(near(actual, expected), "\(kind) slot \(slot) drag \(dx),\(dy): \(actual) != \(expected)")
            #expect(out.rewrite == [id])
        }
    }
}

@Test(arguments: layoutKinds)
func physicalSharesSetTheTileExtentOnEachSplitAxis(_ kind: LayoutKind) {
    for slot in 0..<kind.count {
        var e = layoutEngine(kind)
        let id = WindowID(slot + 1)
        let area = e.state.displays[0].info.visibleFrame
        let f = tileFrames(e)[id]!
        let out = command(&e, "window resize \(id) 0.45x0.4")
        let actual = out.scene.displays["primary"]!.frames[id]!
        let width = f.width == area.width ? area.width : 0.45 * area.width
        let height = f.height == area.height ? area.height : 0.4 * area.height
        #expect(abs(actual.width - width) <= 1 && abs(actual.height - height) <= 1, "\(kind) slot \(slot): \(actual)")
    }
}

@Test func singleShareFollowsTheSplitAxisOfMirroredAndStackedLayouts() {
    var mirrored = layoutEngine(LayoutKind(count: 3, variant: .mirrored, portrait: false))
    command(&mirrored, "window resize 1 0.6")
    #expect(tileFrames(mirrored)[1] == Rect(x: 520, y: 80, width: 600, height: 800))
    command(&mirrored, "window resize 3 0.3")
    #expect(tileFrames(mirrored)[3] == Rect(x: 120, y: 480, width: 300, height: 400))
    var stacked = layoutEngine(LayoutKind(count: 3, variant: .stacked, portrait: false))
    command(&stacked, "window resize 2 0.4")
    #expect(tileFrames(stacked)[2] == Rect(x: 120, y: 293, width: 1000, height: 320))
    #expect(tileFrames(stacked)[3]?.y == 613)
    var portrait = layoutEngine(LayoutKind(count: 3, variant: .stacked, portrait: true))
    command(&portrait, "window resize 1 0.4")
    #expect(tileFrames(portrait)[1] == Rect(x: -800, y: 200, width: 320, height: 1000))
}
