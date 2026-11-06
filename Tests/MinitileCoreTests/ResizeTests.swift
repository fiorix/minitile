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

@Test func singleShareFollowsTheSplitAxisOfEachThreeWindowLayout() {
    var tall = layoutEngine(LayoutKind(count: 3, variant: .twoByOneTall, portrait: false))
    command(&tall, "window resize 1 0.6")
    #expect(tileFrames(tall)[1] == Rect(x: 520, y: 80, width: 600, height: 800))
    command(&tall, "window resize 3 0.3")
    #expect(tileFrames(tall)[3] == Rect(x: 120, y: 480, width: 300, height: 400))
    var stacked = layoutEngine(LayoutKind(count: 3, variant: .stacked, portrait: false))
    command(&stacked, "window resize 2 0.4")
    #expect(tileFrames(stacked)[2] == Rect(x: 120, y: 293, width: 1000, height: 320))
    #expect(tileFrames(stacked)[3]?.y == 613)
    var portrait = layoutEngine(LayoutKind(count: 3, variant: .stacked, portrait: true))
    command(&portrait, "window resize 1 0.4")
    #expect(tileFrames(portrait)[1] == Rect(x: -800, y: 200, width: 320, height: 1000))
    var top = layoutEngine(LayoutKind(count: 3, variant: .oneByTwoWide, portrait: false))
    command(&top, "window resize 1 0.6")
    #expect(tileFrames(top)[1] == Rect(x: 120, y: 80, width: 1000, height: 480))
    command(&top, "window resize 3 0.3")
    #expect(tileFrames(top)[3] == Rect(x: 620, y: 640, width: 500, height: 240))
    var bottom = layoutEngine(LayoutKind(count: 3, variant: .twoByOneWide, portrait: false))
    command(&bottom, "window resize 1 0.6")
    #expect(tileFrames(bottom)[1] == Rect(x: 120, y: 400, width: 1000, height: 480))
    var left = layoutEngine(LayoutKind(count: 3, variant: .oneByTwoWide, portrait: true))
    command(&left, "window resize 1 0.4")
    #expect(tileFrames(left)[1] == Rect(x: -800, y: 200, width: 320, height: 1000))
}

@Test(arguments: layoutKinds)
func arrowsMoveTheEdgeOnTheirSideOrShrinkFromTheOtherOne(_ kind: LayoutKind) {
    for slot in 0..<kind.count {
        for direction in ["left", "right", "up", "down"] {
            var e = layoutEngine(kind)
            let id = WindowID(slot + 1)
            let area = e.state.displays[0].info.visibleFrame
            let before = tileFrames(e)
            let out = command(&e, "window resize \(id) \(direction)")
            let f = before[id]!
            let horizontal = direction == "left" || direction == "right"
            let forward = direction == "right" || direction == "down"
            let step = (forward ? 0.05 : -0.05) * (horizontal ? area.width : area.height)
            var low = horizontal ? f.x : f.y, high = horizontal ? f.maxX : f.maxY
            let inner = (low: low > (horizontal ? area.x : area.y), high: high < (horizontal ? area.maxX : area.maxY))
            // The edge on the arrow's side moves when it is inner; otherwise the opposite inner edge moves the same way.
            if forward ? inner.high : inner.low { if forward { high += step } else { low += step } }
            else if forward ? inner.low : inner.high { if forward { low += step } else { high += step } }
            let expected = horizontal ? Rect(x: low, y: f.y, width: high - low, height: f.height)
                : Rect(x: f.x, y: low, width: f.width, height: high - low)
            let actual = out.scene.displays["primary"]!.frames[id]!
            #expect(near(actual, expected), "\(kind) slot \(slot) \(direction): \(actual) != \(expected)")
            if !inner.low && !inner.high {
                #expect(out.scene.displays["primary"]!.frames == before)
                #expect(out.events.isEmpty && out.actions.isEmpty && out.rewrite.isEmpty && !out.stateChanged)
            } else {
                #expect(out.stateChanged && out.rewrite.isEmpty && out.actions.isEmpty)
            }
        }
    }
}

