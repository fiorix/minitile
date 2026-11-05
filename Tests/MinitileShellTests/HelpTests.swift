import CoreGraphics
import Foundation
import MinitileCore
import Testing
@testable import minitile

@Test func chordsUseNamedKeycapsInWebsiteOrder() {
    #expect(HelpKeys.caps(Chord(modifiers: [.cmd, .shift, .alt, .ctrl], key: "left")) == ["Control", "Option", "Shift", "Cmd", "Left"])
    #expect(HelpKeys.caps(Chord(modifiers: .cmd, key: "`")) == ["Cmd", "Backtick"])
    #expect(HelpKeys.caps(Chord(modifiers: [.shift, .cmd], key: "tab")) == ["Shift", "Cmd", "Tab"])
    #expect(["right", "up", "down", "return", "escape", "space", "h", "f12"].map(HelpKeys.key)
            == ["Right", "Up", "Down", "Return", "Esc", "Space", "H", "F12"])
}

@Test func defaultHelpFollowsTheWebsiteAndFoldsReverseShiftBindings() {
    let content = HelpContent(config: .default)
    #expect(content.sections.map(\.title) == ["", "Mouse and trackpad"])
    let rows = content.sections[0].entries
    #expect(rows.map(\.text) == ["Move around", "Move a window", "Resize a window", "Cycle layouts", "Find a window anywhere",
                                "Cycle windows on this page", "Swap a window with its neighbour", "Show every shortcut"])
    #expect(rows.map(\.keys) == [["Control", "Arrow keys"], ["Control", "Shift", "Arrow keys"], ["Control", "Option", "Arrow keys"],
                                ["Control", "Option", "Space"], ["Cmd", "Tab"], ["Cmd", "Backtick"], ["Option", "Cmd", "Backtick"],
                                ["Cmd", "H"]])
    #expect(rows[0].detail == nil && rows[1].detail == nil)
    #expect(rows[4].detail == "Hold Cmd, choose with Tab or arrows, then release to jump. Add Shift to go back.")
    #expect(rows[5].detail == "Add Shift to go back." && rows[6].detail == "Add Shift to go back.")
    #expect(rows[7].detail == "Press Esc or click anywhere else to close.")
}

@Test func differentlyReboundDirectionsAndMissingBindingsStayExplicit() throws {
    var config = Config.default
    config.bindings[Chord(modifiers: .ctrl, key: "left")] = nil
    config.bindings[Chord(modifiers: .alt, key: "h")] = ["page", "prev"]
    let rows = HelpContent(config: config).sections[0].entries
    #expect(rows[0].text == "Move around (left)" && rows[0].keys == ["Option", "H"])
    #expect(rows[1].text == "Move around (right)" && rows[1].keys == ["Control", "Right"])
    #expect(rows[2].text == "Move around (up / down)" && rows[2].keys == ["Control", "Up / Down"])
    let unbound = HelpContent(config: try Config.parse("[bindings]\n\"cmd+h\" = \"\"\n\"ctrl+left\" = \"window close\"\n"))
    #expect(!unbound.sections.flatMap(\.entries).contains { $0.text == "Show every shortcut" })
    #expect(unbound.sections[0].entries[0].text == "Move around (right)")
    #expect(unbound.sections.first { $0.title == "Other" }?.entries == [HelpContent.Entry(keys: ["Control", "Left"], text: "window close")])
}

@Test func aliasesAndMultipleBindingsKeepTheirActualKeys() {
    let config = Config(bindings: [
        Chord(modifiers: .alt, key: "h"): ["window", "move", "left"],
        Chord(modifiers: .alt, key: "l"): ["window", "nudge", "right"],
        Chord(modifiers: .ctrl, key: "left"): ["window", "nudge", "left"],
        Chord(modifiers: .ctrl, key: "right"): ["window", "move", "right"],
        Chord(modifiers: .ctrl, key: "up"): ["window", "resize", "up"],
        Chord(modifiers: .ctrl, key: "down"): ["window", "resize", "down"],
    ])
    let rows = HelpContent(config: config).sections[0].entries
    #expect(rows.map(\.keys) == [["Option", "H / L"], ["Control", "Left / Right"], ["Control", "Up / Down"]])
    #expect(rows.map(\.text) == ["Move a window (left / right)", "Move a window (left / right)", "Resize a window (up / down)"])
}

