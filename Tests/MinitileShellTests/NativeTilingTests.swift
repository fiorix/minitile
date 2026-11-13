import MinitileCore
import Testing
@testable import minitile

@Test func nativeGeometryWaitsForBurstAndWriteEchoToSettle() {
    let target = Rect(x: 8, y: 38, width: 500, height: 600)
    var changes = GeometrySettlement()
    changes.observe(1, pid: 42, target: target, now: 10, suppressedUntil: 0)
    #expect(changes.pending[1]?.due == 10.25)
    changes.observe(1, pid: 42, target: target, now: 10.1, suppressedUntil: 11.2)
    #expect(changes.pending[1]?.due == 11.25)
    let held = changes.holds(1, target: target)
    #expect(held)
    var next = target
    next.width += 200
    let changed = changes.holds(1, target: next)
    #expect(!changed)
    #expect(changes.pending.isEmpty)
}

@Test func nativeGeometryCancellationAndReusedIDsDoNotKeepOldHolds() {
    let target = Rect(x: 8, y: 38, width: 500, height: 600)
    var changes = GeometrySettlement()
    changes.observe(1, pid: 42, target: target, now: 10, suppressedUntil: 0)
    changes.observe(1, pid: 99, target: target, now: 12, suppressedUntil: 0)
    #expect(changes.pending[1]?.pid == 99)
    changes.cancel(1)
    let held = changes.holds(1, target: target)
    #expect(!held)
}

@Test func nativeGeometryKeepsCorrectionEchoesFromRetryingForever() {
    let target = Rect(x: 8, y: 38, width: 500, height: 600)
    var changes = GeometrySettlement()
    changes.observe(1, pid: 42, target: target, now: 10, suppressedUntil: 11.2)
    #expect(changes.pending[1]?.mayRestore == true)
    changes.observe(1, pid: 42, target: target, now: 11.3, suppressedUntil: 12.5, mayRestore: false)
    #expect(changes.pending[1]?.mayRestore == false)
    #expect(changes.pending[1]?.due == 12.55)
}

@Test func nativeGeometryAppearsInGridMiniatures() {
    let area = Rect(x: 0, y: 0, width: 1000, height: 800)
    var e = Engine()
    _ = e.handle(.started(saved: nil, windows: (1...4).map { WindowInfo(id: WindowID($0), pid: 1, display: "a") },
                          displays: [DisplayInfo(id: "a", frame: area)], focus: 1))
    let native = Rect(x: 0, y: 0, width: 500, height: 800)
    let out = e.handle(.nativeTiled(1, frame: native))
    let state = e.savedState(), page = state.displays[0].workspaces[0].pages[0]
    let miniature = GridMiniature(page: page, windows: state.windows, focus: 1, area: area, config: .default)
    #expect(miniature.slots.first { $0.window == 1 }?.frame == Rect(x: 8, y: 8, width: 488, height: 784))
    #expect(Dictionary(uniqueKeysWithValues: miniature.tiles.map { ($0.window, $0.frame!) }) == out.scene.displays["a"]?.frames.filter { page.windows.contains($0.key) })
}

@Test func nativeSelectionCoalescesArrangeAndIgnoresOwnFrameEchoes() throws {
    let area = Rect(x: 0, y: 0, width: 1000, height: 800)
    var e = Engine()
    let initial = e.handle(.started(saved: nil, windows: (1...4).map { WindowInfo(id: WindowID($0), pid: 1, display: "a") },
                                   displays: [DisplayInfo(id: "a", frame: area)], focus: 4))
    let state = e.savedState(), page = state.displays[0].workspaces[0].pages[0]
    let targets = try #require(initial.scene.displays["a"]?.frames)
    #expect(NativeSelection(page: page, state: state, area: area, actual: targets, targets: targets) == nil)
    let left = Rect(x: 0, y: 0, width: 500, height: 800), right = Rect(x: 500, y: 0, width: 500, height: 800)
    var observed = targets
    observed[4] = left; observed[2] = right
    let selection = try #require(NativeSelection(page: page, state: state, area: area, actual: observed, targets: targets))
    #expect(selection.window == 4)
    #expect(selection.frame == left)
    #expect(selection.companions == [2: right])
    let out = e.handle(.nativeTiled(selection.window, frame: selection.frame, companions: selection.companions))
    #expect(out.scene.displays["a"]?.visible == [4, 2])
    #expect(out.scene.displays["a"]?.stashed == [1, 3])
}

@Test func nativeGeometryWaitsForEveryWindowInAnArrangeBurst() {
    let area = Rect(x: 0, y: 0, width: 1000, height: 800)
    var e = Engine()
    _ = e.handle(.started(saved: nil, windows: [WindowInfo(id: 1, pid: 1), WindowInfo(id: 2, pid: 2)],
                          displays: [DisplayInfo(id: "a", frame: area)], focus: 1))
    var changes = GeometrySettlement()
    changes.observe(1, pid: 1, target: area, now: 10, suppressedUntil: 0)
    changes.observe(2, pid: 2, target: area, now: 10.1, suppressedUntil: 0)
    #expect(changes.ready(state: e.savedState(), now: 10.3).isEmpty)
    #expect(Set(changes.ready(state: e.savedState(), now: 10.4).keys) == [1, 2])
}
