import CoreGraphics
import Foundation
import MinitileCore
import Testing
@testable import minitile

private let ctrl = "\u{2303}", option = "\u{2325}", shift = "\u{21E7}", command = "\u{2318}"
private let leftArrow = "\u{2190}", rightArrow = "\u{2192}", upArrow = "\u{2191}", downArrow = "\u{2193}"

private func entry(_ keys: String, _ text: String) -> HelpContent.Entry { HelpContent.Entry(keys: keys, text: text) }

@Test func chordsRenderAsMacOSMenusShowThem() {
    #expect(HelpKeys.text(Chord(modifiers: [.cmd, .shift, .alt, .ctrl], key: "left")) == ctrl + option + shift + command + leftArrow)
    #expect(HelpKeys.text(Chord(modifiers: .cmd, key: "`")) == command + "`")
    #expect(HelpKeys.text(Chord(modifiers: [.shift, .cmd], key: "tab")) == shift + command + "Tab")
    #expect(HelpKeys.text(Chord(modifiers: [.ctrl, .shift], key: "space")) == ctrl + shift + "Space")
    #expect(HelpKeys.text(Chord(modifiers: .cmd, key: "h")) == command + "H")
    #expect(HelpKeys.text(Chord(key: "f12")) == "F12")
    #expect(HelpKeys.text(Chord(modifiers: .alt, key: "1")) == option + "1")
    #expect(["right", "up", "down", "return", "escape"].map(HelpKeys.key) == [rightArrow, upArrow, downArrow, "Return", "Esc"])
}

@Test func defaultBindingsAreGroupedByWhatTheyDo() {
    let content = HelpContent(config: .default)
    #expect(content.sections.map(\.title) == ["Pages and workspaces", "Windows", "Layout", "Switcher", "Help", "Other", "Mouse and trackpad"])
    #expect(content.sections[0].entries == [entry(ctrl + leftArrow, "Previous page"), entry(ctrl + rightArrow, "Next page"),
                                            entry(ctrl + upArrow, "Workspace above"), entry(ctrl + downArrow, "Workspace below")])
    #expect(content.sections[1].entries == [
        entry(command + "`", "Focus next window"), entry(shift + command + "`", "Focus previous window"),
        entry(ctrl + shift + leftArrow, "Nudge window left"), entry(ctrl + shift + rightArrow, "Nudge window right"),
        entry(ctrl + shift + upArrow, "Carry to workspace above"), entry(ctrl + shift + downArrow, "Carry to workspace below"),
        entry(option + command + "`", "Swap with next slot"), entry(option + shift + command + "`", "Swap with previous slot"),
    ])
    #expect(content.sections[2].entries == [
        entry(ctrl + shift + "Space", "Cycle page layout"), entry(ctrl + option + leftArrow, "Resize window left"),
        entry(ctrl + option + rightArrow, "Resize window right"), entry(ctrl + option + upArrow, "Resize window up"),
        entry(ctrl + option + downArrow, "Resize window down"),
    ])
    #expect(content.sections[3].entries == [entry(command + "Tab", "Window switcher"), entry(shift + command + "Tab", "Window switcher, backwards")])
    #expect(content.sections[4].entries == [entry(command + "H", "Show this help")])
    #expect(content.sections[5].entries == [entry(option + command + "H", "Blocked")])
    #expect(content.sections[6].entries == HelpContent.gestures(swipes: true))
    // Every default binding is a known command.
    #expect(content.sections.dropLast().flatMap(\.entries).count == Config.defaultBindings.count)
}

