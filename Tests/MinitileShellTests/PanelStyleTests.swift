import AppKit
import MinitileCore
import Testing
@testable import minitile

@Test func paletteIsTheBrandsInSRGB() throws {
    #expect(PanelStyle.void == Paint(rgb: 0x05070c))
    #expect(PanelStyle.well == Paint(rgb: 0x04060b))
    #expect(PanelStyle.wire == Paint(rgb: 0x7d9cc9))
    #expect(PanelStyle.ink == Paint(rgb: 0xe8f0fc))
    #expect(PanelStyle.dim == Paint(rgb: 0x8e9cb4))
    #expect(PanelStyle.skyBloom == Paint(rgb: 0x2d5cff))
    #expect(PanelStyle.neon == Paint(rgb: 0x53e9ff))
    #expect(PanelStyle.neonCore == Paint(rgb: 0xdcfbff))
    #expect(PanelStyle.accent == Paint(rgb: 0xff5599))
    #expect(PanelStyle.accentCore == Paint(rgb: 0xffe4f0))
    #expect(PanelStyle.accentBloom == Paint(rgb: 0xc21868))
    let accent = PanelStyle.accent.opacity(0.4)
    #expect(accent.rgb == 0xff5599 && accent.alpha == 0.4)
    let expected: [CGFloat] = [0xff, 0x55, 0x99, 0.4 * 255].map { $0 / 255 }
    #expect([accent.red, accent.green, accent.blue, accent.alpha] == expected)
    let color = try #require(accent.color.usingColorSpace(.sRGB))
    let components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    #expect(zip(components, expected).allSatisfy { abs($0 - $1) < 1e-6 })
}

@Test func panelsAreDarkTranslucentAndDrawnWithFineWire() {
    #expect(PanelStyle.tint == Paint(rgb: 0x05070c, alpha: 0.68))
    #expect(PanelStyle.border == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.36), width: 0.75))
    #expect(PanelStyle.radius == 24 && PanelStyle.pageRadius == 7.5 && PanelStyle.tileRadius == 5)
    #expect(PanelStyle.page == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.48), width: 0.8))
    #expect(PanelStyle.emptyPage == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.22), width: 0.8))
    #expect(PanelStyle.tile == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.55), width: 0.75))
    #expect(PanelStyle.tileFill == Paint(rgb: 0x7d9cc9, alpha: 0.08))
    #expect(PanelStyle.highlightFill == Paint(rgb: 0xff5599, alpha: 0.20))
    #expect(PanelStyle.plate == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.52), width: 0.75))
    #expect(PanelStyle.plateFill == Paint(rgb: 0x05070c, alpha: 0.94))
    #expect(PanelStyle.iconOpacity == 0.75 && PanelStyle.reservedOpacity < PanelStyle.iconOpacity)
    #expect(PanelStyle.previewFill == Paint(rgb: 0xff5599, alpha: 0.08))
    #expect(PanelStyle.keyline == Stroke(paint: Paint(rgb: 0x05070c, alpha: 0.55), width: 1))
    #expect(PanelStyle.marker == Stroke(paint: Paint(rgb: 0x7d9cc9, alpha: 0.6), width: 1))
}

