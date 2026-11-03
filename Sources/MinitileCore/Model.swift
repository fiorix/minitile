import Foundation

struct Location: Equatable {
    var display: Int
    var workspace: Int
    var page: Int
    var slot: Int = 0
}

extension Engine {
    mutating func nextSerial() -> UInt64 { state.serial += 1; return state.serial }

    mutating func newWorkspace(home: DisplayID) -> WorkspaceState {
        let page = PageState(id: nextSerial())
        return WorkspaceState(id: nextSerial(), home: home, pages: [page], currentPage: page.id)
    }

    func displayIndex(_ id: DisplayID?) -> Int? {
        state.displays.firstIndex { $0.info.id == id }
    }

    func currentDisplay() -> Int? {
        if let id = state.focus, let window = state.windows[id], let d = displayIndex(window.display),
           state.displays[d].info.unmanagedReason == nil { return d }
        if let d = displayIndex(state.activeDisplay), state.displays[d].info.unmanagedReason == nil { return d }
        return state.displays.firstIndex { $0.info.isPrimary && $0.info.unmanagedReason == nil }
            ?? state.displays.firstIndex { $0.info.unmanagedReason == nil }
    }

    func currentLocation(display d: Int) -> Location? {
        let display = state.displays[d]
        guard let w = display.workspaces.firstIndex(where: { $0.id == display.currentWorkspace }),
              let p = display.workspaces[w].pages.firstIndex(where: { $0.id == display.workspaces[w].currentPage }) else { return nil }
        return Location(display: d, workspace: w, page: p)
    }

    func locations() -> [WindowID: Location] {
        var result: [WindowID: Location] = [:]
        for d in state.displays.indices {
            for w in state.displays[d].workspaces.indices {
                for p in state.displays[d].workspaces[w].pages.indices {
                    for (s, id) in state.displays[d].workspaces[w].pages[p].windows.enumerated() {
                        result[id] = Location(display: d, workspace: w, page: p, slot: s)
                    }
                }
            }
        }
        return result
    }

    func location(_ id: WindowID) -> Location? { locations()[id] }
    func page(_ at: Location) -> PageState { state.displays[at.display].workspaces[at.workspace].pages[at.page] }
    func isShown(_ at: Location) -> Bool {
        guard state.displays[at.display].info.unmanagedReason == nil else { return false }
        let current = currentLocation(display: at.display)
        return current?.workspace == at.workspace && current?.page == at.page
    }
    func canFocus(_ id: WindowID) -> Bool {
        guard let window = state.windows[id] else { return false }
        return !window.hidden && !window.info.minimized && !window.info.appHidden
    }
    func tiled(_ page: PageState, activeOnly: Bool = false) -> [WindowID] {
        page.windows.filter { id in
            guard let window = state.windows[id], !window.floating else { return false }
            return !activeOnly || (!window.info.minimized && !window.info.appHidden)
        }
    }

    mutating func place(_ id: WindowID, at start: Location) -> Location {
        var at = start
        if state.windows[id]?.floating != true {
            while at.page < state.displays[at.display].workspaces[at.workspace].pages.count,
                  tiled(page(at)).count >= 4 { at.page += 1 }
        }
        if at.page == state.displays[at.display].workspaces[at.workspace].pages.count {
            let created = PageState(id: nextSerial())
            state.displays[at.display].workspaces[at.workspace].pages.append(created)
        }
        at.slot = page(at).windows.count
        state.displays[at.display].workspaces[at.workspace].pages[at.page].windows.append(id)
        state.windows[id]?.display = state.displays[at.display].info.id
        state.windows[id]?.hidden = false
        return at
    }

    mutating func removeFromPage(_ id: WindowID) {
        guard let at = location(id) else { return }
        state.displays[at.display].workspaces[at.workspace].pages[at.page].windows.removeAll { $0 == id }
        if page(at).lastFocus == id { state.displays[at.display].workspaces[at.workspace].pages[at.page].lastFocus = nil }
    }

    mutating func focus(_ id: WindowID?, action: Bool, output: inout Output) {
        let previous = state.focus
        state.focus = id
        if let id, let at = location(id) {
            state.activeDisplay = state.displays[at.display].info.id
            let serial = nextSerial()
            state.windows[id]?.lastFocused = serial
            state.displays[at.display].workspaces[at.workspace].pages[at.page].lastFocus = id
            if action { output.actions.append(.focus(id)) }
        }
        if previous != id { output.events.append(Event(type: "focus", data: id.map { .number(Double($0)) } ?? .null)) }
    }

    mutating func show(_ at: Location, focusWindow: Bool = true, output: inout Output) {
        let changed = !isShown(at)
        let workspace = state.displays[at.display].workspaces[at.workspace]
        state.displays[at.display].currentWorkspace = workspace.id
        state.displays[at.display].workspaces[at.workspace].currentPage = workspace.pages[at.page].id
        state.activeDisplay = state.displays[at.display].info.id
        if changed {
            output.events.append(Event(type: "page_shown", data: .object([
                "display": .string(state.displays[at.display].info.id),
                "workspace": .number(Double(at.workspace + 1)), "page": .number(Double(at.page + 1)),
            ])))
        }
        if focusWindow {
            let page = page(at)
            let id = page.lastFocus.flatMap { page.windows.contains($0) && canFocus($0) ? $0 : nil }
                ?? page.windows.first(where: canFocus)
            focus(id, action: true, output: &output)
        }
    }

