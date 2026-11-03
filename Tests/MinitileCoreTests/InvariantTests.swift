import Testing
@testable import MinitileCore

private func checkInvariants(_ e: Engine, _ out: Output, step: Int) {
    let state = e.savedState()
    var assigned: [WindowID] = []
    for display in state.displays {
        if display.info.unmanagedReason == nil {
            #expect(display.workspaces.contains { $0.id == display.currentWorkspace }, "Missing current workspace at step \(step)")
        }
        for workspace in display.workspaces {
            #expect(workspace.pages.contains { $0.id == workspace.currentPage })
            for page in workspace.pages {
                #expect(e.tiled(page).count <= 4)
                #expect((0.2...0.8).contains(page.r1))
                #expect((0.2...0.8).contains(page.r2))
                for id in page.windows {
                    assigned.append(id)
                    #expect(state.windows[id]?.display == display.info.id)
                    #expect(state.windows[id]?.hidden == false)
                }
            }
        }
    }
    #expect(Set(assigned).count == assigned.count)
    #expect(Set(assigned) == Set(state.windows.filter { !$0.value.hidden }.keys))
    let placed = out.scene.displays.values.flatMap { $0.visible + $0.stashed }
    #expect(Set(placed).count == placed.count)
    let managed = Set(state.displays.filter { $0.info.unmanagedReason == nil }.map { $0.info.id })
    #expect(Set(placed) == Set(state.windows.filter { managed.contains($0.value.display) }.keys))
    for (id, frame) in out.scene.displays.values.flatMap({ $0.frames }) {
        #expect(state.windows[id]?.floating == false)
        #expect(frame.width >= 0 && frame.height >= 0)
    }
}

@Test func mixedOperationsPreserveModelInvariants() {
    var e = twoDisplays()
    var random: UInt64 = 12345
    for step in 0..<600 {
        random = random &* 6364136223846793005 &+ 1
        let id = WindowID((random >> 32) % 20 + 1)
        let input: Input
        switch step % 15 {
        case 0, 1: input = .windowAppeared(window(id, frontmost: step % 2 == 0))
        case 2: input = .windowGone(id)
        case 3: input = .command(["window", "nudge", String(id), "right"])
        case 4: input = .command(["window", "move", String(id), "workspace", "next"])
        case 5: input = .command(["window", "hide", String(id)])
        case 6: input = .command(["window", "show", String(id)])
        case 7: input = .command(["window", "float", String(id)])
        case 8: input = .command(["page", "prev"])
        case 9: input = .command(["workspace", "prev"])
        case 10: input = .command(["window", "move", String(id), "display", "secondary"])
        case 11: input = .displaysChanged([testDisplay])
        case 12: input = .displaysChanged([testDisplay, secondDisplay])
        case 13: input = .command(["page", "ratio", "0.8", "0.2"])
        default: input = .windowUpdated(window(id))
        }
        let out = e.handle(input)
        checkInvariants(e, out, step: step)
    }
}

@Test func disconnectingFocusedDisplayFocusesPrimaryShownPage() {
    var e = twoDisplays()
    command(&e, "window focus 2")
    let out = e.handle(.displaysChanged([testDisplay]))
    #expect(e.savedState().focus == 1)
    #expect(out.actions.last == .focus(1))
    #expect(out.scene.displays["primary"]?.stashed == [2])
}

@Test func appearanceWithReusedIDReplacesOldProcess() {
    var e = engine(1)
    command(&e, "window hide 1")
    _ = e.handle(.windowAppeared(window(1, pid: 999)))
    #expect(grid(e) == [[[1]]])
    #expect(e.savedState().windows[1]?.info.pid == 999)
}

@Test func manyStartupWindowsHaveOneOwnerAndBoundedPages() {
    var e = Engine()
    let windows = (1...2000).map { window(WindowID($0)) }
    let out = e.handle(.started(saved: nil, windows: windows, displays: [testDisplay], focus: nil))
    #expect(grid(e)[0].count == 500)
    #expect(e.savedState().windows.count == 2000)
    checkInvariants(e, out, step: 0)
}

@Test func bulkConfigChangesPreserveCapacityAndFocus() {
    let apps = (1...500).map { "app.\($0)" }
    var e = Engine(config: Config(floatApps: apps))
    _ = e.handle(.started(saved: nil, windows: (1...500).map { window(WindowID($0)) }, displays: [testDisplay], focus: 500))
    let tiled = e.handle(.configLoaded(.default))
    #expect(grid(e)[0].count == 125)
    #expect(tiled.scene.displays["primary"]?.visible == [497, 498, 499, 500])
    checkInvariants(e, tiled, step: 0)
    let filtered = e.handle(.configLoaded(Config(onlyApps: ["app.1"])))
    #expect(Set(e.savedState().windows.keys) == [1])
    checkInvariants(e, filtered, step: 1)
}

@Test func focusOutsideManagedWindowsClearsCommandTarget() {
    var e = engine(1)
    command(&e, "window focus 1")
    _ = e.handle(.focusChanged(999))
    #expect(e.savedState().focus == nil)
    #expect(e.handle(.command(["window", "close"])).reply?.ok == false)
    #expect(e.savedState().activeDisplay == "primary")
}
