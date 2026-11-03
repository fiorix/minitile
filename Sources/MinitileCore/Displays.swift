import Foundation

extension Engine {
    mutating func changeDisplays(_ infos: [DisplayInfo], output: inout Output) {
        let old = state.displays
        let oldFocusDisplay = state.focus.flatMap { state.windows[$0]?.display } ?? state.activeDisplay
        for display in old {
            if let viewed = display.currentWorkspace { state.displayViews[display.info.id] = viewed }
        }
        var seen = Set<DisplayID>()
        var updated: [DisplayState] = infos.filter { seen.insert($0.id).inserted }.map { info in
            var display = old.first { $0.info.id == info.id } ?? DisplayState(info: info)
            display.info = info
            return display
        }
        let primary = updated.firstIndex { $0.info.isPrimary && $0.info.unmanagedReason == nil }
            ?? updated.firstIndex { $0.info.unmanagedReason == nil }
        var hostChanges: [DisplayID: DisplayID] = [:]
        for var missing in old where !seen.contains(missing.info.id) {
            if let primary {
                updated[primary].workspaces += missing.workspaces
                hostChanges[missing.info.id] = updated[primary].info.id
            } else {
                missing.info.unmanagedReason = "Display disconnected"
                updated.append(missing)
            }
        }
        let destinations = Dictionary(uniqueKeysWithValues: updated.enumerated().compactMap { index, display in
            display.info.unmanagedReason == nil ? (display.info.id, index) : nil
        })
        var returning: [(Int, WorkspaceState)] = []
        var focusAfter: DisplayID?
        for d in updated.indices {
            let original = updated[d].workspaces
            let leaving = Set(original.filter { destinations[$0.home] != nil && destinations[$0.home] != d }.map(\.id))
            if let viewed = updated[d].currentWorkspace, leaving.contains(viewed),
               let index = original.firstIndex(where: { $0.id == viewed }) {
                updated[d].currentWorkspace = original[..<index].last(where: { !leaving.contains($0.id) })?.id
                    ?? original.first(where: { !leaving.contains($0.id) })?.id
                if oldFocusDisplay == updated[d].info.id { focusAfter = updated[d].info.id }
            }
            updated[d].workspaces.removeAll { workspace in
                guard let target = destinations[workspace.home], target != d else { return false }
                returning.append((target, workspace))
                return true
            }
        }
        for (d, workspace) in returning { updated[d].workspaces.append(workspace) }
        for d in updated.indices where updated[d].info.unmanagedReason == nil {
            if updated[d].workspaces.isEmpty {
                let workspace = newWorkspace(home: updated[d].info.id)
                updated[d].workspaces = [workspace]
            }
            if !updated[d].workspaces.contains(where: { $0.id == updated[d].currentWorkspace }) {
                let remembered = state.displayViews[updated[d].info.id]
                updated[d].currentWorkspace = updated[d].workspaces.first(where: { $0.id == remembered })?.id
                    ?? updated[d].workspaces.first?.id
            }
        }
        state.displays = updated
        for (id, at) in locations() { state.windows[id]?.display = updated[at.display].info.id }
        for id in state.windows.keys {
            guard let window = state.windows[id], window.hidden else { continue }
            if let home = window.hiddenHome, destinations[home] != nil { state.windows[id]?.display = home }
            else if let host = hostChanges[window.display] { state.windows[id]?.display = host }
        }
        if let active = state.activeDisplay, let host = hostChanges[active] { state.activeDisplay = host }
        if let focusAfter, let d = displayIndex(focusAfter), let at = currentLocation(display: d) { show(at, output: &output) }
        output.events.append(Event(type: "display_changed", data: (try? .encoding(infos)) ?? .null))
    }
}
