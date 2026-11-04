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
