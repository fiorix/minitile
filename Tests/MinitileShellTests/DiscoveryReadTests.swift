import MinitileCore
import Testing
@testable import minitile

private func record(_ id: WindowID, pid: Int32, layer: Int = 0, alpha: Double = 1) -> CGWindowRecord {
    CGWindowRecord(id: id, pid: pid, app: "", title: "", frame: Rect(x: 0, y: 0, width: 100, height: 100), layer: layer, alpha: alpha)
}

private func snapshot(_ records: CGWindowRecord...) -> [WindowID: CGWindowRecord] {
    Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
}

@Test func accessoryAppsAreReadOnlyWhileTheyOwnARealWindow() {
    let apps = [AppCandidate(pid: 1, regular: true), AppCandidate(pid: 2, regular: false), AppCandidate(pid: 3, regular: false),
                AppCandidate(pid: 4, regular: false), AppCandidate(pid: 5, regular: false)]
    let cg = snapshot(record(20, pid: 2), record(30, pid: 3, layer: 25), record(40, pid: 4, alpha: 0))
    #expect(DiscoveryPlan.reads(apps, snapshot: cg, reading: []) == [1, 2])
    #expect(DiscoveryPlan.reads(apps, snapshot: [:], reading: []) == [1])
}

@Test func appsWhoseReadIsRunningAreSkipped() {
    let apps = [AppCandidate(pid: 1, regular: true), AppCandidate(pid: 2, regular: true)]
    #expect(DiscoveryPlan.reads(apps, snapshot: [:], reading: [1]) == [2])
    var ledger = DiscoveryLedger()
    let first = ledger.beginRead(1)
    let overlapping = ledger.beginRead(1)
    #expect(first && !overlapping)
    #expect(ledger.reading == [1])
    ledger.endRead(1, answered: true)
    #expect(ledger.reading.isEmpty)
    let next = ledger.beginRead(1)
    #expect(next)
}

@Test func resultsAreStaleForWindowsTouchedAfterTheirWorkBegan() {
    var ledger = DiscoveryLedger()
    ledger.touch(1)
    let ticket = ledger.beginSnapshot()
    _ = ledger.beginRead(10)
    ledger.endSnapshot()
    ledger.touch(2)
    #expect(!ledger.stale(1, since: ticket))
    #expect(ledger.stale(2, since: ticket))
    #expect(!ledger.stale(3, since: ticket))
    let later = ledger.ticket
    #expect(!ledger.stale(2, since: later))
}

@Test func touchesLastUntilTheLastRunningReadEnds() {
    var ledger = DiscoveryLedger()
    let ticket = ledger.beginSnapshot()
    _ = ledger.beginRead(1)
    _ = ledger.beginRead(2)
    ledger.endSnapshot()
    ledger.touch(7)
    ledger.endRead(1, answered: true)
    #expect(ledger.stale(7, since: ticket))
    ledger.endRead(2, answered: true)
    #expect(!ledger.stale(7, since: ticket))
    let snapshotOnly = ledger.beginSnapshot()
    ledger.touch(8)
    #expect(ledger.stale(8, since: snapshotOnly))
}

@Test func stampsOrderEveryTouch() {
    var ledger = DiscoveryLedger()
    let first = ledger.touch(5)
    let second = ledger.touch(5)
    #expect(second > first)
    #expect(ledger.stamp == second)
}

@Test func resultsAreDroppedWhileSuspendedOrAfterASuspensionBegan() {
    var ledger = DiscoveryLedger()
    let ticket = ledger.ticket
    #expect(ledger.accepts(ticket, frozen: false))
    #expect(!ledger.accepts(ticket, frozen: true))
    ledger.suspend()
    #expect(!ledger.accepts(ticket, frozen: false))
    #expect(ledger.accepts(ledger.ticket, frozen: false))
}