@Test func arrowsStopAtTheClampAndTheThreeSliceSpacing() {
    var e = layoutEngine(LayoutKind(count: 3, variant: .stacked, portrait: false))
    for _ in 0..<8 { command(&e, "window resize 1 down") }
    var page = e.page(e.currentLocation(display: 0)!)
    #expect(abs(page.r2 - 2.0 / 3) < 0.00001 && abs(page.r1 - (2.0 / 3 - 0.2)) < 0.00001)
    let stuck = command(&e, "window resize 1 down")
    #expect(!stuck.stateChanged && stuck.events.isEmpty && stuck.rewrite.isEmpty)
    for _ in 0..<8 { command(&e, "window resize 2 up") }
    page = e.page(e.currentLocation(display: 0)!)
    #expect(page.r1 == 0.2 && abs(page.r2 - 2.0 / 3) < 0.00001)
    command(&e, "window focus 3")
    for _ in 0..<8 { command(&e, "window resize up") }
    page = e.page(e.currentLocation(display: 0)!)
    #expect(page.r1 == 0.2 && abs(page.r2 - 0.4) < 0.00001)
    var four = layoutEngine(LayoutKind(count: 4, variant: .standard, portrait: true))
    for _ in 0..<8 { command(&four, "window resize 4 left") }
    #expect(four.page(four.currentLocation(display: 0)!).r2 == 0.2)
    #expect(four.page(four.currentLocation(display: 0)!).r1 == 0.5)
}

@Test func floatingArrowsResizeFromTheTopLeftWithinTheLayoutArea() {
    var e = engine(3, config: Config(gaps: 0, padding: 0))
    command(&e, "window float 3 on")
    command(&e, "window focus 3")
    #expect(command(&e, "window resize right").actions == [.setFrame(3, Rect(x: 120, y: 80, width: 450, height: 300))])
    #expect(command(&e, "window resize down").actions == [.setFrame(3, Rect(x: 120, y: 80, width: 450, height: 340))])
    #expect(command(&e, "window resize up").actions == [.setFrame(3, Rect(x: 120, y: 80, width: 450, height: 300))])
    #expect(e.savedState().windows[3]?.info.frame == Rect(x: 120, y: 80, width: 450, height: 300))
    // Shrinking stops at a fifth of the layout area.
    for _ in 0..<4 { command(&e, "window resize left") }
    #expect(e.savedState().windows[3]?.info.frame.width == 250)
    #expect(command(&e, "window resize left").actions == [.setFrame(3, Rect(x: 120, y: 80, width: 200, height: 300))])
    let floor = command(&e, "window resize left")
    #expect(floor.actions.isEmpty && !floor.stateChanged)
    // Growing stops at the layout area's edge, and a window already past it keeps its size.
    var moved = window(3)
    moved.frame = Rect(x: 820, y: 700, width: 250, height: 150)
    _ = e.handle(.windowUpdated(moved))
    #expect(command(&e, "window resize right").actions == [.setFrame(3, Rect(x: 820, y: 700, width: 300, height: 150))])
    #expect(command(&e, "window resize right").actions.isEmpty)
    #expect(command(&e, "window resize down").actions == [.setFrame(3, Rect(x: 820, y: 700, width: 300, height: 180))])
    moved.frame = Rect(x: 1000, y: 80, width: 400, height: 300)
    _ = e.handle(.windowUpdated(moved))
    let past = command(&e, "window resize right")
    #expect(past.actions.isEmpty && !past.stateChanged)
    #expect(command(&e, "window resize left").actions == [.setFrame(3, Rect(x: 1000, y: 80, width: 350, height: 300))])
}

@Test func directionalResizeNeedsAnActiveTileOrAFloatingWindow() {
    var e = engine(2)
    var minimized = window(2)
    minimized.minimized = true
    _ = e.handle(.windowUpdated(minimized))
    #expect(e.handle(.command(["window", "resize", "2", "left"])).reply?.ok == false)
    #expect(e.handle(.command(["window", "resize", "1", "sideways"])).reply?.ok == false)
    #expect(Engine.help.contains("window resize [ID] SHARE|WIDTHxHEIGHT|left|right|up|down"))
}
