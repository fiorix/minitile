import AppKit
import MinitileCore
import Testing
@testable import minitile

/// Exports review artifacts only when requested, without showing a window or touching the running app.
func saveRender(_ bitmap: NSBitmapImageRep, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["MINITILE_RENDER_DIR"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: directory.appendingPathComponent(name + ".png"))
}

@MainActor func renderBitmap(_ size: CGSize, draw: () -> Void) throws -> NSBitmapImageRep {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

@Test @MainActor func helpRendersItsRowsAndKeycapsInOneOrTwoColumns() throws {
    let content = HelpContent(config: .default)
    for (height, count) in [(913, 1), (500, 2)] {
        let layout = HelpLayout(content: content, bounds: CGSize(width: 1480, height: height))
        #expect(layout.columns.count == count)
        let view = HelpView(layout: layout)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try saveRender(bitmap, name: "help-\(count)-column")
        for (index, column) in layout.columns.enumerated() {
            var origin = layout.origin(column: index)
            for line in column {
                if case .entry(let entry) = line {
                    #expect(try draws(view, in: CGRect(x: origin.x, y: origin.y, width: HelpLayout.textWidth - 12, height: 24)), "\(entry.text)")
                    #expect(try draws(view, in: CGRect(x: origin.x + HelpLayout.textWidth, y: origin.y, width: HelpLayout.keyWidth, height: 26)), "\(entry.text)")
                    if entry.detail != nil {
                        #expect(try draws(view, in: CGRect(x: origin.x, y: origin.y + 23, width: HelpLayout.textWidth - 12, height: 32)))
                    }
                }
                origin.y += line.height
                #expect(origin.y <= layout.size.height - HelpLayout.margin)
            }
        }
    }
}

@Test @MainActor func longCustomHelpIsClippedToTheUsableArea() throws {
    var config = Config.default
    for number in 1...20 { config.bindings[Chord(modifiers: [.ctrl, .alt, .shift, .cmd], key: "f\(number)")] = ["workspace", "show", "\(number)"] }
    let content = HelpContent(config: config)
    let layout = HelpLayout(content: content, bounds: CGSize(width: 608, height: 368))
    let view = HelpView(layout: layout)
    view.setFrameSize(CGSize(width: min(608, layout.size.width), height: min(368, layout.size.height)))
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try saveRender(bitmap, name: "help-small-display")
    #expect(view.bounds.height == 368 && layout.size.height > view.bounds.height)
    #expect(layout.columns.count == 1)
    let full = HelpView(layout: HelpLayout(content: content, bounds: CGSize(width: 1800, height: 900)))
    let complete = try #require(full.bitmapImageRepForCachingDisplay(in: full.bounds))
    full.cacheDisplay(in: full.bounds, to: complete)
    try saveRender(complete, name: "help-custom-bindings")
    #expect(full.bounds.height <= 900)
}

@Test @MainActor func keycapsScaleTheirTextAndGeometry() throws {
    let small = PanelStyle.keycapSize("Control"), large = PanelStyle.keycapSize("Control", scale: 2)
    #expect(abs(large.width - small.width * 2) <= 1 && large.height == small.height * 2)
    let bitmap = try renderBitmap(CGSize(width: large.width + 8, height: large.height + 8)) {
        PanelStyle.keycap("Control", at: CGPoint(x: 4, y: 4), scale: 2)
    }
    try saveRender(bitmap, name: "keycap")
    #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
    #expect((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0)
}

@Test @MainActor func helpHeaderPutsTheMarkTitleAndLinkLeftAndTheSubtitleRight() throws {
    let view = HelpView(layout: HelpLayout(content: HelpContent(config: .default), bounds: CGSize(width: 1480, height: 913)))
    let header = HelpHeader(width: view.bounds.width)
    #expect(header.mark.maxX < header.title.minX && header.title.maxX < header.link.minX && header.link.maxX < header.subtitle.minX)
    #expect(header.subtitle.maxX == view.bounds.width - HelpLayout.margin)
    #expect(abs(header.mark.midY - header.title.midY) <= 2)
    for rect in [header.mark, header.title, header.subtitle, header.link] {
        #expect(rect.minY >= 0 && rect.maxY <= HelpLayout.margin + HelpLayout.titleHeight)
        #expect(try draws(view, in: rect))
    }
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try saveRender(bitmap, name: "help-header")
    // The wide top tile of the mark is lit neon.
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    let lit = try #require(bitmap.colorAt(x: Int((header.mark.minX + header.mark.width / 2) * scale),
                                          y: Int((header.mark.minY + header.mark.height * 13.5 / 40) * scale))?.usingColorSpace(.sRGB))
    #expect(lit.greenComponent > 0.8 && lit.blueComponent > 0.8 && lit.redComponent < 0.5)
    #expect(HelpHeader.website.absoluteString == "https://minitile.app")
}
