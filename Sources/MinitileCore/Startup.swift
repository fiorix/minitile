import Foundation

extension Engine {
    mutating func start(saved: SavedState?, windows: [WindowInfo], displays: [DisplayInfo], focused: WindowID?, output: inout Output) {
        var observed: [WindowID: WindowInfo] = [:]
        for info in windows where observed[info.id] == nil { observed[info.id] = info }
        state = saved.flatMap { validSnapshot($0) ? $0 : nil } ?? SavedState()
        state.focus = nil
        state.windows = state.windows.filter { id, window in observed[id]?.pid == window.info.pid && observed[id].map(allows) == true }
        for id in state.windows.keys {
            guard let info = observed[id], let old = state.windows[id] else { continue }
            let floats = floating(info, override: old.floatingOverride)
            state.windows[id]?.info = info
            state.windows[id]?.floating = floats
        }
        for d in state.displays.indices {
            for w in state.displays[d].workspaces.indices {
                for p in state.displays[d].workspaces[w].pages.indices {
                    state.displays[d].workspaces[w].pages[p].windows.removeAll { state.windows[$0] == nil || state.windows[$0]?.hidden == true }
                }
            }
        }
        changeDisplays(displays, output: &output)
        output.actions.removeAll()
        state.focus = nil
        _ = repackOverflow()
        let assigned = Set(locations().keys)
        state.windows = state.windows.filter { $0.value.hidden || assigned.contains($0.key) }
        var adopted = Set<WindowID>()
        let unknown = windows.filter { info in
            state.windows[info.id] == nil && allows(info) && adopted.insert(info.id).inserted
        }
        for onStash in [false, true] {
            var cursors: [Int: Int] = [:]
            var counts: [UInt64: Int] = [:]
            for (d, display) in state.displays.enumerated() where display.info.unmanagedReason == nil {
                guard let first = display.workspaces.first else { continue }
                cursors[d] = onStash ? (first.pages.lastIndex(where: { !$0.windows.isEmpty }).map { $0 + 1 } ?? 0) : 0
                for page in first.pages { counts[page.id] = tiled(page).count }
            }
            for info in unknown where info.onStash == onStash {
                guard let d = displayIndex(info.display) ?? currentDisplay(),
                      state.displays[d].info.unmanagedReason == nil, var p = cursors[d] else { continue }
                let floats = floating(info)
                while !floats && p < state.displays[d].workspaces[0].pages.count,
                      counts[state.displays[d].workspaces[0].pages[p].id, default: 0] >= 4 { p += 1 }
                if p == state.displays[d].workspaces[0].pages.count {
                    let page = PageState(id: nextSerial())
                    state.displays[d].workspaces[0].pages.append(page)
                }
                let pageID = state.displays[d].workspaces[0].pages[p].id
                state.windows[info.id] = WindowState(info: info, display: state.displays[d].info.id, floating: floats)
                state.displays[d].workspaces[0].pages[p].windows.append(info.id)
                if !floats { counts[pageID, default: 0] += 1 }
                cursors[d] = p
                output.events.append(Event(type: "window_added", data: .number(Double(info.id))))
            }
        }
        if let focused, let at = location(focused) {
            show(at, focusWindow: false, output: &output)
            focus(focused, action: false, output: &output)
        }
    }

    private func validSnapshot(_ snapshot: SavedState) -> Bool {
        guard snapshot.version == 1, snapshot.serial < UInt64(Int64.max) else { return false }
        var displays = Set<DisplayID>(), identities = Set<UInt64>(), windows = Set<WindowID>()
        for display in snapshot.displays {
            guard displays.insert(display.info.id).inserted else { return false }
            guard display.workspaces.isEmpty || display.workspaces.contains(where: { $0.id == display.currentWorkspace }) else { return false }
            for workspace in display.workspaces {
                guard workspace.id <= snapshot.serial, identities.insert(workspace.id).inserted,
                      workspace.pages.contains(where: { $0.id == workspace.currentPage }) else { return false }
                for page in workspace.pages {
                    guard page.id <= snapshot.serial, identities.insert(page.id).inserted, page.r1.isFinite, page.r2.isFinite else { return false }
                    for id in page.windows { guard windows.insert(id).inserted else { return false } }
                }
            }
        }
        return true
    }
}
