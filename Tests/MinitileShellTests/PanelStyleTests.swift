import AppKit
import MinitileCore
import Testing
@testable import minitile

@Test func paletteIsTheBrandsInSRGB() throws {
    #expect(PanelStyle.background == Paint(rgb: 0x0b0d10))
    #expect(PanelStyle.rule == Paint(rgb: 0x292f39))
    #expect(PanelStyle.ice == Paint(rgb: 0xc8ddf8))
    #expect(PanelStyle.steel == Paint(rgb: 0x7489a5))
    #expect(PanelStyle.text == Paint(rgb: 0xeef0f4))
    #expect(PanelStyle.secondary == Paint(rgb: 0x9da6b3))
    let ice = PanelStyle.ice.opacity(0.4)
    #expect(ice.rgb == 0xc8ddf8 && ice.alpha == 0.4)
    let expected: [CGFloat] = [200, 221, 248, 0.4 * 255].map { $0 / 255 }
    #expect([ice.red, ice.green, ice.blue, ice.alpha] == expected)
    let color = try #require(ice.color.usingColorSpace(.sRGB))
    let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    #expect(zip(components, expected).allSatisfy { abs($0 - $1) < 1e-6 })
}

@Test func panelsAreDarkTranslucentAndDrawnWithHairlines() {
    #expect(PanelStyle.tint == Paint(rgb: 0x0b0d10, alpha: 0.8))
    #expect(PanelStyle.border == Stroke(paint: Paint(rgb: 0x292f39), width: 1))
    #expect(PanelStyle.page == Stroke(paint: Paint(rgb: 0x7489a5, alpha: 0.4), width: 1))
    #expect(PanelStyle.emptyPage.paint.alpha < PanelStyle.page.paint.alpha)
    #expect(PanelStyle.shownPage == Stroke(paint: Paint(rgb: 0xc8ddf8, alpha: 0.95), width: 1.5))
    #expect(PanelStyle.tile == Stroke(paint: Paint(rgb: 0x7489a5, alpha: 0.5), width: 0.7))
    #expect(PanelStyle.tileFill == Paint(rgb: 0xc8ddf8, alpha: 0.03))
    #expect(PanelStyle.highlight == Stroke(paint: Paint(rgb: 0xc8ddf8, alpha: 0.95), width: 1.5))
    #expect(PanelStyle.highlightFill.rgb == 0xc8ddf8 && PanelStyle.highlightFill.alpha > PanelStyle.tileFill.alpha)
    #expect(PanelStyle.iconOpacity == 0.7 && PanelStyle.reservedOpacity < PanelStyle.iconOpacity)
    #expect(PanelStyle.preview == Stroke(paint: Paint(rgb: 0xc8ddf8, alpha: 0.95), width: 1.5))
    #expect(PanelStyle.previewFill.rgb == 0xc8ddf8 && PanelStyle.previewFill.alpha < PanelStyle.highlightFill.alpha)
    #expect(PanelStyle.grab.rgb == 0xc8ddf8)
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
