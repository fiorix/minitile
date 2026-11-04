import AppKit
import MinitileCore
import Testing
@testable import minitile

@Test func paletteIsTheBrandsInSRGB() throws {
    #expect(PanelStyle.void == Paint(rgb: 0x05070c))
    #expect(PanelStyle.wire == Paint(rgb: 0x7d9cc9))
    #expect(PanelStyle.ink == Paint(rgb: 0xe8f0fc))
    #expect(PanelStyle.dim == Paint(rgb: 0x8e9cb4))
    #expect(PanelStyle.neon == Paint(rgb: 0x53e9ff))
    #expect(PanelStyle.neonCore == Paint(rgb: 0xdcfbff))
    let neon = PanelStyle.neon.opacity(0.4)
    #expect(neon.rgb == 0x53e9ff && neon.alpha == 0.4)
    let expected: [CGFloat] = [0x53, 0xe9, 0xff, 0.4 * 255].map { $0 / 255 }
    #expect([neon.red, neon.green, neon.blue, neon.alpha] == expected)
    let color = try #require(neon.color.usingColorSpace(.sRGB))
    let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    #expect(zip(components, expected).allSatisfy { abs($0 - $1) < 1e-6 })
}

@Test func panelsAreDarkTranslucentAndDrawnWithFineWire() {
    #expect(PanelStyle.tint == Paint(rgb: 0x05070c, alpha: 0.6))
    #expect(PanelStyle.border == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.28), width: 0.5))
    #expect(PanelStyle.page == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.45), width: 0.75))
    #expect(PanelStyle.emptyPage == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.2), width: 0.75))
    #expect(PanelStyle.tile == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.5), width: 0.5))
    #expect(PanelStyle.tileFill == Paint(rgb: 0x7d9cc9, alpha: 0.05))
    #expect(PanelStyle.highlightFill == Paint(rgb: 0x53e9ff, alpha: 0.12))
    #expect(PanelStyle.plate == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.5), width: 0.5))
    #expect(PanelStyle.plateFill == Paint(rgb: 0x05070c, alpha: 0.92))
    #expect(PanelStyle.iconOpacity == 0.7 && PanelStyle.reservedOpacity < PanelStyle.iconOpacity)
    #expect(PanelStyle.previewFill == Paint(rgb: 0x53e9ff, alpha: 0.08))
    #expect(PanelStyle.keyline == Stroke(paint: Paint(rgb: 0x05070c, alpha: 0.5), width: 1))
}

@Test @MainActor func onlyStateIsLitAndPanelsLeaveRoomForTheHalo() {
    let glow = Glow(paint: Paint(rgb: 0x53e9ff, alpha: 0.85), radii: [6, 2])
    #expect(PanelStyle.glow == glow && glow.reach == 6)
    let lit: [(Stroke, CGFloat)] = [(PanelStyle.shownPage, 1), (PanelStyle.highlight, 1), (PanelStyle.preview, 1.5), (PanelStyle.grab, 2)]
    for (stroke, width) in lit {
        #expect(stroke == Stroke(paint: Paint(rgb: 0xdcfbff), width: width, glow: glow) && stroke.reach == 6)
    }
    for stroke in [PanelStyle.border, PanelStyle.page, PanelStyle.emptyPage, PanelStyle.tile, PanelStyle.plate, PanelStyle.keyline] {
        #expect(stroke.glow == nil && stroke.reach == 0)
    }
    let target = NSRect(x: 100, y: 200, width: 640, height: 480)
    #expect(DropPreviewView.frame(around: target) == target.insetBy(dx: -6, dy: -6))
}

/// Draws into a transparent bitmap at twice the point size, as on a Retina display.
@MainActor private func render(_ size: NSSize, _ draw: () -> Void) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = size
    let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

@Test @MainActor func aLitLineGlowsWithinItsReachAndIsLitInBandsExactlyAsWhole() throws {
    let size = NSSize(width: 200, height: 140), rect = NSRect(x: 20, y: 20, width: 160, height: 100), radius: CGFloat = 12
    let stroke = PanelStyle.grab, glow = try #require(stroke.glow)
    #expect(glow.bands(around: rect, radius: radius, width: stroke.width).count == 4)
    #expect(glow.bands(around: NSRect(x: 0, y: 0, width: 40, height: 30), radius: radius, width: stroke.width).count == 1)
    let banded = try render(size) { stroke.draw(inside: rect, radius: radius) }
    let whole = try render(size) {
        let inset = stroke.width / 2
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
        path.lineWidth = stroke.width
        glow.light(path, core: stroke.paint)
    }
    let bytes = banded.bytesPerRow * banded.pixelsHigh
    let pixels = try [banded, whole].map { rep in
        let data = try #require(rep.bitmapData)
        return Array(UnsafeBufferPointer(start: data, count: bytes))
    }
    #expect(pixels[0] == pixels[1])
    func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        banded.colorAt(x: Int(x * 2), y: Int((size.height - y) * 2))?.alphaComponent ?? -1
    }
    // The core is opaque, the halo shows on both sides of it, at the corners too, and has faded out by its reach.
    #expect(alpha(rect.midX, rect.maxY - 1) == 1)
    #expect(alpha(rect.midX, rect.maxY + 1.5) > 0.1 && alpha(rect.midX, rect.maxY - stroke.width - 1) > 0.1)
    #expect(alpha(rect.minX + 2, rect.minY + 2) > 0.05)
    #expect(alpha(rect.midX, rect.maxY + stroke.reach + 1) == 0 && alpha(rect.minX - stroke.reach - 1, rect.midY) == 0)
    #expect(alpha(rect.midX, rect.midY) == 0)
}

