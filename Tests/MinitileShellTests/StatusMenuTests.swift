import AppKit
import Testing
@testable import minitile

@MainActor private final class MenuRefreshState {
    var value = 0
    var rendered: [Int] = []
}

@Test @MainActor func appWarningsRequestRefreshOnlyWhenTheyChange() throws {
    var queued: [MenuRefresh.Work] = []
    let delegate = AppDelegate(menuRefresh: MenuRefresh { queued.append($0) })
    // Complete the queued request through its shutdown guard, without rendering panels or a status item.
    func finishRequest() throws {
        try #require(queued.count == 1)
        delegate.quitting = true
        queued.removeFirst()()
        delegate.quitting = false
    }
    delegate.warnings = [:]
    #expect(queued.isEmpty)
    delegate.warnings["test"] = "First warning"
    try finishRequest()
    delegate.warnings["test"] = "First warning"
    delegate.warnings = ["test": "First warning"]
    #expect(queued.isEmpty)
    delegate.warnings["test"] = "Second warning"
    try finishRequest()
    delegate.warnings.removeValue(forKey: "test")
    try finishRequest()
    delegate.warnings.removeValue(forKey: "test")
    #expect(queued.isEmpty)
    #expect(!delegate.started)
}

@Test @MainActor func menuRefreshCoalescesABurstAndReadsTheLatestState() {
    var queued: [MenuRefresh.Work] = []
    let refresh = MenuRefresh { queued.append($0) }
    let state = MenuRefreshState()
    for next in 1...100 {
        state.value = next
        refresh.request { state.rendered.append(state.value) }
    }
    #expect(queued.count == 1 && state.rendered.isEmpty)
    queued.removeFirst()()
    #expect(state.rendered == [100])
    state.value = 101
    refresh.request { state.rendered.append(state.value) }
    #expect(queued.count == 1)
    queued.removeFirst()()
    #expect(state.rendered == [100, 101] && queued.isEmpty)
}

@Test @MainActor func menuRefreshDuringRenderingQueuesTheNextTurn() {
    var queued: [MenuRefresh.Work] = []
    let refresh = MenuRefresh { queued.append($0) }
    var renders = 0
    refresh.request {
        renders += 1
        refresh.request { renders += 1 }
        refresh.request { renders += 1 }
    }
    queued.removeFirst()()
    #expect(renders == 1 && queued.count == 1)
    queued.removeFirst()()
    #expect(renders == 2 && queued.isEmpty)
}

@Test func statusWarningsTrackAppearanceRemovalAndDisplayNames() {
    let empty = StatusWarnings([], advice: [])
    let secure = "Secure input is blocking keyboard shortcuts"
    let keyboard = "Keyboard tap unavailable; check Accessibility and restart"
    #expect(StatusWarnings([secure], advice: []) != empty)
    #expect(StatusWarnings([secure, keyboard], advice: []) == StatusWarnings([keyboard, secure], advice: []))
    #expect(StatusWarnings([secure, keyboard], advice: []) != StatusWarnings([keyboard], advice: []))
    let first = StatusWarnings([keyboard], advice: [.secondDesktop(name: "Studio")])
    let renamed = StatusWarnings([keyboard], advice: [.secondDesktop(name: "Office")])
    #expect(first != renamed)
    #expect(renamed.titles == ["Office needs a second desktop", keyboard])
    #expect(StatusWarnings([], advice: []).isEmpty)
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