@Test func onlyAnExactReverseShiftVariantBecomesADetail() {
    let config = Config(bindings: [
        Chord(modifiers: .alt, key: "a"): ["switcher", "next"],
        Chord(modifiers: [.alt, .shift], key: "a"): ["switcher", "prev"],
        Chord(modifiers: .cmd, key: "tab"): ["switcher", "prev"],
        Chord(modifiers: [.cmd, .shift], key: "`"): ["window", "focus", "prev"],
        Chord(key: "f5"): ["window", "float"],
        Chord(key: "f6"): ["debug", "spaces"],
        Chord(key: "f7"): ["window", "focus", "42"],
        Chord(key: "f8"): ["ignore"],
    ])
    let content = HelpContent(config: config)
    #expect(content.sections.map(\.title) == ["", "Other", "Mouse and trackpad"])
    #expect(content.sections[0].entries[0].keys == ["Option", "A"])
    #expect(content.sections[0].entries[0].detail?.hasSuffix("Add Shift to go back.") == true)
    #expect(content.sections[1].entries.map(\.text) == ["Focus previous window", "Toggle floating", "Window switcher, backwards",
                                                     "debug spaces", "window focus 42"])
    #expect(content.sections[1].entries.map(\.keys) == [["Shift", "Cmd", "Backtick"], ["F5"], ["Cmd", "Tab"], ["F6"], ["F7"]])
}

@Test func swipesAreListedOnlyWhileMinitileTakesThem() {
    let on = HelpContent.gestures(swipes: true), off = HelpContent.gestures(swipes: false)
    #expect(on.count == 5 && off.count == 4)
    #expect(on.first == HelpContent.Entry(keys: ["Swipe in any direction"], text: "Move around", chord: false))
    #expect(Array(on.dropFirst()) == off)
    #expect(off.last?.keys == ["Drag, then Control + arrows"])
    #expect(on.allSatisfy { !$0.chord })
    var config = Config(bindings: [:])
    config.trackpadSwipes = false
    #expect(HelpContent(config: config).sections == [HelpContent.Section(title: "Mouse and trackpad", entries: off)])
}

@Test func helpFitsOneColumnWhenTheUsableAreaIsTallEnough() {
    let layout = HelpLayout(content: HelpContent(config: .default), bounds: CGSize(width: 1480, height: 913))
    #expect(layout.columns.count == 1)
    #expect(layout.size == CGSize(width: 592, height: 654))
    #expect(layout.origin(column: 0) == CGPoint(x: 16, y: 46))
}

@Test func helpBalancesColumnsWithoutLosingRows() {
    let content = HelpContent(config: .default)
    let layout = HelpLayout(content: content, bounds: CGSize(width: 1480, height: 500))
    #expect(layout.columns.count == 2)
    #expect(layout.size.width == 1176 && layout.size.height <= 500)
    #expect(layout.origin(column: 1) == CGPoint(x: 600, y: 46))
    #expect(layout.columns.flatMap { $0 } == HelpLayout.pack(content.sections, limit: .infinity)[0])
    #expect(HelpLayout(content: content, bounds: CGSize(width: 500, height: 500)).columns.count == 1)
    for column in layout.columns {
        if case .header = column.last { Issue.record("A heading has no row") }
    }
}

@Test func tallSectionsSplitAndHeadingsKeepTheirFirstRow() {
    let rows = (1...10).map { HelpContent.Entry(keys: ["K\($0)"], text: "T\($0)") }
    let split = HelpLayout.pack([HelpContent.Section(title: "A", entries: rows)], limit: 100)
    #expect(split[0] == [.header("A"), .entry(rows[0]), .entry(rows[1])])
    #expect(split.flatMap { $0 } == [.header("A")] + rows.map { .entry($0) })
    let detailed = HelpContent.Entry(keys: ["H"], text: "Help", detail: "Some detail")
    let moved = HelpLayout.pack([HelpContent.Section(title: "", entries: [rows[0]]),
                                HelpContent.Section(title: "B", entries: [detailed])], limit: 100)
    #expect(moved == [[.entry(rows[0])], [.header("B"), .entry(detailed)]])
}

// MARK: - Key routing

private let names: [UInt16: String] = [4: "h", 12: "q", 48: "tab", 53: "escape", 123: "left", 124: "right", 36: "return", 96: "f5"]
private let h: UInt16 = 4, q: UInt16 = 12, tab: UInt16 = 48, escape: UInt16 = 53, left: UInt16 = 123, f5: UInt16 = 96

private func makeRouter(_ bindings: [Chord: [String]] = Config.defaultBindings) -> KeyRouter {
    var router = KeyRouter(bindings: bindings, names: names)
    router.switcherAvailable = true
    router.helpAvailable = true
    return router
}