@Test @MainActor func onlyStateIsLitWithCyanContextAndPinkFocus() {
    let cyanGlow = Glow(paint: Paint(rgb: 0x53e9ff, alpha: 0.85), radii: [6, 2])
    let accentGlow = Glow(paint: Paint(rgb: 0xff5599, alpha: 0.88), radii: [6, 2])
    #expect(PanelStyle.glow == cyanGlow && cyanGlow.reach == 6)
    #expect(PanelStyle.accentGlow == accentGlow && accentGlow.reach == 6)
    #expect(PanelStyle.shownPage == Stroke(paint: Paint(rgb: 0xdcfbff), width: 1.1, glow: cyanGlow) && PanelStyle.shownPage.reach == 6)
    let focal: [(Stroke, CGFloat)] = [(PanelStyle.highlight, 1.2), (PanelStyle.preview, 1.5), (PanelStyle.grab, 2)]
    for (stroke, width) in focal {
        #expect(stroke == Stroke(paint: Paint(rgb: 0xffe4f0), width: width, glow: accentGlow) && stroke.reach == 6)
    }
    for stroke in [PanelStyle.border, PanelStyle.page, PanelStyle.emptyPage, PanelStyle.tile, PanelStyle.plate, PanelStyle.keyline,
                   PanelStyle.marker] {
        #expect(stroke.glow == nil && stroke.reach == 0)
    }
    let target = NSRect(x: 100, y: 200, width: 640, height: 480)
    let previewMargin = DropPreviewView.hugOffset + PanelStyle.preview.reach
    #expect(DropPreviewView.frame(around: target) == target.insetBy(dx: -previewMargin, dy: -previewMargin))
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

@Test @MainActor func aLitSquircleGlowsWithinItsReachAndIsLitInBandsExactlyAsWhole() throws {
    let size = NSSize(width: 220, height: 150), rect = NSRect(x: 20, y: 20, width: 180, height: 110), radius: CGFloat = 12
    let stroke = PanelStyle.grab, glow = try #require(stroke.glow)
    #expect(glow.bands(around: rect, radius: radius, width: stroke.width).count == 4)
    #expect(glow.bands(around: NSRect(x: 0, y: 0, width: 40, height: 30), radius: radius, width: stroke.width).count == 1)
    let banded = try render(size) { stroke.draw(inside: rect, radius: radius) }
    let whole = try render(size) {
        let inset = stroke.width / 2
        let path = Squircle.path(rect.insetBy(dx: inset, dy: inset), radius: radius - inset)
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
    // The core is opaque, the halo shows on both sides of it, at the continuous corners too, and fades out by its reach.
    #expect(alpha(rect.midX, rect.maxY - 1) == 1)
    #expect(alpha(rect.midX, rect.maxY + 1.5) > 0.1 && alpha(rect.midX, rect.maxY - stroke.width - 1) > 0.1)
    #expect(alpha(rect.minX + 3, rect.minY + 3) > 0.05)
    #expect(alpha(rect.midX, rect.maxY + stroke.reach + 1) == 0 && alpha(rect.minX - stroke.reach - 1, rect.midY) == 0)
    #expect(alpha(rect.midX, rect.midY) == 0)
}

@Test @MainActor func offscreenViewsRenderPinkFocalElementsAndConcentricHugs() throws {
    let preview = DropPreviewView(frame: NSRect(x: 0, y: 0, width: 280, height: 190))
    let previewRep = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
    preview.cacheDisplay(in: preview.bounds, to: previewRep)
    try saveRender(previewRep, name: "drop-preview-tunnel")
    let previewColors = try drawn(preview, in: NSRect(x: 4, y: 4, width: 44, height: 44)).compactMap { $0.usingColorSpace(.sRGB) }
    #expect(previewColors.contains { $0.redComponent > $0.blueComponent + 0.2 })

    let grab = GrabOutlineView(frame: NSRect(x: 0, y: 0, width: 280, height: 190))
    let grabRep = try #require(grab.bitmapImageRepForCachingDisplay(in: grab.bounds))
    grab.cacheDisplay(in: grab.bounds, to: grabRep)
    try saveRender(grabRep, name: "grab-corner-hugs")
    let grabColors = try drawn(grab, in: NSRect(x: 4, y: 4, width: 44, height: 44)).compactMap { $0.usingColorSpace(.sRGB) }
    #expect(grabColors.contains { $0.redComponent > $0.blueComponent + 0.2 })

    let notice = DesktopNoticeView(layout: DesktopNoticeLayout(name: "Studio Display"))
    let noticeRep = try #require(notice.bitmapImageRepForCachingDisplay(in: notice.bounds))
    notice.cacheDisplay(in: notice.bounds, to: noticeRep)
    try saveRender(noticeRep, name: "desktop-notice")
    let secondDesktop = notice.layout.desktops[1]
    let noticeColors = try drawn(notice, in: secondDesktop).compactMap { $0.usingColorSpace(.sRGB) }
    #expect(noticeColors.contains { $0.redComponent > $0.blueComponent + 0.2 })
}

@Test func labelsUseTheMonospacedSystemFont() {
    #expect(PanelStyle.font(size: 20, monospaced: true).fontDescriptor.symbolicTraits.contains(.monoSpace))
    #expect(!PanelStyle.font(size: 20).fontDescriptor.symbolicTraits.contains(.monoSpace))
    #expect(PanelStyle.font(size: 20, weight: .semibold).pointSize == 20)
}

@Test func panelsAreAtScaleTwo() {
    let indicator = GridMetrics(cellArea: 64 * 40, spacing: 6, labelGap: 2, minWidth: 220, icon: 10...14, reservedIcon: 10, trayIcon: nil)
    let switcher = GridMetrics(cellArea: 128 * 80, spacing: 12, labelGap: 12, minWidth: 300, icon: 16...32, reservedIcon: 14, trayIcon: 16,
                               shelfIcon: 20)
    #expect(indicator.scaled(2) == .indicator)
    #expect(switcher.scaled(2) == .switcher)
    #expect(GridMetrics.picker.scale == 2 && GridMetrics.picker.cellArea == 256 * 160)
    #expect(GridMetrics.switcher.cellArea == 4 * GridMetrics.indicator.cellArea)
    let area = Rect(x: 0, y: 33, width: 1512, height: 945)
    #expect(GridIndicatorGeometry.cellSize(area: area, metrics: .indicator) == CGSize(width: 128, height: 80))
    #expect(GridIndicatorGeometry.cellSize(area: area, metrics: .switcher) == CGSize(width: 256, height: 160))
    #expect(GridIndicatorGeometry.cellSize(area: area, metrics: .picker) == CGSize(width: 256, height: 160))
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
