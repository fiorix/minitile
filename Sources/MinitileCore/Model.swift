import Foundation

struct Location: Equatable {
    var display: Int
    var workspace: Int
    var page: Int
    var slot: Int = 0
    var tiledSlot: Int?
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
                    var tile = 0
                    for (s, id) in state.displays[d].workspaces[w].pages[p].windows.enumerated() {
                        let floats = state.windows[id]?.floating == true
                        result[id] = Location(display: d, workspace: w, page: p, slot: s, tiledSlot: floats ? nil : tile)
                        if !floats { tile += 1 }
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
        state.windows[id]?.hiddenHome = nil
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
        if let old = state.windows[info.id], old.info.pid != info.pid { gone(info.id, output: &output) }
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
        removeFromPage(id)
        state.windows.removeValue(forKey: id)
        output.events.append(Event(type: "window_removed", data: .number(Double(id))))
        if state.focus == id {
            focus(nil, action: false, output: &output)
        }
    }

    mutating func appActivated(_ pid: Int32, output: inout Output) {
        let positions = locations()
        let candidates = state.windows.values.filter { $0.info.pid == pid && !$0.hidden && !$0.info.minimized }
        if candidates.contains(where: { positions[$0.info.id].map(isShown) == true }) { return }
        let best = candidates.min {
            if $0.lastFocused != $1.lastFocused { return $0.lastFocused > $1.lastFocused }
            guard let a = positions[$0.info.id], let b = positions[$1.info.id] else { return $0.info.id < $1.info.id }
            return (a.display, a.workspace, a.page, a.slot) < (b.display, b.workspace, b.page, b.slot)
        }
        if let id = best?.info.id, let at = positions[id] { show(at, focusWindow: false, output: &output) }
    }

    /// Without an explicit `display`, navigation past the edge of the grid crosses to the display on that side.
    mutating func navigatePage(_ delta: Int, display: Int? = nil, output: inout Output) throws {
        guard let d = display ?? currentDisplay(), var at = currentLocation(display: d) else { throw CommandError("No managed display") }
        let pages = state.displays[d].workspaces[at.workspace].pages
        if at.page + delta < 0 || (at.page + delta >= pages.count && page(at).windows.isEmpty) {
            if display == nil { cross(from: d, dx: delta, dy: 0, output: &output) }
            return
        }
        if at.page + delta >= pages.count {
            let created = PageState(id: nextSerial())
            state.displays[d].workspaces[at.workspace].pages.append(created)
        }
        at.page += delta
        show(at, output: &output)
    }

    mutating func navigateWorkspace(_ delta: Int, display: Int? = nil, alwaysNew: Bool = false, output: inout Output) throws {
        guard let d = display ?? currentDisplay(), var at = currentLocation(display: d) else { throw CommandError("No managed display") }
        let workspaces = state.displays[d].workspaces
        let empty = !workspaces[at.workspace].pages.contains(where: { !$0.windows.isEmpty })
        if !alwaysNew, at.workspace + delta < 0 || (at.workspace + delta >= workspaces.count && empty) {
            if display == nil { cross(from: d, dx: 0, dy: delta, output: &output) }
            return
        }
        if alwaysNew || at.workspace + delta >= workspaces.count {
            guard !empty else { return }
            let workspace = newWorkspace(home: state.displays[d].info.id)
            state.displays[d].workspaces.append(workspace)
            at.workspace = state.displays[d].workspaces.count - 1
            at.page = 0
        } else {
            // Moving up or down the grid keeps the page position. The open slot just past a shorter workspace's last
            // page gets an empty page, as Ctrl+Right from that page would; further out, the last page is shown.
            at.workspace += delta
            let pages = state.displays[d].workspaces[at.workspace].pages
            if at.page == pages.count, pages.last.map({ !$0.windows.isEmpty }) == true {
                state.displays[d].workspaces[at.workspace].pages.append(PageState(id: nextSerial()))
            } else {
                at.page = min(at.page, pages.count - 1)
            }
        }
        show(at, output: &output)
    }

    /// Crosses from display `d` to the display on the side a unit step (dx, dy) points to, if there is one. That
    /// display becomes active and keeps its shown page, whose last focused window, or first, gets focus.
    mutating func cross(from d: Int, dx: Int, dy: Int, output: inout Output) {
        guard let e = neighbour(of: d, dx: dx, dy: dy), let at = currentLocation(display: e) else { return }
        leave(d, output: &output)
        show(at, output: &output)
    }

    /// A display that a crossing leaves showing an empty page shows the nearest page instead, and cleanup drops the
    /// empty one: the page before it, else the page after it, else the page last viewed in the workspace above, else
    /// the one below. Focus is left to the display crossed into, which must be shown after this.
    mutating func leave(_ d: Int, output: inout Output) {
        guard let at = currentLocation(display: d), page(at).windows.isEmpty else { return }
        let workspaces = state.displays[d].workspaces
        var target = at
        if workspaces[at.workspace].pages.count > 1 {
            target.page = at.page > 0 ? at.page - 1 : at.page + 1
        } else if let w = [at.workspace - 1, at.workspace + 1].first(where: workspaces.indices.contains) {
            target.workspace = w
            target.page = workspaces[w].pages.firstIndex { $0.id == workspaces[w].currentPage } ?? 0
        } else { return }
        show(target, focusWindow: false, output: &output)
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