@Test func cmdHTogglesHelpAndItsRepeatsDoNotToggleItAgain() {
    var router = makeRouter()
    #expect(router.flags(.cmd) == .pass)
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open, session: 1))
    #expect(router.help == KeyRouter.OpenModal(kind: .help, session: 1, held: []))
    for _ in 0..<3 { #expect(router.key(h, modifiers: .cmd, down: true, autorepeat: true) == .swallow) }
    #expect(router.help?.session == 1)
    #expect(router.key(h, modifiers: .cmd, down: false) == .swallow)
    #expect(router.flags([.cmd, .shift]) == .pass)
    #expect(router.flags(.cmd) == .pass)
    #expect(router.help?.session == 1)
    #expect(router.flags([]) == .pass)
    #expect(router.help?.session == 1)
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.close, session: 1))
    #expect(router.key(h, modifiers: .cmd, down: true, autorepeat: true) == .swallow)
    #expect(router.key(h, modifiers: [], down: false) == .swallow)
    #expect(router.help == nil)
    #expect(router.flags([]) == .pass)
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open, session: 2))
    #expect(router.flags(.shift) == .pass)
    #expect(router.key(h, modifiers: .shift, down: false) == .swallow)
    #expect(router.key(h, modifiers: [], down: true) == .pass)
}

@Test func reboundHelpTogglesWithOrWithoutModifiers() {
    var router = makeRouter([Chord(modifiers: [.ctrl, .shift], key: "h"): ["help", "show"], Chord(key: "f5"): ["help", "show"]])
    #expect(router.key(h, modifiers: [.ctrl, .shift], down: true) == .help(.open, session: 1))
    #expect(router.key(h, modifiers: [.ctrl, .shift], down: false) == .swallow)
    #expect(router.flags(.ctrl) == .pass)
    #expect(router.key(h, modifiers: [.ctrl, .shift], down: true) == .help(.close, session: 1))
    #expect(router.key(h, modifiers: [.ctrl, .shift], down: false) == .swallow)
    #expect(router.key(f5, modifiers: [], down: true) == .help(.open, session: 2))
    #expect(router.flags([]) == .pass)
    #expect(router.key(f5, modifiers: [], down: false) == .swallow)
    #expect(router.key(escape, modifiers: [], down: true) == .help(.close, session: 2))
    #expect(router.key(escape, modifiers: [], down: false) == .swallow)
    // A repeat whose press the tap did not see opens nothing.
    var fresh = makeRouter()
    #expect(fresh.key(h, modifiers: .cmd, down: true, autorepeat: true) == .swallow)
    #expect(fresh.help == nil)
}

@Test func escClosesHelpWhileOtherKeysAndBindingsKeepTheirMeaning() {
    var router = makeRouter()
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open, session: 1))
    let keys: [(UInt16, Modifiers)] = [(q, .cmd), (tab, []), (left, [])]
    for (code, modifiers) in keys {
        #expect(router.key(code, modifiers: modifiers, down: true) == .pass)
        #expect(router.key(code, modifiers: modifiers, down: true, autorepeat: true) == .pass)
        #expect(router.key(code, modifiers: modifiers, down: false) == .pass)
    }
    #expect(router.key(left, modifiers: .ctrl, down: true) == .command(["page", "prev"]))
    #expect(router.key(left, modifiers: .ctrl, down: false) == .swallow)
    #expect(router.key(h, modifiers: [.cmd, .alt], down: true) == .command(["ignore"]))
    #expect(router.key(h, modifiers: [.cmd, .alt], down: false) == .swallow)
    #expect(router.help?.session == 1)
    #expect(router.key(escape, modifiers: .cmd, down: true) == .help(.close, session: 1))
    #expect(router.help == nil)
    #expect(router.key(escape, modifiers: .cmd, down: true, autorepeat: true) == .swallow)
    #expect(router.key(escape, modifiers: .cmd, down: false) == .swallow)
    #expect(router.flags([]) == .pass)
    #expect(router.key(escape, modifiers: [], down: true) == .pass)
    #expect(router.key(q, modifiers: .cmd, down: true) == .pass)
    #expect(router.key(left, modifiers: .ctrl, down: true) == .command(["page", "prev"]))
}

@Test func ignoreBindingSwallowsItsChordLikeAnyOtherBinding() {
    var router = makeRouter()
    #expect(router.key(h, modifiers: [.cmd, .alt], down: true) == .command(["ignore"]))
    #expect(router.key(h, modifiers: [.cmd, .alt], down: true, autorepeat: true) == .swallow)
    #expect(router.key(h, modifiers: [.cmd, .alt], down: false) == .swallow)
    #expect(router.key(h, modifiers: .alt, down: true) == .pass)
    #expect(router.help == nil)
}

@Test func cmdHPassesToMacOSWhenHelpIsUnavailableOrUnbound() {
    var router = makeRouter()
    router.helpAvailable = false
    #expect(router.key(h, modifiers: .cmd, down: true) == .pass)
    #expect(router.key(h, modifiers: .cmd, down: true, autorepeat: true) == .pass)
    #expect(router.key(h, modifiers: .cmd, down: false) == .pass)
    router.helpAvailable = true
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open, session: 1))
    // Losing the switcher's availability leaves the help screen open; losing help's closes it.
    router.switcherAvailable = false
    #expect(router.help?.session == 1)
    router.helpAvailable = false
    #expect(router.help == nil)
    #expect(router.key(h, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(q, modifiers: .cmd, down: true) == .pass)
    #expect(router.flags([]) == .pass)
    var bindings = Config.defaultBindings
    bindings[Chord(modifiers: .cmd, key: "h")] = nil
    var unbound = makeRouter(bindings)
    #expect(unbound.key(h, modifiers: .cmd, down: true) == .pass)
}

