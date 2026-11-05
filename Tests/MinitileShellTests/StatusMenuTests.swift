import AppKit
import Testing
@testable import minitile

@Test @MainActor func statusMarksAreTemplatesAndWidenForLongLabels() throws {
    let labels: [String?] = [nil, "1:1", "2:3", "12:10"]
    var widths: [CGFloat] = []
    var bitmaps: [NSBitmapImageRep] = []
    for label in labels {
        let image = StatusMark.image(label: label)
        #expect(image.isTemplate)
        #expect(image.size.height == 16)
        widths.append(image.size.width)
        let bitmap = try renderBitmap(image.size) { image.draw(in: CGRect(origin: .zero, size: image.size)) }
        bitmaps.append(bitmap)
        try saveRender(bitmap, name: "menu-\(label?.replacingOccurrences(of: ":", with: "-") ?? "none")")
        let alphas = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x in bitmap.colorAt(x: x, y: y)?.alphaComponent }
        }
        #expect(alphas.contains { $0 > 0.5 } && alphas.contains(0))
    }
    #expect(widths[0] == 16)
    #expect(widths[1] == widths[2] && widths[1] >= widths[0])
    #expect(widths[3] > widths[2])
    let bare = bitmaps[0], labelled = bitmaps[1], offset = Int(widths[1] - widths[0])
    let cleared = (0..<bare.pixelsHigh).flatMap { y in
        (0..<bare.pixelsWide).filter { x in
            (bare.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
                && (labelled.colorAt(x: x + offset, y: y)?.alphaComponent ?? 1) < 0.1
        }
    }
    #expect(!cleared.isEmpty, "The label must knock out the mark around its glyphs")
}

@Test @MainActor func statusMenuKeepsWarningsAndOnlyHelpAndQuitCommands() throws {
    let menu = StatusMenu.menu(warnings: StatusWarnings(["Config: invalid"], advice: []), state: "Starting")
    #expect(menu.items.map(\.title) == ["Starting", "Config: invalid", "", "Help", "Quit Minitile"])
    #expect(!menu.items[0].isEnabled && !menu.items[1].isEnabled && menu.items[2].isSeparatorItem)
    let help = try #require(menu.item(withTitle: "Help"))
    #expect(help.keyEquivalent == "h" && help.keyEquivalentModifierMask == .command)
    #expect(help.representedObject as? [String] == ["help", "show"])
    #expect(menu.item(withTitle: "Quit Minitile")?.representedObject as? [String] == ["quit"])
    let advice = SetupAdvice.secondDesktop(name: "Studio")
    let setup = StatusMenu.menu(warnings: StatusWarnings([], advice: [advice]), state: "Starting")
    #expect(setup.items[1].title == advice.title && setup.items[1].subtitle == advice.detail)
    #expect(setup.items[2].representedObject as? URL == SetupFix.missionControl.url)
    #expect(setup.items[3].isSeparatorItem)
}
