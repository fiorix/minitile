import CoreGraphics
import MinitileCore
import Testing
@testable import minitile

private let display = DisplayInfo(id: "d", frame: Rect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: Rect(x: 0, y: 33, width: 1512, height: 900), isPrimary: true)
private let config = Config(gaps: 10, padding: 6)

private func engine(_ count: Int) -> Engine {
    var engine = Engine(config: config)
    let windows = (1...count).map { WindowInfo(id: WindowID($0), pid: Int32(100 + $0), display: "d") }
    _ = engine.handle(.started(saved: nil, windows: windows, displays: [display], focus: nil))
    return engine
}

@discardableResult
private func run(_ engine: inout Engine, _ text: String) -> Output {
    let output = engine.handle(.command(text.split(separator: " ").map(String.init)))
    #expect(output.reply?.ok == true, Comment(rawValue: output.reply?.text ?? "missing reply"))
    return output
}

private func picker(_ engine: Engine, _ window: WindowID = 1) -> DropPicker? {
    DropPicker(state: engine.savedState(), config: engine.config, window: window)
}

private func global(_ picker: DropPicker, _ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x + picker.frame.minX, y: point.y + picker.frame.minY)
}

private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

@Test(arguments: [(2, [Variant.standard, .alternate]), (3, [.standard, .mirrored, .alternate, .stacked]), (4, [.standard])])
func pickerOffersTheCountsLayoutsInARowAtTheBottomCentre(_ count: Int, _ variants: [Variant]) throws {
    let picker = try #require(picker(engine(count)))
    #expect(picker.options.map(\.variant) == variants)
    #expect(picker.options.map(\.current) == variants.map { $0 == .standard })
    #expect(picker.pid == 101)
    #expect(picker.display == "d")
    // The switcher's cell size, unscaled on this display, in the middle of the usable area.
    #expect(picker.metrics == .picker)
    #expect(GridMetrics.picker.scale == 2)
    #expect(GridMetrics.picker.cellArea == GridMetrics.switcher.cellArea)
    let cell = GridIndicatorGeometry.cellSize(area: display.visibleFrame, metrics: .picker)
    let margin = DropPicker.margin * GridMetrics.picker.scale
    for (index, option) in picker.options.enumerated() {
        #expect(option.frames.count == count)
        #expect(option.tiles.count == count)
        #expect(option.cell.size == cell)
        #expect(option.cell.minX == margin + CGFloat(index) * (cell.width + GridMetrics.picker.spacing))
        #expect(option.cell.minY == margin)
        for tile in option.tiles { #expect(option.cell.contains(center(tile))) }
    }
    #expect(picker.frame.width == picker.options.last!.cell.maxX + margin)
    #expect(picker.frame.height == cell.height + 2 * margin)
    #expect(abs(picker.frame.midX - display.visibleFrame.center.x) <= 0.5)
    #expect(abs(picker.frame.midY - display.visibleFrame.center.y) <= 0.5)
}

@Test func pickerScalesDownToFitASmallDisplay() throws {
    #expect(picker(engine(3))?.metrics == .picker)
    let small = DisplayInfo(id: "d", frame: Rect(x: 0, y: 0, width: 480, height: 330), visibleFrame: Rect(x: 0, y: 30, width: 480, height: 300),
                            isPrimary: true)
    var e = Engine(config: config)
    _ = e.handle(.started(saved: nil, windows: (1...3).map { WindowInfo(id: WindowID($0), pid: Int32(100 + $0), display: "d") },
                          displays: [small], focus: nil))
    let picker = try #require(picker(e))
    #expect(picker.metrics.scale < 1)
    #expect(picker.options.count == 4)
    #expect(picker.frame.minX >= small.visibleFrame.x + PanelStyle.inset)
    #expect(picker.frame.maxX <= small.visibleFrame.maxX - PanelStyle.inset)
    let last = try #require(picker.options.last)
    #expect(picker.frame.width == last.cell.maxX + DropPicker.margin * picker.metrics.scale)
    for option in picker.options {
        for (slot, tile) in option.tiles.enumerated() {
            #expect(picker.target(at: global(picker, center(tile))) == DropTarget(variant: option.variant, slot: slot))
        }
    }
}

@Test func pickerIsOnlyForActiveTilesOnPagesOfTwoToFour() {
    #expect(picker(engine(1)) == nil)
    var five = engine(5)
    #expect(picker(five, 5) == nil)
    #expect(picker(five, 4) != nil)
    #expect(picker(five, 42) == nil)
    var minimized = WindowInfo(id: 2, pid: 102, display: "d")
    minimized.minimized = true
    _ = five.handle(.windowUpdated(minimized))
    #expect(picker(five, 2) == nil)
    #expect(picker(five, 1)?.options.map(\.variant) == [.standard, .mirrored, .alternate, .stacked])
    _ = five.handle(.windowAppeared(WindowInfo(id: 95, pid: 195, tileable: false, display: "d")))
    #expect(picker(five, 95) == nil)
    run(&five, "window float 3 on")
    #expect(picker(five, 3) == nil)
    #expect(picker(five, 1)?.options.map(\.variant) == [.standard, .alternate])
    var unmanaged = display
    unmanaged.unmanagedReason = DisplayNeed.secondDesktop.reason
    _ = five.handle(.displaysChanged([unmanaged]))
    #expect(picker(five, 1) == nil)
}

@Test func hitTestingFindsTheTileUnderTheCursorAndNothingOutsideTheCells() throws {
    let picker = try #require(picker(engine(3)))
    for option in picker.options {
        for (slot, tile) in option.tiles.enumerated() {
            #expect(picker.target(at: global(picker, center(tile))) == DropTarget(variant: option.variant, slot: slot))
        }
    }
    let first = picker.options[0], second = picker.options[1]
    // The gap between the large tile and the pair, and the cell's rim, still pick the nearest tile.
    #expect(picker.target(at: global(picker, CGPoint(x: (first.tiles[0].maxX + first.tiles[1].minX) / 2, y: first.tiles[0].midY)))?.variant == .standard)
    #expect(picker.target(at: global(picker, CGPoint(x: first.cell.minX + 0.5, y: first.cell.midY))) == DropTarget(variant: .standard, slot: 0))
    let between = CGPoint(x: (first.cell.maxX + second.cell.minX) / 2, y: first.cell.midY)
    for point in [between, CGPoint(x: 2, y: 2), CGPoint(x: first.cell.midX, y: first.cell.maxY + 2)] {
        #expect(picker.target(at: global(picker, point)) == nil)
    }
    #expect(picker.target(at: CGPoint(x: picker.frame.maxX + 10, y: picker.frame.midY)) == nil)
    #expect(picker.target(at: CGPoint(x: 0, y: 0)) == nil)
}

@Test(arguments: [2, 3, 4])
func previewIsTheFrameWindowPlaceLaysOut(_ count: Int) throws {
    var base = engine(count)
    run(&base, "page ratio 0.6 0.7")
    let picker = try #require(picker(base, 2))
    for option in picker.options {
        for slot in option.frames.indices {
            let target = DropTarget(variant: option.variant, slot: slot)
            var placed = base
            run(&placed, target.command(2).joined(separator: " "))
            #expect(picker.preview(target) == placed.handle(.command(["state"])).scene.displays["d"]?.frames[2])
        }
    }
    #expect(picker.preview(DropTarget(variant: .standard, slot: count)) == nil)
    #expect(picker.preview(DropTarget(variant: .stacked, slot: 0)) == (count == 3 ? picker.options[3].frames[0] : nil))
}

@Test func pickerKeepsRatiosForTheLayoutACountUsesForAnUndefinedVariant() throws {
    var e = engine(3)
    run(&e, "page variant")
    _ = e.handle(.windowGone(3))
    run(&e, "page ratio 0.65")
    let picker = try #require(picker(e))
    #expect(picker.options.map(\.current) == [true, false])
    let target = DropTarget(variant: .standard, slot: 1)
    run(&e, target.command(1).joined(separator: " "))
    #expect(picker.preview(target) == e.handle(.command(["state"])).scene.displays["d"]?.frames[1])
}

@Test func pickerFollowsTheDraggedWindowToItsNewPage() throws {
    var e = engine(6)
    #expect(try #require(picker(e)).options.map(\.variant) == [.standard])
    run(&e, "window nudge 1 right")
    #expect(picker(e) == nil)
    run(&e, "window nudge 1 right")
    let moved = try #require(picker(e))
    #expect(moved.options.map(\.variant) == [.standard, .mirrored, .alternate, .stacked])
    #expect(moved.options[0].frames.count == 3)
}

@Test func dragIsAMoveWhenTheSizeHoldsAndThePositionLeavesTheTolerance() {
    let tile = Rect(x: 100, y: 50, width: 600, height: 400)
    func moved(_ dx: Double, _ dy: Double, _ dw: Double = 0, _ dh: Double = 0) -> Bool {
        DragMove.isMove(Rect(x: tile.x + dx, y: tile.y + dy, width: tile.width + dw, height: tile.height + dh), from: tile)
    }
    #expect(!moved(0, 0))
    #expect(!moved(3, -3))
    #expect(moved(4, 0))
    #expect(moved(0, -4))
    #expect(moved(200, 300, 3, -3))
    #expect(!moved(200, 300, 4, 0))
    #expect(!moved(200, 300, 0, -4))
    #expect(!moved(-30, 0, 30, 0))
}

@Test func dropRoutesToAPickerTileElsewhereOrNowhere() throws {
    let picker = try #require(picker(engine(2)))
    let tile = Rect(x: 6, y: 39, width: 745, height: 888)
    let moved = Rect(x: 400, y: 300, width: 745, height: 888)
    let resized = Rect(x: 6, y: 39, width: 800, height: 888)
    let over = global(picker, center(picker.options[1].tiles[1]))
    let hit = Point(x: over.x, y: over.y), away = Point(x: 700, y: 300)
    #expect(DropRoute.route(frame: moved, cursor: hit, picker: picker, tile: tile) == .place(DropTarget(variant: .alternate, slot: 1)))
    #expect(DropTarget(variant: .alternate, slot: 1).command(7) == ["window", "place", "7", "alternate", "1"])
    #expect(DropRoute.route(frame: moved, cursor: away, picker: picker, tile: tile) == .dragEnded(frame: moved, cursor: away))
    #expect(DropRoute.route(frame: resized, cursor: hit, picker: picker, tile: tile) == .dragEnded(frame: resized, cursor: hit))
    #expect(DropRoute.route(frame: moved, cursor: hit, picker: nil, tile: tile) == .dragEnded(frame: moved, cursor: hit))
    #expect(DropRoute.route(frame: moved, cursor: hit, picker: picker, tile: nil) == .dragEnded(frame: moved, cursor: hit))
    #expect(DropRoute.route(frame: nil, cursor: hit, picker: picker, tile: tile) == .ignore)
    #expect(DropRoute.route(frame: moved, cursor: nil, picker: picker, tile: tile) == .ignore)
}

@Test func pickerContentLeavesTilesEmptyExceptTheHoveredOne() throws {
    let picker = try #require(picker(engine(3)))
    let content = DropPickerContent(picker: picker, hovered: DropTarget(variant: .alternate, slot: 1))
    for option in picker.options {
        let miniature = content.miniature(option)
        #expect(miniature.tiles.compactMap(\.frame) == option.frames)
        #expect(miniature.slots.allSatisfy { $0.pid == 101 })
        #expect(miniature.slots.map(\.placeholder) == option.frames.indices.map { option.variant != .alternate || $0 != 1 })
        #expect(content.selected(option) == (option.variant == .alternate ? 1 : nil))
    }
    let idle = DropPickerContent(picker: picker, hovered: nil)
    #expect(picker.options.allSatisfy { idle.selected($0) == nil && idle.miniature($0).slots.allSatisfy(\.placeholder) })
}

@Test func cocoaFrameInvertsCGFrame() {
    let frame = CGRect(x: -200, y: 120, width: 640, height: 480)
    let cg = Geometry.cgFrame(frame, primaryHeight: 982)
    #expect(cg == Rect(x: -200, y: 382, width: 640, height: 480))
    #expect(Geometry.cocoaFrame(cg, primaryHeight: 982) == frame)
}