@Test func reboundAndUnknownCommandsFollowTheMergedConfig() throws {
    var config = Config(bindings: [
        Chord(modifiers: .ctrl, key: "right"): ["page", "next"],
        Chord(modifiers: .ctrl, key: "return"): ["page", "next"],
        Chord(modifiers: .alt, key: "a"): ["debug", "spaces"],
        Chord(modifiers: .cmd, key: "1"): ["workspace", "show", "1"],
        Chord(modifiers: .alt, key: "b"): ["ignore"],
        Chord(modifiers: [.cmd, .alt], key: "h"): ["ignore"],
        Chord(modifiers: [.ctrl, .alt, .shift, .cmd], key: "f12"): ["window", "float"],
    ])
    config.trackpadSwipes = false
    let content = HelpContent(config: config)
    #expect(content.sections.map(\.title) == ["Pages and workspaces", "Windows", "Other", "Mouse and trackpad"])
    // A command's chords follow each other by name: ctrl+return before ctrl+right.
    #expect(content.sections[0].entries == [entry(ctrl + "Return", "Next page"), entry(ctrl + rightArrow, "Next page")])
    #expect(content.sections[1].entries == [entry(ctrl + option + shift + command + "F12", "Toggle floating")])
    // Known commands come first, then unknown ones by their command text, which they show.
    #expect(content.sections[2].entries == [entry(option + "B", "Blocked"), entry(option + command + "H", "Blocked"),
                                            entry(option + "A", "debug spaces"), entry(command + "1", "workspace show 1")])
    #expect(content.sections[3].entries == HelpContent.gestures(swipes: false))
    // Unbinding a chord in the config file takes it off the screen.
    let unbound = HelpContent(config: try Config.parse("[bindings]\n\"cmd+h\" = \"\"\n\"ctrl+left\" = \"window close\"\n"))
    #expect(!unbound.sections.contains { $0.title == "Help" })
    #expect(unbound.sections.first { $0.title == "Other" }?.entries == [entry(option + command + "H", "Blocked"),
                                                                        entry(ctrl + leftArrow, "window close")])
}

@Test func swipesAreListedOnlyWhileMinitileTakesThem() {
    let on = HelpContent.gestures(swipes: true), off = HelpContent.gestures(swipes: false)
    #expect(on.count == 6)
    #expect(on.prefix(2).map(\.keys) == ["Swipe left or right", "Swipe up or down"])
    #expect(Array(on.dropFirst(2)) == off)
    #expect(off.map(\.keys) == ["Drag an edge or corner", "Drag onto a tile", "Drop on the picker", "Drag, then " + ctrl + " arrows"])
}

@Test func helpFitsOneColumnWhenTheUsableAreaIsTallEnough() {
    let layout = HelpLayout(content: HelpContent(config: .default), bounds: CGSize(width: 1480, height: 913))
    #expect(layout.columns.count == 1)
    // 7 headers and 27 rows.
    #expect(layout.size == CGSize(width: 2 * 16 + 320, height: 2 * 16 + 26 + 7 * 26 + 27 * 18))
    #expect(layout.origin(column: 0) == CGPoint(x: 16, y: 42))
}

@Test func helpBalancesColumnsWhenItIsTooTall() {
    let content = HelpContent(config: .default)
    let layout = HelpLayout(content: content, bounds: CGSize(width: 1480, height: 500))
    func headers(_ column: [HelpLayout.Line]) -> [String] {
        column.compactMap { if case .header(let title) = $0 { title } else { nil } }
    }
    #expect(layout.columns.map(headers) == [["Pages and workspaces", "Windows", "Layout"],
                                            ["Switcher", "Help", "Other", "Mouse and trackpad"]])
    #expect(layout.size == CGSize(width: 2 * 16 + 2 * 320 + 24, height: 2 * 16 + 26 + 3 * 26 + 17 * 18))
    #expect(layout.origin(column: 1) == CGPoint(x: 16 + 320 + 24, y: 42))
    #expect(layout.columns.flatMap { $0 } == HelpLayout.pack(content.sections, limit: .infinity)[0])
    // Too narrow for a second column, it stays in one and overflows.
    #expect(HelpLayout(content: content, bounds: CGSize(width: 500, height: 500)).columns.count == 1)
}

@Test func tallSectionsSplitBetweenRowsAndHeadersKeepARow() {
    let rows = (1...10).map { entry("K\($0)", "T\($0)") }
    let split = HelpLayout.pack([HelpContent.Section(title: "A", entries: rows)], limit: 100)
    #expect(split == [[.header("A")] + rows.prefix(4).map { .entry($0) }, rows[4..<9].map { .entry($0) }, [.entry(rows[9])]])
    let moved = HelpLayout.pack([HelpContent.Section(title: "A", entries: [rows[0]]), HelpContent.Section(title: "B", entries: rows)], limit: 80)
    #expect(moved[0] == [.header("A"), .entry(rows[0])])
    #expect(moved[1].first == .header("B"))
    #expect(moved.allSatisfy { HelpLayout.height($0) <= 80 })
}