@Test func labelsUseTheMonospacedSystemFont() {
    #expect(PanelStyle.font(size: 20, monospaced: true).fontDescriptor.symbolicTraits.contains(.monoSpace))
    #expect(!PanelStyle.font(size: 20).fontDescriptor.symbolicTraits.contains(.monoSpace))
    #expect(PanelStyle.font(size: 20, weight: .semibold).pointSize == 20)
}

@Test func indicatorAndSwitcherAreTwiceThePickersScale() {
    let indicator = GridMetrics(cellArea: 64 * 40, spacing: 6, labelGap: 2, minWidth: 220, icon: 10...14, reservedIcon: 10, trayIcon: nil)
    let switcher = GridMetrics(cellArea: 128 * 80, spacing: 12, labelGap: 12, minWidth: 300, icon: 16...32, reservedIcon: 14, trayIcon: 16)
    #expect(indicator.scaled(2) == .indicator)
    #expect(switcher.scaled(2) == .switcher)
    #expect(GridMetrics.picker.scale == 1 && GridMetrics.picker.cellArea == 128 * 80)
    #expect(GridMetrics.switcher.cellArea == 4 * GridMetrics.indicator.cellArea)
    let area = Rect(x: 0, y: 33, width: 1512, height: 945)
    #expect(GridIndicatorGeometry.cellSize(area: area, metrics: .indicator) == CGSize(width: 128, height: 80))
    #expect(GridIndicatorGeometry.cellSize(area: area, metrics: .switcher) == CGSize(width: 256, height: 160))
    #expect(GridIndicatorGeometry.cellSize(area: area, metrics: .picker) == CGSize(width: 128, height: 80))
    // Scaling down keeps icons on whole points and the cell area in proportion.
    let half = GridMetrics.switcher.scaled(0.47)
    #expect(half.scale == 2 * 0.47 && half.spacing == 24 * 0.47 && half.cellArea == 256 * 160 * 0.47 * 0.47)
    #expect(half.icon == 15...30 && half.reservedIcon == 13 && half.trayIcon == 15)
}

@Test func panelsScaleDownUniformlyToFitTheUsableArea() {
    let laptop = Rect(x: 0, y: 33, width: 1512, height: 945)
    let room = CGSize(width: laptop.width - 2 * PanelStyle.inset, height: laptop.height - 2 * PanelStyle.inset)
    // The indicator's 4 by 5 grid fits a laptop at full size.
    #expect(GridIndicatorGeometry(area: laptop, rows: 4, columns: 5, cropped: true, metrics: .indicator).metrics == .indicator)
    // The switcher's does not, so it shrinks just enough, keeping its cells in the display's proportions.
    let switcher = GridIndicatorGeometry(area: laptop, rows: 4, columns: 5, cropped: true, metrics: .switcher)
    #expect(switcher.metrics.scale < 2 && switcher.metrics.scale > 1.9)
    #expect(switcher.size.width <= room.width && switcher.size.height <= room.height)
    #expect(switcher.size.height > room.height - 4)
    #expect(abs(switcher.cell.width / switcher.cell.height - 1.6) < 0.02)
    // A smaller grid on the same display keeps its full size.
    #expect(GridIndicatorGeometry(area: laptop, rows: 2, columns: 3, cropped: false, metrics: .switcher).metrics == .switcher)
    for area in [Rect(x: 0, y: 0, width: 800, height: 500), Rect(x: 0, y: 0, width: 500, height: 900),
                 Rect(x: 0, y: 0, width: 3440, height: 400)] {
        let room = CGSize(width: area.width - 2 * PanelStyle.inset, height: area.height - 2 * PanelStyle.inset)
        for metrics in [GridMetrics.indicator, .switcher] {
            let geometry = GridIndicatorGeometry(area: area, rows: 4, columns: 5, cropped: true, metrics: metrics)
            #expect(geometry.metrics.scale < metrics.scale)
            #expect(geometry.size.width <= room.width && geometry.size.height <= room.height, "\(area) \(geometry.size)")
        }
    }
    // Without a usable area to measure, nothing is scaled.
    #expect(GridIndicatorGeometry(area: Rect(x: 0, y: 0, width: 0, height: 0), rows: 4, columns: 5, cropped: true,
                                  metrics: .switcher).metrics == .switcher)
    #expect(GridMetrics.switcher.fitted(to: CGSize(width: 10_000, height: 10_000)) { _ in CGSize(width: 100, height: 100) } == .switcher)
}

@Test func indicatorContentFitsItsDisplay() {
    let pages = Array(repeating: Array(repeating: GridMiniature(), count: 6), count: 5)
    var content = GridIndicatorContent(displayName: "Laptop", active: true, workspace: 3, page: 3,
                                       area: Rect(x: 0, y: 33, width: 1512, height: 945), pages: pages, warning: nil)
    #expect(GridIndicatorGeometry(content: content).metrics == .indicator)
    content.area = Rect(x: 0, y: 0, width: 640, height: 400)
    let small = GridIndicatorGeometry(content: content)
    #expect(small.metrics.scale < 1.4)
    #expect(small.size.width <= 640 - 2 * PanelStyle.inset && small.size.height <= 400 - 2 * PanelStyle.inset)
}
