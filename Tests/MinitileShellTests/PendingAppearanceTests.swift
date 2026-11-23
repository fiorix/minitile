import ApplicationServices
import Foundation
import MinitileCore
import Testing
@testable import minitile

@MainActor private final class PendingHarness {
    static let display = DisplayInfo(id: "d", frame: Rect(x: 0, y: 0, width: 1440, height: 900),
                                     visibleFrame: Rect(x: 0, y: 38, width: 1440, height: 862),
                                     isPrimary: true, visibleSpace: 10, stashSpace: 20)
    let directory: URL
    let delegate: AppDelegate
    let discovery: Discovery
    let reconciler: Reconciler
    var buttons = 0
    var activePids: Set<Int32> = [100]
    var appFocus: [Int32: FocusObservation] = [:]
    var frontmostFocus: FocusObservation = .unknown
    var liveFrames: [WindowID: Rect?] = [:]
    var frameReads: [WindowID] = []
    var spaceMoves: [SpaceMove] = []
    var frameWrites: [(WindowID, Rect)] = []
    var retriedPids: [Set<Int32>] = []
    var focusRefreshes = 0

    init(initialWindows: [WindowInfo]? = nil, focus: WindowID? = 1) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("minitile-pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        delegate = AppDelegate(menuRefresh: MenuRefresh { _ in })
        delegate.stateWriter = StateWriter(file: directory.appendingPathComponent("state.json"))
        delegate.displays.setDisplays([NativeDisplay(info: Self.display, identifier: "native-d",
                                                     spaces: [NativeSpace(id: 10, type: 0), NativeSpace(id: 20, type: 0)],
                                                     current: 10)])
        discovery = Discovery(config: .default, displays: delegate.displays)
        reconciler = Reconciler(discovery: discovery, displays: delegate.displays)
        reconciler.submitSpaceMove = { [weak self] move in self?.spaceMoves.append(move); return true }
        reconciler.readEnhancedUI = { _ in nil }
        reconciler.setEnhancedUI = { _, _ in }
        reconciler.writeWindowFrame = { [weak self] id, _, rect in self?.frameWrites.append((id, rect)) }
        delegate.discovery = discovery
        delegate.reconciler = reconciler
        delegate.pressedMouseButtons = { [weak self] in self?.buttons ?? 0 }
        delegate.appearanceHooks = AppearanceHooks(
            isKnown: { [weak self] id, pid in self?.discovery.windows[id]?.info.pid == pid },
            readFrame: { [weak self] id in
                guard let self else { return nil }
                self.frameReads.append(id)
                return self.liveFrames[id] ?? nil
            },
            isActive: { [weak self] pid in self?.activePids.contains(pid) == true },
            focusedWindow: { [weak self] pid in self?.appFocus[pid] ?? .unknown },
            refreshFocus: { [weak self] in
                guard let self else { return }
                self.focusRefreshes += 1
                if case .known(let id) = self.frontmostFocus { self.delegate.focusReported(id) }
            },
            retryRead: { [weak self] pids in self?.retriedPids.append(pids) }
        )
        let seeds = initialWindows ?? [Self.window(1, pid: 100)]
        for info in seeds { register(info) }
        delegate.started = true
        _ = delegate.handle(.started(saved: nil, windows: seeds, displays: [Self.display], focus: focus))
        clearSideEffects()
    }

    deinit {
        let dir = directory
        MainActor.assumeIsolated {
            delegate.appearanceTimer?.invalidate()
            delegate.dragTimer?.invalidate()
            delegate.switcherPressTimer?.invalidate()
            delegate.stateWriter.flush()
        }
        try? FileManager.default.removeItem(at: dir)
    }

    static func window(_ id: WindowID, pid: Int32 = 100, title: String = "Tab",
                       frame: Rect = Rect(x: 40, y: 80, width: 1200, height: 800),
                       fromFrontmostApp: Bool = true) -> WindowInfo {
        WindowInfo(id: id, pid: pid, bundleID: "com.google.Chrome", appName: "Chrome", title: title,
                   frame: frame, fromFrontmostApp: fromFrontmostApp, display: "d")
    }

    func register(_ info: WindowInfo) {
        discovery.setWindow(info.id, window: Discovery.Window(info: info, element: AXUIElementCreateSystemWide()))
        liveFrames[info.id] = info.frame
    }

