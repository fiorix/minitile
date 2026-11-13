import Foundation

extension Engine {
    func allows(_ info: WindowInfo) -> Bool {
        config.onlyApps.isEmpty || info.bundleID.map(config.onlyApps.contains) == true
    }
    func floating(_ info: WindowInfo, override: Bool? = nil) -> Bool {
        !info.tileable || (override ?? (info.bundleID.map(config.floatApps.contains) == true))
    }

    mutating func updateWindow(_ info: WindowInfo, output: inout Output) {
        guard let old = state.windows[info.id] else { return }
        if old.info.pid != info.pid {
            gone(info.id, output: &output)
            appeared(info, output: &output)
            return
        }
        guard allows(info) else { gone(info.id, output: &output); return }
        state.windows[info.id]?.info = info
        let lostFocus = state.focus == info.id && (info.minimized || info.appHidden || info.orderedOut)
        if lostFocus { focus(nil, action: false, output: &output) }
        if info.orderedOut && location(info.id) != nil {
            removeFromPage(info.id)
            output.events.append(Event(type: "window_moved", data: .number(Double(info.id))))
        }
        updateFloating(info.id, value: floating(info, override: old.floatingOverride), output: &output)
        if old.info.orderedOut && !info.orderedOut { orderedIn(info.id, output: &output) }
        if !old.info.fullscreen && info.fullscreen { wentFullscreen(info.id, output: &output) }
        if !lostFocus && old.info.minimized && !info.minimized, let at = location(info.id) {
            show(at, focusWindow: false, output: &output)
            focus(info.id, action: true, output: &output)
        }
    }

    /// A window its app shows again is placed like a new one, on its display's current page.
    mutating func orderedIn(_ id: WindowID, output: inout Output) {
        guard let window = state.windows[id], !window.hidden, location(id) == nil else { return }
        let own = displayIndex(window.display).flatMap { state.displays[$0].info.unmanagedReason == nil ? $0 : nil }
        guard let d = own ?? currentDisplay(), let start = currentLocation(display: d) else { return }
        let at = place(id, at: start)
        output.events.append(Event(type: "window_moved", data: .number(Double(id))))
        if window.info.fromFrontmostApp {
            show(at, focusWindow: false, output: &output)
            focus(id, action: false, output: &output)
        }
    }

    /// macOS shows a window that goes full screen on a native Space of its own, so the window takes a page of its
    /// own and that page is shown. Leaving full screen needs nothing: the window is tiled on that page.
    mutating func wentFullscreen(_ id: WindowID, output: inout Output) {
        guard let at = isolate(id, output: &output), canFocus(id) else { return }
        show(at, focusWindow: false, output: &output)
        focus(id, action: false, output: &output)
    }

    /// Moves a full screen window that shares its page onto a new page right after it. Returns where the window is.
    mutating func isolate(_ id: WindowID, output: inout Output) -> Location? {
        guard var at = location(id) else { return nil }
        guard page(at).windows.count > 1 else { return at }
        removeFromPage(id)
        var created = PageState(id: nextSerial())
        created.windows = [id]
        at = Location(display: at.display, workspace: at.workspace, page: at.page + 1)
        state.displays[at.display].workspaces[at.workspace].pages.insert(created, at: at.page)
        output.events.append(Event(type: "window_moved", data: .number(Double(id))))
        return at
    }

    /// Full screen windows that came to share a page some other way, as one found full screen at startup does, each
    /// move to a page of their own. The view follows the focused one.
    mutating func isolateFullscreen(output: inout Output) {
        for id in state.windows.keys.sorted() where isFullscreen(id) {
            guard let old = location(id), page(old).windows.count > 1, let at = isolate(id, output: &output) else { continue }
            if state.focus == id {
                show(at, focusWindow: false, output: &output)
                focus(id, action: false, output: &output)
            }
        }
    }

    mutating func updateFloating(_ id: WindowID, value: Bool, output: inout Output) {
        guard let window = state.windows[id], window.floating != value else { return }
        state.windows[id]?.floating = value
        guard !value, let at = location(id), tiled(page(at)).count > 4 else { return }
        let followed = state.focus == id
        removeFromPage(id)
        let target = place(id, at: at)
        if followed { show(target, focusWindow: false, output: &output); focus(id, action: true, output: &output) }
        output.events.append(Event(type: "window_moved", data: .number(Double(id))))
    }

