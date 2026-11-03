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
        updateFloating(info.id, value: floating(info, override: old.floatingOverride), output: &output)
        if old.info.minimized && !info.minimized, let at = location(info.id) {
            show(at, focusWindow: false, output: &output)
            focus(info.id, action: true, output: &output)
        } else if state.focus == info.id && (info.minimized || info.appHidden), let at = location(info.id) {
            show(at, output: &output)
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

    mutating func loadConfig(_ config: Config, output: inout Output) {
        for id in state.windows.keys.sorted() {
            guard let window = state.windows[id] else { continue }
            if !allows(window.info) { gone(id, output: &output) }
            else { updateFloating(id, value: floating(window.info, override: window.floatingOverride), output: &output) }
        }
        output.events.append(Event(type: "config_reloaded"))
    }
}