    func unregister(_ id: WindowID) {
        discovery.setWindow(id, window: nil)
        liveFrames.removeValue(forKey: id)
    }

    func clearSideEffects() {
        frameReads.removeAll()
        spaceMoves.removeAll()
        frameWrites.removeAll()
        retriedPids.removeAll()
        focusRefreshes = 0
    }
}

@Test @MainActor func heldMousePressDefersAppearanceWithoutFrameOrSpaceWritesAndAdmitsOnceOnRelease() throws {
    let harness = try PendingHarness()
    harness.buttons = 1
    let torn = PendingHarness.window(2, title: "Detached")
    harness.register(torn)
    _ = harness.delegate.handle(.windowAppeared(torn))

    // Neither the torn-off window nor the existing window gets a frame write or Space move while the button is held.
    #expect(harness.delegate.pendingAppearances.contains(2))
    #expect(harness.delegate.appearanceTimer != nil)
    #expect(harness.delegate.engine.savedState().windows[2] == nil)
    #expect(harness.frameWrites.isEmpty)
    #expect(harness.spaceMoves.isEmpty)

    // Updates, moves and focus notifications for the pending window stay outside the model and do not start drags.
    var moved = torn
    moved.title = "Detached Updated"
    moved.frame = Rect(x: 320, y: 140, width: 1200, height: 800)
    harness.register(moved)
    harness.delegate.windowMoved(2)
    _ = harness.delegate.handle(.windowUpdated(moved))
    harness.delegate.focusReported(2)
    #expect(harness.reconciler.dragging == nil)
    #expect(harness.delegate.engine.savedState().focus == 1)
    #expect(harness.frameWrites.isEmpty)
    #expect(harness.spaceMoves.isEmpty)

    // Overflow on a full 4-window page also causes no premature Space stash or page switch before release.
    let full = try PendingHarness(initialWindows: (1...4).map { PendingHarness.window(WindowID($0)) }, focus: 4)
    full.buttons = 1
    let fifth = PendingHarness.window(5)
    full.register(fifth)
    _ = full.delegate.handle(.windowAppeared(fifth))
    #expect(full.frameWrites.isEmpty && full.spaceMoves.isEmpty)
    #expect(full.delegate.engine.savedState().displays[0].workspaces[0].pages.count == 1)

    // Releasing the left button reads the live frame once, refreshes activation, tiles both windows, and stops polling.
    let releasedFrame = Rect(x: 500, y: 200, width: 1200, height: 800)
    harness.liveFrames[2] = releasedFrame
    harness.frontmostFocus = .known(2)
    harness.buttons = 0
    harness.delegate.drainPendingAppearancesIfReleased()
    #expect(harness.delegate.pendingAppearances.isEmpty)
    #expect(harness.delegate.appearanceTimer == nil)
    #expect(harness.frameReads == [2])
    #expect(harness.focusRefreshes == 1)
    let state = harness.delegate.engine.savedState()
    #expect(state.windows[2]?.info.title == "Detached Updated")
    #expect(state.displays[0].workspaces[0].pages[0].windows == [1, 2])
    #expect(state.focus == 2)
    #expect(Set(harness.frameWrites.map(\.0)) == [1, 2])

    // Subsequent release polls do not re-admit the window.
    harness.clearSideEffects()
    harness.delegate.drainPendingAppearancesIfReleased()
    #expect(harness.frameReads.isEmpty && harness.frameWrites.isEmpty && harness.spaceMoves.isEmpty)
}

@Test @MainActor func reattachedOrClosedWindowBeforeReleaseLeavesExistingTilesUntouched() throws {
    let harness = try PendingHarness()
    harness.buttons = 1
    let torn = PendingHarness.window(2)
    harness.register(torn)
    _ = harness.delegate.handle(.windowAppeared(torn))
    #expect(harness.delegate.appearanceTimer != nil)

    // Reattaching the tab into the source strip destroys the temporary window before mouse-up.
    harness.unregister(2)
    _ = harness.delegate.handle(.windowGone(2))
    #expect(harness.delegate.pendingAppearances.isEmpty)
    #expect(harness.delegate.appearanceTimer == nil)
    #expect(harness.frameWrites.isEmpty && harness.spaceMoves.isEmpty)
    #expect(harness.delegate.engine.savedState().windows.keys.sorted() == [1])
    #expect(harness.delegate.engine.savedState().focus == 1)

    harness.buttons = 0
    harness.delegate.drainPendingAppearancesIfReleased()
    #expect(harness.frameReads.isEmpty && harness.frameWrites.isEmpty)
}

