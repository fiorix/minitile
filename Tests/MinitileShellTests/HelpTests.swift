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

// MARK: - Key routing

private let names: [UInt16: String] = [4: "h", 12: "q", 48: "tab", 53: "escape", 123: "left", 124: "right", 36: "return", 96: "f5"]
private let h: UInt16 = 4, q: UInt16 = 12, tab: UInt16 = 48, escape: UInt16 = 53, left: UInt16 = 123, f5: UInt16 = 96

private func makeRouter(_ bindings: [Chord: [String]] = Config.defaultBindings) -> KeyRouter {
    var router = KeyRouter(bindings: bindings, names: names)
    router.switcherAvailable = true
    router.helpAvailable = true
    return router
}

@Test func cmdHShowsHelpWhileCmdIsHeldAndItsRepeatsDoNotReopenIt() {
    var router = makeRouter()
    #expect(router.flags(.cmd) == .pass)
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open(held: .cmd), session: 1))
    #expect(router.help == KeyRouter.OpenModal(kind: .help, session: 1, held: .cmd))
    for _ in 0..<3 { #expect(router.key(h, modifiers: .cmd, down: true, autorepeat: true) == .swallow) }
    #expect(router.help?.session == 1)
    #expect(router.key(h, modifiers: .cmd, down: false) == .swallow)
    #expect(router.flags([.cmd, .shift]) == .pass)
    #expect(router.flags(.cmd) == .pass)
    #expect(router.help?.session == 1)
    #expect(router.flags([]) == .help(.close, session: 1))
    #expect(router.help == nil)
    #expect(router.flags([]) == .pass)
    // Releasing Cmd before H closes it too, and the key-up stays swallowed.
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open(held: .cmd), session: 2))
    #expect(router.flags(.shift) == .help(.close, session: 2))
    #expect(router.key(h, modifiers: .shift, down: false) == .swallow)
    #expect(router.key(h, modifiers: [], down: true) == .pass)
}

@Test func pressingTheHelpBindingAgainReopensItUnderANewSession() {
    var router = makeRouter([Chord(modifiers: [.ctrl, .shift], key: "h"): ["help", "show"], Chord(key: "f5"): ["help", "show"]])
    // Shift is not among the held modifiers.
    #expect(router.key(h, modifiers: [.ctrl, .shift], down: true) == .help(.open(held: .ctrl), session: 1))
    #expect(router.key(h, modifiers: [.ctrl, .shift], down: false) == .swallow)
    #expect(router.flags(.ctrl) == .pass)
    #expect(router.key(h, modifiers: [.ctrl, .shift], down: true) == .help(.open(held: .ctrl), session: 2))
    #expect(router.key(h, modifiers: [.ctrl, .shift], down: false) == .swallow)
    // A binding without modifiers opens a screen that only Esc or its timer closes.
    #expect(router.key(f5, modifiers: [], down: true) == .help(.open(held: []), session: 3))
    #expect(router.flags([]) == .pass)
    #expect(router.key(f5, modifiers: [], down: false) == .swallow)
    #expect(router.key(escape, modifiers: [], down: true) == .help(.close, session: 3))
    #expect(router.key(escape, modifiers: [], down: false) == .swallow)
    // A repeat whose press the tap did not see opens nothing.
    var fresh = makeRouter()
    #expect(fresh.key(h, modifiers: .cmd, down: true, autorepeat: true) == .swallow)
    #expect(fresh.help == nil)
}

