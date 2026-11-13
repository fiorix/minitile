import MinitileCore
import Testing
@testable import minitile

@MainActor private final class SuspensionHelp: HelpPresenting {
    var hides = 0
    func show(_ content: HelpContent, display: DisplayID?) {}
    func hide() { hides += 1 }
}

@Test(arguments: [false, true]) @MainActor func unchangedSuspensionReasonLeavesPendingStateAlone(_ enabled: Bool) {
    let delegate = AppDelegate()
    let presenter = SuspensionHelp()
    delegate.helpScreen = HelpScreen(presenter: presenter)
    delegate.helpScreen.open(session: 1, content: HelpContent(config: .default), display: nil)
    delegate.spaceSync = ["pending"]
    _ = delegate.suspension.set("locked", enabled: enabled)
    for _ in 0..<3 { delegate.suspend("locked", enabled: enabled) }
    #expect(delegate.suspendedReasons == (enabled ? ["locked"] : []))
    #expect(delegate.spaceSync == ["pending"])
    #expect(delegate.helpScreen.session == 1 && presenter.hides == 0)
    #expect(!delegate.started)
}

@Test func resumeWaitsForEveryInterruptionAndRunsOnce() {
    var suspension = SuspensionState()
    for (reason, enabled) in [("locked", false), ("sleep", true), ("locked", true),
                              ("display", true), ("sleep", false), ("display", false)] {
        let resumed = suspension.set(reason, enabled: enabled)
        #expect(!resumed)
    }
    #expect(suspension.reasons == ["locked"])
    let resumed = suspension.set("locked", enabled: false)
    #expect(resumed)
    let resumedAgain = suspension.set("locked", enabled: false)
    #expect(!resumedAgain)
    #expect(suspension.reasons.isEmpty)
}