    mutating func setFloating(_ id: WindowID, value: Bool?, output: inout Output) throws {
        guard let window = state.windows[id] else { throw CommandError("Unknown window ID") }
        let enabled = value ?? !window.floating
        guard enabled || window.info.tileable else { throw CommandError("Window does not support tiling") }
        state.windows[id]?.floatingOverride = enabled
        updateFloating(id, value: enabled, output: &output)
    }

    mutating func hideWindow(_ id: WindowID, output: inout Output) {
        guard state.windows[id]?.hidden == false else { return }
        let at = location(id)
        state.windows[id]?.hiddenHome = at.map { state.displays[$0.display].workspaces[$0.workspace].home }
        removeFromPage(id)
        state.windows[id]?.hidden = true
        if state.focus == id {
            if let at { show(at, output: &output) }
            else { focus(nil, action: false, output: &output) }
        }
        output.events.append(Event(type: "window_moved", data: .number(Double(id))))
    }

    mutating func showWindow(_ id: WindowID, output: inout Output) throws {
        guard let window = state.windows[id] else { throw CommandError("Unknown window ID") }
        if window.hidden {
            guard let d = currentDisplay(), let start = currentLocation(display: d) else { throw CommandError("No managed display") }
            let at = place(id, at: start)
            show(at, focusWindow: false, output: &output)
            output.events.append(Event(type: "window_moved", data: .number(Double(id))))
        } else if let at = location(id) { show(at, focusWindow: false, output: &output) }
        focus(id, action: true, output: &output)
    }

    mutating func loadConfig(output: inout Output) {
        let focused = state.focus
        let oldPage = focused.flatMap(location).map { page($0).id }
        let removed = Set(state.windows.filter { !allows($0.value.info) }.keys)
        state.windows = state.windows.filter { !removed.contains($0.key) }
        for id in state.windows.keys {
            guard let window = state.windows[id] else { continue }
            let value = floating(window.info, override: window.floatingOverride)
            state.windows[id]?.floating = value
        }
        for d in state.displays.indices {
            for w in state.displays[d].workspaces.indices {
                for p in state.displays[d].workspaces[w].pages.indices {
                    state.displays[d].workspaces[w].pages[p].nativeLayout = nil
                    state.displays[d].workspaces[w].pages[p].windows.removeAll { removed.contains($0) }
                }
            }
        }
        output.events += removed.sorted().map { Event(type: "window_removed", data: .number(Double($0))) }
        output.events += repackOverflow().map { Event(type: "window_moved", data: .number(Double($0))) }
        if let focused, let at = location(focused), page(at).id != oldPage {
            show(at, focusWindow: false, output: &output)
            focus(focused, action: true, output: &output)
        } else if let focused, removed.contains(focused) {
            if let d = currentDisplay(), let at = currentLocation(display: d) { show(at, output: &output) }
            else { focus(nil, action: false, output: &output) }
        }
        output.events.append(Event(type: "config_reloaded"))
    }

    // Only overflow moves; each workspace's existing valid slots retain their pages.
    mutating func repackOverflow() -> [WindowID] {
        var moved: [WindowID] = []
        for d in state.displays.indices {
            for w in state.displays[d].workspaces.indices {
                var p = 0, consumed = 0
                var overflow: [WindowID] = []
                while p < state.displays[d].workspaces[w].pages.count || consumed < overflow.count {
                    if p == state.displays[d].workspaces[w].pages.count {
                        let page = PageState(id: nextSerial())
                        state.displays[d].workspaces[w].pages.append(page)
                    }
                    let at = Location(display: d, workspace: w, page: p)
                    let all = page(at).windows
                    var count = 0
                    state.displays[d].workspaces[w].pages[p].windows = all.filter { id in
                        if state.windows[id]?.floating == true { return true }
                        count += 1
                        if count > 4 { overflow.append(id); moved.append(id); return false }
                        return true
                    }
                    while count < 4 && consumed < overflow.count {
                        state.displays[d].workspaces[w].pages[p].windows.append(overflow[consumed])
                        consumed += 1
                        count += 1
                    }
                    if let last = page(at).lastFocus, !page(at).windows.contains(last) {
                        state.displays[d].workspaces[w].pages[p].lastFocus = nil
                    }
                    p += 1
                }
            }
        }
        return moved
    }
}
