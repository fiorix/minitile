import AppKit
import Testing
@testable import minitile

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