@Test @MainActor func transientFrameReadFailureRetainsPendingWindowWithoutPollingUntilFrameRecovers() throws {
    let harness = try PendingHarness()
    harness.buttons = 1
    let slow = PendingHarness.window(2, pid: 200)
    harness.activePids = [100, 200]
    harness.register(slow)
    _ = harness.delegate.handle(.windowAppeared(slow))

    // At mouse-up, AX.frame transiently fails (nil). The entry stays pending without 30 ms AX retries.
    harness.liveFrames[2] = .some(nil)
    harness.buttons = 0
    harness.delegate.drainPendingAppearancesIfReleased()
    #expect(harness.delegate.pendingAppearances.contains(2))
    #expect(!harness.delegate.pendingAppearances.needsReleasePoll)
    #expect(harness.delegate.appearanceTimer == nil)
    #expect(harness.frameReads == [2])
    #expect(harness.retriedPids == [[200]])
    #expect(harness.delegate.engine.savedState().windows[2] == nil)

    // Repeated release checks while awaiting a frame make zero additional AX.frame calls, and healthy apps are not blocked.
    harness.clearSideEffects()
    harness.delegate.drainPendingAppearancesIfReleased()
    #expect(harness.frameReads.isEmpty)
    let healthy = PendingHarness.window(3, pid: 100)
    harness.register(healthy)
    _ = harness.delegate.handle(.windowAppeared(healthy))
    #expect(harness.delegate.engine.savedState().windows[3] != nil)
    #expect(harness.delegate.pendingAppearances.contains(2))

    // Once discovery observes a live frame, the retained entry admits immediately without a duplicate AX.frame read.
    harness.clearSideEffects()
    let recovered = Rect(x: 100, y: 100, width: 900, height: 700)
    harness.frontmostFocus = .known(2)
    harness.delegate.observedWindowFrame(2, pid: 200, frame: recovered)
    #expect(harness.delegate.pendingAppearances.isEmpty)
    #expect(harness.frameReads.isEmpty)
    #expect(harness.delegate.engine.savedState().windows[2] != nil)
    #expect(harness.delegate.engine.savedState().focus == 2)
}

@Test @MainActor func suspensionPreservesPendingAppearancesAndResumeRevalidatesThem() throws {
    let harness = try PendingHarness()
    harness.buttons = 1
    let surviving = PendingHarness.window(2)
    let vanished = PendingHarness.window(3)
    harness.register(surviving)
    harness.register(vanished)
    _ = harness.delegate.handle(.windowAppeared(surviving))
    _ = harness.delegate.handle(.windowAppeared(vanished))
    #expect(harness.delegate.appearanceTimer != nil)

    // Entering suspension stops the timer, keeps pending entries, and blocks admission even if the button goes up.
    _ = harness.delegate.suspension.set("sleep", enabled: true)
    harness.discovery.frozen = true
    harness.delegate.suspendPendingAppearances()
    #expect(harness.delegate.appearanceTimer == nil)
    #expect(harness.delegate.pendingAppearances.contains(2) && harness.delegate.pendingAppearances.contains(3))
    harness.buttons = 0
    harness.delegate.drainPendingAppearancesIfReleased()
    #expect(harness.delegate.engine.savedState().windows[2] == nil)

    // Resuming with the button still held drops vanished entries and restarts release tracking for surviving ones.
    harness.unregister(3)
    harness.buttons = 1
    _ = harness.delegate.suspension.set("sleep", enabled: false)
    harness.discovery.frozen = false
    harness.delegate.resumePendingAppearances()
    #expect(harness.delegate.pendingAppearances.contains(2))
    #expect(!harness.delegate.pendingAppearances.contains(3))
    #expect(harness.delegate.appearanceTimer != nil)
    #expect(harness.delegate.engine.savedState().windows[2] == nil)

    // Resuming (or releasing) with the button up admits the surviving window once.
    harness.buttons = 0
    harness.frontmostFocus = .known(2)
    harness.delegate.resumePendingAppearances()
    #expect(harness.delegate.pendingAppearances.isEmpty)
    #expect(harness.delegate.appearanceTimer == nil)
    #expect(harness.delegate.engine.savedState().windows.keys.sorted() == [1, 2])
}