    mutating func appeared(_ info: WindowInfo, output: inout Output) {
        guard allows(info), state.windows[info.id] == nil,
              let d = displayIndex(info.display) ?? currentDisplay(),
              state.displays[d].info.unmanagedReason == nil,
              let start = currentLocation(display: d) else { return }
        state.windows[info.id] = WindowState(info: info, display: state.displays[d].info.id, floating: floating(info))
        let at = place(info.id, at: start)
        output.events.append(Event(type: "window_added", data: .number(Double(info.id))))
        if info.fromFrontmostApp {
            show(at, focusWindow: false, output: &output)
            focus(info.id, action: false, output: &output)
        }
    }

    mutating func gone(_ id: WindowID, output: inout Output) {
        guard state.windows[id] != nil else { return }
        let at = location(id)
        removeFromPage(id)
        state.windows.removeValue(forKey: id)
        output.events.append(Event(type: "window_removed", data: .number(Double(id))))
        if state.focus == id {
            if let at, isShown(at) { show(at, output: &output) }
            else { focus(nil, action: false, output: &output) }
        }
    }

    mutating func appActivated(_ pid: Int32, output: inout Output) {
        let positions = locations()
        let candidates = state.windows.values.filter { $0.info.pid == pid && !$0.hidden }
        if candidates.contains(where: { positions[$0.info.id].map(isShown) == true }) { return }
        let best = candidates.min {
            if $0.lastFocused != $1.lastFocused { return $0.lastFocused > $1.lastFocused }
            guard let a = positions[$0.info.id], let b = positions[$1.info.id] else { return $0.info.id < $1.info.id }
            return (a.display, a.workspace, a.page, a.slot) < (b.display, b.workspace, b.page, b.slot)
        }
        if let id = best?.info.id, let at = positions[id] { show(at, focusWindow: false, output: &output) }
    }

    mutating func navigatePage(_ delta: Int, output: inout Output) throws {
        guard let d = currentDisplay(), var at = currentLocation(display: d) else { throw CommandError("No managed display") }
        let pages = state.displays[d].workspaces[at.workspace].pages
        if at.page + delta < 0 { return }
        if at.page + delta >= pages.count {
            guard delta > 0, !page(at).windows.isEmpty else { return }
            let created = PageState(id: nextSerial())
            state.displays[d].workspaces[at.workspace].pages.append(created)
        }
        at.page += delta
        show(at, output: &output)
    }

    mutating func navigateWorkspace(_ delta: Int, alwaysNew: Bool = false, output: inout Output) throws {
        guard let d = currentDisplay(), var at = currentLocation(display: d) else { throw CommandError("No managed display") }
        let workspaces = state.displays[d].workspaces
        if at.workspace + delta < 0 { return }
        if alwaysNew || at.workspace + delta >= workspaces.count {
            guard workspaces[at.workspace].pages.contains(where: { !$0.windows.isEmpty }) else { return }
            let workspace = newWorkspace(home: state.displays[d].info.id)
            state.displays[d].workspaces.append(workspace)
            at.workspace = state.displays[d].workspaces.count - 1
        } else { at.workspace += delta }
        let target = state.displays[d].workspaces[at.workspace]
        at.page = target.pages.firstIndex { $0.id == target.currentPage } ?? 0
        show(at, output: &output)
    }

    mutating func cleanup() {
        for d in state.displays.indices {
            for w in state.displays[d].workspaces.indices {
                let viewed = state.displays[d].currentWorkspace == state.displays[d].workspaces[w].id
                let current = state.displays[d].workspaces[w].currentPage
                state.displays[d].workspaces[w].pages.removeAll { $0.windows.isEmpty && !(viewed && $0.id == current) }
                if !state.displays[d].workspaces[w].pages.contains(where: { $0.id == current }),
                   let first = state.displays[d].workspaces[w].pages.first {
                    state.displays[d].workspaces[w].currentPage = first.id
                }
            }
            state.displays[d].workspaces.removeAll { $0.pages.isEmpty }
            if !state.displays[d].workspaces.contains(where: { $0.id == state.displays[d].currentWorkspace }) {
                state.displays[d].currentWorkspace = state.displays[d].workspaces.first?.id
            }
        }
    }

    func makeScene() -> Scene {
        var scene = Scene()
        for (d, display) in state.displays.enumerated() where display.info.unmanagedReason == nil {
            var result = DisplayScene()
            if let current = currentLocation(display: d) { result.label = "\(current.workspace + 1):\(current.page + 1)" }
            for (w, workspace) in display.workspaces.enumerated() {
                for (p, page) in workspace.pages.enumerated() {
                    let at = Location(display: d, workspace: w, page: p)
                    result.frames.merge(frames(at)) { _, new in new }
                    if isShown(at) { result.visible += page.windows }
                    else { result.stashed += page.windows }
                }
            }
            scene.displays[display.info.id] = result
        }
        for (id, window) in state.windows where window.hidden { scene.displays[window.display]?.stashed.append(id) }
        for id in scene.displays.keys { scene.displays[id]?.stashed.sort() }
        return scene
    }
}