@Test func helpAndTheSwitcherReplaceEachOther() {
    var router = makeRouter()
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open, session: 1))
    #expect(router.key(h, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 2))
    #expect(router.help == nil)
    #expect(router.switcher?.session == 2)
    #expect(router.key(tab, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open, session: 3))
    #expect(router.switcher == nil)
    #expect(router.key(h, modifiers: .cmd, down: false) == .swallow)
    // The switcher's keys and modifier release leave help alone.
    #expect(router.key(left, modifiers: .cmd, down: true) == .pass)
    #expect(router.flags([]) == .pass)
    #expect(router.flags([]) == .pass)
    // Losing help's availability leaves an open switcher alone.
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 4))
    router.helpAvailable = false
    #expect(router.switcher?.session == 4)
}

@Test func mainThreadHelpSessionsStayOpenUntilClosed() {
    var router = makeRouter()
    #expect(router.open(.help) == 1)
    #expect(router.help == KeyRouter.OpenModal(kind: .help, session: 1, held: []))
    #expect(router.flags([]) == .pass)
    #expect(router.key(q, modifiers: .cmd, down: true) == .pass)
    #expect(router.key(escape, modifiers: [], down: true) == .help(.close, session: 1))
    let opened = router.open(.help)
    // Cmd+H also closes a screen opened through `mntl`.
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.close, session: 2))
    #expect(router.help == nil)
    #expect(router.open(.help) == 3)
    router.close(opened)
    #expect(router.help?.session == 3)
    router.close(3)
    #expect(router.help == nil)
    _ = router.open(.help)
    #expect(router.open(.switcher) == 5)
    #expect(router.help == nil)
    #expect(router.switcher?.session == 5)
}

// MARK: - Screen

@MainActor
private final class FakePresenter: HelpPresenting {
    var shown: [DisplayID?] = []
    var hides = 0
    func show(_ content: HelpContent, display: DisplayID?) { shown.append(display) }
    func hide() { hides += 1 }
}

private let content = HelpContent(config: .default)

@Test @MainActor func helpStaysOpenAndRepeatedShowsKeepItsContent() {
    let presenter = FakePresenter()
    let visible = HelpScreen(presenter: presenter)
    visible.open(session: 1, content: content, display: "d")
    visible.open(session: 2, content: content, display: nil)
    #expect(visible.isOpen && visible.session == 2)
    #expect(presenter.shown == ["d"])
    #expect(presenter.hides == 0)
    visible.close(1)
    #expect(visible.isOpen)
    visible.close(2)
    #expect(!visible.isOpen)
    #expect(presenter.hides == 1)
    visible.close(2)
    #expect(presenter.hides == 1)
    #expect(visible.isStale(2) && !visible.isStale(3))
}

@Test @MainActor func theSwitcherSupersedesHelp() {
    let presenter = FakePresenter()
    let visible = HelpScreen(presenter: presenter)
    visible.open(session: 1, content: content, display: "d")
    visible.supersede(4)
    #expect(!visible.isOpen)
    #expect(presenter.hides == 1)
    #expect(visible.isStale(4) && !visible.isStale(5))
    visible.supersede(2)
    #expect(visible.isStale(4))
    #expect(presenter.hides == 1)
}

@Test func helpLeavesRepeatingResizeAndItsGrabUsable() {
    var router = makeRouter()
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open, session: 1))
    #expect(router.key(h, modifiers: [], down: false) == .swallow)
    #expect(router.key(left, modifiers: [.ctrl, .alt], down: true) == .command(["window", "resize", "left"], grab: 1))
    #expect(router.key(left, modifiers: [.ctrl, .alt], down: true, autorepeat: true) == .command(["window", "resize", "left"], grab: 1))
    #expect(router.grabFlags([]) == .grabReleased(1))
    #expect(router.flags([]) == .pass && router.help?.session == 1)
    #expect(router.key(left, modifiers: [], down: false) == .swallow)
    // With nothing to offer, the switcher binding leaves help open and reaches macOS.
    router.switcherAvailable = false
    #expect(router.key(tab, modifiers: .cmd, down: true) == .pass)
    #expect(router.key(tab, modifiers: .cmd, down: false) == .pass)
    #expect(router.help?.session == 1)
    router.frontmostManaged = false
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.close, session: 1))
}