@Test func registrationsWaitForTheLatestReadToBeAnswered() {
    var ledger = DiscoveryLedger()
    #expect(!ledger.answers(1))
    _ = ledger.beginRead(1)
    ledger.endRead(1, answered: true)
    #expect(ledger.answers(1))
    _ = ledger.beginRead(1)
    ledger.endRead(1, answered: nil)
    #expect(ledger.answers(1))
    _ = ledger.beginRead(1)
    ledger.endRead(1, answered: false)
    #expect(!ledger.answers(1))
    ledger.record(1, answered: true)
    #expect(ledger.answers(1))
    ledger.forget(1)
    #expect(!ledger.answers(1))
}

@Test func presenceRemovesAfterThreeMissesAndResetsWhenSeen() {
    var misses = PresenceMisses()
    let known = [PresenceMisses.Known(id: 1, pid: 10, added: 1), PresenceMisses.Known(id: 2, pid: 10, added: 1)]
    for _ in 0..<2 {
        let gone = misses.check(known, pids: [10], snapshot: snapshot(record(2, pid: 10)), taken: 5)
        #expect(gone.isEmpty)
    }
    #expect(misses.counts == [1: 2])
    let seen = misses.check(known, pids: [10], snapshot: snapshot(record(1, pid: 10), record(2, pid: 10)), taken: 5)
    #expect(seen.isEmpty)
    #expect(misses.counts.isEmpty)
    for _ in 0..<2 {
        let gone = misses.check(known, pids: [10], snapshot: [:], taken: 5)
        #expect(gone.isEmpty)
    }
    let gone = misses.check(known, pids: [10], snapshot: [:], taken: 5)
    #expect(gone == [1, 2])
}

@Test func presenceCountsOnlyWindowsKnownWhenTheSnapshotWasTaken() {
    var misses = PresenceMisses()
    let known = [PresenceMisses.Known(id: 1, pid: 10, added: 3), PresenceMisses.Known(id: 2, pid: 10, added: 9)]
    for _ in 0..<3 { _ = misses.check(known, pids: [10], snapshot: [:], taken: 5) }
    #expect(misses.counts[1] == 3)
    #expect(misses.counts[2] == nil)
}

@Test func presenceNeedsTheSamePidAndChecksOnlyTheGivenPids() {
    var misses = PresenceMisses()
    let known = [PresenceMisses.Known(id: 1, pid: 10, added: 0), PresenceMisses.Known(id: 2, pid: 20, added: 0)]
    let reused = snapshot(record(1, pid: 11))
    for _ in 0..<2 { _ = misses.check(known, pids: [10], snapshot: reused, taken: 0) }
    let gone = misses.check(known, pids: [10], snapshot: reused, taken: 0)
    #expect(gone == [1])
    #expect(misses.counts[2] == nil)
    misses.forget(1)
    #expect(misses.counts[1] == nil)
}

@Test func failedAttributeReadsKeepPriorValues() {
    var info = WindowInfo(id: 1, pid: 10, title: "Old", frame: Rect(x: 0, y: 0, width: 10, height: 10), tileable: true, minimized: false)
    info.apply(WindowAttributes(), appHidden: true, geometry: true)
    #expect(info.title == "Old" && info.tileable && !info.minimized && info.appHidden)
    #expect(info.frame == Rect(x: 0, y: 0, width: 10, height: 10))
    let read = WindowAttributes(title: "New", minimized: true, frame: Rect(x: 5, y: 5, width: 20, height: 20), tileable: false)
    var settling = info
    settling.apply(read, appHidden: false, geometry: false)
    #expect(settling.frame == info.frame)
    #expect(settling.title == "New" && settling.minimized && !settling.tileable && !settling.appHidden)
    info.apply(read, appHidden: false, geometry: true)
    #expect(info.frame == Rect(x: 5, y: 5, width: 20, height: 20))
}

@Test func scanWallTimeRunsToTheLastAppliedRead() {
    var passes = ScanPasses()
    let pass = passes.begin(at: 10)
    passes.reading(pass, reads: 2, at: 10.02)
    passes.readFinished(pass, at: 10.5)
    #expect(passes.count == 0)
    passes.readFinished(pass, at: 11)
    #expect(passes.count == 1)
    #expect(abs(passes.milliseconds - 1000) < 0.001)
    passes.readFinished(pass, at: 12)
    #expect(passes.count == 1)
}