@Test @MainActor func pendingNativeTabSelectionsPreserveSlotTransferAndDeferredClosure() throws {
    let harness = try PendingHarness()
    // Give window 1 a floating override so slot transfer is observable beyond page membership.
    _ = harness.delegate.handle(.command(["window", "float", "1", "on"]))
    harness.clearSideEffects()

    // Case 1: Admitted window 1 -> pending tab 2 -> pending tab 3, and window 1 closes before mouse-up.
    harness.buttons = 1
    let tab2 = PendingHarness.window(2, title: "Tab 2")
    let tab3 = PendingHarness.window(3, title: "Tab 3")
    harness.register(tab2)
    harness.register(tab3)
    _ = harness.delegate.handle(.windowTabSelected(previous: 1, tab2))
    _ = harness.delegate.handle(.windowTabSelected(previous: 2, tab3))
    harness.unregister(1)
    _ = harness.delegate.handle(.windowGone(1))

    // Nothing changed in the model yet; window 1's closure waits so its slot and floatingOverride can transfer to tab 3.
    #expect(harness.frameWrites.isEmpty && harness.spaceMoves.isEmpty)
    #expect(harness.delegate.engine.savedState().windows[1]?.floatingOverride == true)
    #expect(harness.delegate.engine.savedState().windows[3] == nil)

    harness.appFocus[100] = .known(3)
    harness.frontmostFocus = .known(3)
    harness.buttons = 0
    harness.delegate.drainPendingAppearancesIfReleased()

    let state = harness.delegate.engine.savedState()
    #expect(state.windows[1] == nil)
    #expect(state.windows[2]?.info.orderedOut == true)
    #expect(state.windows[3]?.info.orderedOut == false)
    #expect(state.windows[3]?.floatingOverride == true)
    #expect(state.displays[0].workspaces[0].pages[0].windows == [3])
    #expect(state.focus == 3)

    // Case 2: Pending window 10 -> pending tab 11 before an unrelated pending window 12 keeps 10's discovery slot.
    let second = try PendingHarness()
    second.buttons = 1
    let w10 = PendingHarness.window(10, title: "Group A1")
    let w12 = PendingHarness.window(12, pid: 102, title: "Other")
    let w11 = PendingHarness.window(11, title: "Group A2")
    second.activePids = [100, 102]
    second.register(w10)
    second.register(w12)
    second.register(w11)
    _ = second.delegate.handle(.windowAppeared(w10))
    _ = second.delegate.handle(.windowAppeared(w12))
    _ = second.delegate.handle(.windowTabSelected(previous: 10, w11))
    second.frontmostFocus = .known(11)
    second.buttons = 0
    second.delegate.drainPendingAppearancesIfReleased()

    let secondState = second.delegate.engine.savedState()
    #expect(secondState.windows[10]?.info.orderedOut == true)
    #expect(secondState.displays[0].workspaces[0].pages[0].windows == [1, 11, 12])
    #expect(secondState.focus == 11)
}

@Test @MainActor func multiplePendingWindowsFromSameAppPreserveOrderAndRefreshActualFocus() throws {
    // Start with three windows on page 1 so the first pending window takes slot 4 on page 1 and the second spills to page 2.
    let harness = try PendingHarness(initialWindows: (1...3).map { PendingHarness.window(WindowID($0)) }, focus: 3)
    harness.buttons = 1
    let first = PendingHarness.window(4, title: "First")
    let second = PendingHarness.window(5, title: "Second")
    harness.register(first)
    harness.register(second)
    _ = harness.delegate.handle(.windowAppeared(first))
    _ = harness.delegate.handle(.windowAppeared(second))
    #expect(harness.frameWrites.isEmpty && harness.spaceMoves.isEmpty)

    // Both belong to the active app (pid 100), so placement ends on window 5 (page 2), while macOS actually focused window 4 (page 1).
    harness.frontmostFocus = .known(4)
    harness.buttons = 0
    harness.delegate.drainPendingAppearancesIfReleased()

    let state = harness.delegate.engine.savedState()
    let pages = state.displays[0].workspaces[0].pages
    #expect(pages.count == 2)
    #expect(pages[0].windows == [1, 2, 3, 4])
    #expect(pages[1].windows == [5])
    #expect(state.focus == 4)
    #expect(state.displays[0].workspaces[0].currentPage == pages[0].id)
    #expect(harness.focusRefreshes == 1)
}