@Test func escClosesHelpAndEveryOtherKeyIsSwallowedWhileItIsOpen() {
    var router = makeRouter()
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open(held: .cmd), session: 1))
    let keys: [(UInt16, Modifiers)] = [(q, .cmd), (left, .ctrl), (tab, []), (left, []), (h, [.cmd, .alt])]
    for (code, modifiers) in keys {
        #expect(router.key(code, modifiers: modifiers, down: true) == .swallow)
        #expect(router.key(code, modifiers: modifiers, down: true, autorepeat: true) == .swallow)
        #expect(router.key(code, modifiers: modifiers, down: false) == .swallow)
    }
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
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open(held: .cmd), session: 1))
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
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open(held: .cmd), session: 1))
    #expect(router.key(h, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(tab, modifiers: .cmd, down: true) == .switcher(.open(forward: true, held: .cmd), session: 2))
    #expect(router.help == nil)
    #expect(router.switcher?.session == 2)
    #expect(router.key(tab, modifiers: .cmd, down: false) == .swallow)
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open(held: .cmd), session: 3))
    #expect(router.switcher == nil)
    #expect(router.key(h, modifiers: .cmd, down: false) == .swallow)
    // The switcher's keys no longer go to it, and the release closes the help screen without committing.
    #expect(router.key(left, modifiers: .cmd, down: true) == .swallow)
    #expect(router.flags([]) == .help(.close, session: 3))
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
    #expect(router.key(q, modifiers: .cmd, down: true) == .swallow)
    #expect(router.key(escape, modifiers: [], down: true) == .help(.close, session: 1))
    let timed = router.open(.help)
    // Cmd+H on a screen `mntl` opened holds it with Cmd.
    #expect(router.key(h, modifiers: .cmd, down: true) == .help(.open(held: .cmd), session: 3))
    router.close(timed)
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

@MainActor
private final class FakeClock {
    var pending: [(delay: TimeInterval, work: @MainActor @Sendable () -> Void)] = []
    func fire() {
        let due = pending
        pending = []
        for item in due { item.work() }
    }
}

@MainActor
private func screen() -> (HelpScreen, FakePresenter, FakeClock) {
    let presenter = FakePresenter(), clock = FakeClock()
    return (HelpScreen(presenter: presenter) { clock.pending.append(($0, $1)) }, presenter, clock)
}

private let content = HelpContent(config: .default)

@Test @MainActor func helpFromMntlClosesAfterItsTimeout() {
    let (help, presenter, clock) = screen()
    var expired: [Int] = []
    help.expired = { expired.append($0) }
    help.open(session: 1, held: false, content: content, display: "d")
    #expect(help.isOpen && !help.held)
    #expect(presenter.shown == ["d"])
    #expect(clock.pending.map(\.delay) == [5])
    #expect(HelpScreen.timeout == 5)
    clock.fire()
    #expect(!help.isOpen)
    #expect(presenter.hides == 1)
    #expect(expired == [1])
}

@Test @MainActor func reopeningRestartsTheTimeoutWithoutHidingTheScreen() {
    let (help, presenter, clock) = screen()
    var expired: [Int] = []
    help.expired = { expired.append($0) }
    help.open(session: 1, held: false, content: content, display: nil)
    help.open(session: 2, held: false, content: content, display: nil)
    #expect(presenter.shown == [nil, nil])
    #expect(presenter.hides == 0)
    #expect(clock.pending.count == 2)
    clock.fire()
    #expect(!help.isOpen)
    #expect(presenter.hides == 1)
    #expect(expired == [2])
}

@Test @MainActor func heldHelpHasNoTimerAndClosesOnlyForItsSession() {
    let (help, presenter, clock) = screen()
    help.open(session: 1, held: false, content: content, display: "d")
    help.open(session: 2, held: true, content: content, display: "d")
    #expect(help.held)
    clock.fire()
    #expect(help.session == 2)
    help.close(1)
    #expect(help.isOpen)
    help.close(2)
    #expect(!help.isOpen && !help.held)
    #expect(presenter.hides == 1)
    help.close(2)
    #expect(presenter.hides == 1)
    #expect(help.isStale(2) && !help.isStale(3))
}

@Test @MainActor func theSwitcherSupersedesHelpAndHelpTheSwitcher() {
    let (help, presenter, _) = screen()
    help.open(session: 1, held: true, content: content, display: "d")
    help.supersede(4)
    #expect(!help.isOpen)
    #expect(presenter.hides == 1)
    #expect(help.isStale(4) && !help.isStale(5))
    help.supersede(2)
    #expect(help.isStale(4))
    #expect(presenter.hides == 1)
}