@Test func scansWithoutReadsFinishAtOnceAndCancelledOnesAreNotCounted() {
    var passes = ScanPasses()
    let empty = passes.begin(at: 1)
    passes.reading(empty, reads: 0, at: 1.25)
    #expect(passes.count == 1)
    #expect(abs(passes.milliseconds - 250) < 0.001)
    let cancelled = passes.begin(at: 2)
    passes.cancel(cancelled)
    passes.readFinished(cancelled, at: 3)
    #expect(passes.count == 1)
    passes.add(milliseconds: 40)
    #expect(passes.count == 2)
    #expect(abs(passes.milliseconds - 290) < 0.001)
}

@Test func popupsHaveNoMeaningfulSubroleAndNoCloseButton() {
    // Chrome's address bar suggestions: AXUnknown, no close button.
    #expect(WindowAttributes.popup(subrole: "AXUnknown", closeButton: false) == true)
    #expect(WindowAttributes.popup(subrole: "AXUnknown", closeButton: true) == false)
    #expect(WindowAttributes.popup(subrole: "AXUnknown", closeButton: nil) == nil)
    #expect(WindowAttributes.popup(subrole: "AXStandardWindow", closeButton: nil) == false)
    #expect(WindowAttributes.popup(subrole: "AXDialog", closeButton: false) == false)
    #expect(WindowAttributes.popup(subrole: nil, closeButton: false) == nil)
}

private func known(_ id: WindowID, pid: Int32 = 10, added: Int = 0, orderedOut: Bool = false) -> OrderedOutChecks.Known {
    OrderedOutChecks.Known(info: WindowInfo(id: id, pid: pid, orderedOut: orderedOut), added: added)
}

private func offScreen(_ id: WindowID, pid: Int32 = 10) -> CGWindowRecord {
    var result = record(id, pid: pid)
    result.onScreen = false
    return result
}

@Test func orderedOutAfterThreeOffScreenSightingsInARowAndBackWhenSeen() {
    var checks = OrderedOutChecks()
    let windows = [known(1), known(2)]
    let both = snapshot(offScreen(1), offScreen(2))
    for _ in 0..<2 { #expect(checks.check(windows, pids: [10], snapshot: both, offScreen: [1, 2], taken: 5).isEmpty) }
    // A sighting that is not off screen on a shown desktop, like a stashed window's, breaks the run.
    #expect(checks.check(windows, pids: [10], snapshot: both, offScreen: [1], taken: 5) == [1: true])
    #expect(checks.counts.isEmpty)
    let flagged = [known(1, orderedOut: true), known(2)]
    #expect(checks.check(flagged, pids: [10], snapshot: both, offScreen: [1, 2], taken: 5).isEmpty)
    #expect(checks.counts == [2: 1])
    let seen = snapshot(record(1, pid: 10), record(2, pid: 10))
    #expect(checks.check(flagged, pids: [10], snapshot: seen, offScreen: [], taken: 5) == [1: false])
    #expect(checks.counts.isEmpty)
}

@Test func orderedOutIgnoresWindowsThatTellNothing() {
    var checks = OrderedOutChecks()
    var minimized = known(1)
    minimized.info.minimized = true
    var appHidden = known(2)
    appHidden.info.appHidden = true
    let windows = [minimized, appHidden, known(3, added: 9), known(4, pid: 20), known(5)]
    let records = snapshot(offScreen(1), offScreen(2), offScreen(3), offScreen(4), offScreen(5, pid: 11))
    for _ in 0..<3 {
        #expect(checks.check(windows, pids: [10], snapshot: records, offScreen: [1, 2, 3, 4, 5], taken: 5).isEmpty)
    }
    #expect(checks.counts.isEmpty)
}