@Test @MainActor func switcherOwnedPressAdmitsNewWindowsImmediately() throws {
    let harness = try PendingHarness()
    // An earlier deferred entry that has not ticked yet drains alongside a switcher-opened window without stalling.
    harness.buttons = 1
    let earlier = PendingHarness.window(2, title: "Earlier")
    harness.register(earlier)
    _ = harness.delegate.handle(.windowAppeared(earlier))
    #expect(harness.delegate.pendingAppearances.contains(2))

    harness.delegate.switcherOwnsPress = true
    let opened = PendingHarness.window(3, title: "Reopened")
    harness.register(opened)
    harness.frontmostFocus = .known(3)
    _ = harness.delegate.handle(.windowAppeared(opened))

    #expect(harness.delegate.pendingAppearances.isEmpty)
    #expect(harness.delegate.appearanceTimer == nil)
    #expect(harness.delegate.engine.savedState().displays[0].workspaces[0].pages[0].windows == [1, 2, 3])
    #expect(harness.delegate.engine.savedState().focus == 3)
    #expect(Set(harness.frameWrites.map(\.0)) == [1, 2, 3])
}

@Test @MainActor func tabRoundTripsWindowIDReuseAndLeftBehindFocusSuppressionStayConsistent() throws {
    let harness = try PendingHarness(initialWindows: (1...4).map { PendingHarness.window(WindowID($0)) }, focus: 1)
    harness.buttons = 1

    // Round-trip W1 -> W5 -> W1 -> W6 while held leaves only W6 inheriting W1's slot, and W1 ID reuse after closure admits anew.
    let tab5 = PendingHarness.window(5, title: "Tab 5")
    let tab6 = PendingHarness.window(6, title: "Tab 6")
    harness.register(tab5)
    harness.register(tab6)
    _ = harness.delegate.handle(.windowTabSelected(previous: 1, tab5))
    var backTo1 = PendingHarness.window(1, title: "Back 1")
    backTo1.fromFrontmostApp = true
    harness.register(backTo1)
    _ = harness.delegate.handle(.windowTabSelected(previous: 5, backTo1))
    #expect(harness.delegate.engine.savedState().windows[1]?.info.title == "Back 1")
    _ = harness.delegate.handle(.windowTabSelected(previous: 1, tab5))
    _ = harness.delegate.handle(.windowTabSelected(previous: 1, tab6))

    // W1 closes, then the same process reuses ID 1 for an independent new window before mouse-up.
    harness.unregister(1)
    _ = harness.delegate.handle(.windowGone(1))
    let reused1 = PendingHarness.window(1, title: "Reused 1")
    harness.register(reused1)
    _ = harness.delegate.handle(.windowAppeared(reused1))

    // Also include an unseen left-behind tab (fromFrontmostApp == false while app is active) that must not steal the view.
    let leftBehind = PendingHarness.window(7, title: "Left Behind", fromFrontmostApp: false)
    harness.register(leftBehind)
    _ = harness.delegate.handle(.windowAppeared(leftBehind))
    #expect(harness.frameWrites.isEmpty && harness.spaceMoves.isEmpty)

    harness.appFocus[100] = .known(6)
    harness.frontmostFocus = .known(6)
    harness.buttons = 0
    harness.delegate.drainPendingAppearancesIfReleased()

    let state = harness.delegate.engine.savedState()
    let pages = state.displays[0].workspaces[0].pages
    #expect(state.windows[5]?.info.orderedOut == true)
    // W6 took old W1's slot 0 on page 1; reused ID 1 and leftBehind spilled onto page 2 without stealing focus or view from W6.
    #expect(pages[0].windows == [6, 2, 3, 4])
    #expect(pages[1].windows == [1, 7])
    #expect(state.windows[1]?.info.title == "Reused 1")
    #expect(state.focus == 6)
    #expect(state.displays[0].workspaces[0].currentPage == pages[0].id)
}

