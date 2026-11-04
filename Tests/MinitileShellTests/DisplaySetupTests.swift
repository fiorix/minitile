import AppKit
import MinitileCore
import Testing
@testable import minitile

private func display(_ id: DisplayID, _ need: DisplayNeed?) -> DisplayInfo {
    DisplayInfo(id: id, frame: Rect(x: 0, y: 0, width: 1512, height: 982), unmanagedReason: need?.reason)
}

@Test func unmanagedReasonsSayWhatToDoAndReadBack() {
    #expect(DisplayNeed.secondDesktop.reason == "Needs a second desktop: open Mission Control and click + at the top of this display")
    #expect(DisplayNeed.separateSpaces.reason == "Needs Displays have separate Spaces: turn it on in Desktop & Dock settings, then log out")
    for need in DisplayNeed.allCases { #expect(DisplayNeed(reason: need.reason) == need) }
    #expect(DisplayNeed(reason: "Display disconnected") == nil && DisplayNeed(reason: nil) == nil)
}

@Test func menuNamesEachDisplayThatNeedsASecondDesktopAndSaysWhy() {
    let displays = [display("a", .secondDesktop), display("b", nil), display("c", .secondDesktop)]
    let advice = SetupAdvice.list(displays: displays, names: ["a": "LG UltraFine", "b": "Built-in Retina Display"], separateSpaces: true)
    #expect(advice.map(\.title) == ["LG UltraFine needs a second desktop", "A display needs a second desktop"])
    #expect(advice[0].detail == """
        minitile keeps hidden pages on a second desktop. macOS does not let apps add one: open Mission Control and click + \
        at the top of this display.
        """)
    #expect(advice.allSatisfy { $0.fix == .missionControl })
    let warnings = StatusWarnings(["Secure input is blocking keyboard shortcuts"], advice: advice)
    #expect(warnings.titles == ["LG UltraFine needs a second desktop", "A display needs a second desktop",
                                "Secure input is blocking keyboard shortcuts"])
    // One place to add them all.
    #expect(warnings.fixes == [.missionControl])
    #expect(SetupFix.missionControl.title == "Open Mission Control")
    #expect(SetupFix.missionControl.url.path == "/System/Applications/Mission Control.app")
    let fine = StatusWarnings([], advice: SetupAdvice.list(displays: [display("b", nil)], names: [:], separateSpaces: true))
    #expect(fine.isEmpty && fine.fixes.isEmpty)
}

@Test func separateSpacesIsOneSettingForEveryDisplay() {
    let displays = [display("a", .separateSpaces), display("b", .separateSpaces)]
    let advice = SetupAdvice.list(displays: displays, names: ["a": "LG UltraFine"], separateSpaces: false)
    #expect(advice == [.separateSpaces])
    #expect(advice[0].title == "Displays have separate Spaces is off" && advice[0].fix == .desktopSettings)
    #expect(SetupFix.desktopSettings.title == "Open Desktop & Dock Settings")
    #expect(SetupFix.desktopSettings.url.absoluteString == "x-apple.systempreferences:com.apple.Desktop-Settings.extension")
    // A startup that stops for it reads no display; its failure is listed once, with the explanation.
    let startup = StatusWarnings([SetupAdvice.separateSpaces.title],
                                 advice: SetupAdvice.list(displays: [], names: [:], separateSpaces: false))
    #expect(startup.titles == ["Displays have separate Spaces is off"] && startup.others.isEmpty)
    #expect(startup.fixes == [.desktopSettings])
    // Only a missing second desktop gets a notice on the display.
    #expect(DesktopNoticeTiming.needing(displays).isEmpty)
    #expect(DesktopNoticeTiming.needing([display("a", .secondDesktop), display("b", nil)]) == ["a"])
}

@Test func noticeShowsWhenADisplayStartsNeedingASecondDesktopNotOnEveryProbe() {
    var timing = DesktopNoticeTiming()
    // At launch.
    timing.update(needing: ["a"], now: 100)
    #expect(timing.visible(now: 100) == ["a"] && timing.expiry(now: 100) == 112)
    // A display connected without one.
    timing.update(needing: ["a", "b"], now: 103)
    #expect(timing.visible(now: 103) == ["a", "b"] && timing.expiry(now: 103) == 112)
    // Adding the desktop hides its notice at once.
    timing.update(needing: ["b"], now: 104)
    #expect(timing.visible(now: 104) == ["b"])
    // Probes that still find it missing neither extend nor repeat it.
    timing.update(needing: ["b"], now: 110)
    #expect(timing.visible(now: 114.9) == ["b"] && timing.visible(now: 115).isEmpty && timing.expiry(now: 115) == nil)
    timing.update(needing: ["b"], now: 120)
    #expect(timing.visible(now: 120).isEmpty)
    // Removing the desktop again, or reconnecting the display without one, shows it again.
    timing.update(needing: [], now: 121)
    timing.update(needing: ["b"], now: 125)
    #expect(timing.visible(now: 125) == ["b"] && timing.expiry(now: 125) == 137)
    timing.update(needing: [], now: 126)
    timing.update(needing: ["b"], now: 127)
    #expect(timing.visible(now: 127) == ["b"])
}

@Test @MainActor func noticeNamesItsDisplayAboveTheMenusExplanation() {
    let layout = DesktopNoticeLayout(name: "LG UltraFine")
    #expect(layout.advice == .secondDesktop(name: "LG UltraFine"))
    #expect(layout.body == "\(layout.advice.detail) Until then, minitile leaves this display's windows alone.")
    // The body wraps to a few lines, all inside the panel, below the header and the desktops' labels.
    #expect(layout.bodyHeight > 2 * DesktopNoticeLayout.bodySize && layout.bodyRect.maxY + DesktopNoticeLayout.margin == layout.size.height)
    #expect(layout.desktops.count == 2 && layout.headerRect.minY > layout.labelRect(layout.desktops[1]).maxY)
    #expect(layout.bodyRect.minY >= layout.headerRect.maxY && layout.size.width == DesktopNoticeLayout.width)
}
