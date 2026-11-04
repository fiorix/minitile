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
        else if let id = state.focus, let at = location(id), !isShown(at) {
            if state.displays[at.display].info.unmanagedReason == nil, let current = currentLocation(display: at.display) {
                show(current, output: &output)
            } else { focus(nil, action: false, output: &output) }
        }
        output.events.append(Event(type: "display_changed", data: (try? .encoding(infos)) ?? .null))
    }

    /// The managed display on one side of display `d`, the side a unit step (dx, dy) points to: its facing edge lies
    /// on `d`'s edge within 1 pt and the two edges overlap. The longest overlap wins, then the nearest centre. An
    /// unmanaged display has no neighbours.
    func neighbour(of d: Int, dx: Int, dy: Int) -> Int? {
        guard state.displays[d].info.unmanagedReason == nil else { return nil }
        let frame = state.displays[d].info.frame
        var best: (display: Int, overlap: Double, distance: Double)?
        for (e, display) in state.displays.enumerated() where e != d && display.info.unmanagedReason == nil {
            let other = display.info.frame
            let gap = dx > 0 ? other.x - frame.maxX : dx < 0 ? frame.x - other.maxX : dy > 0 ? other.y - frame.maxY : frame.y - other.maxY
            let overlap = dx != 0 ? min(frame.maxY, other.maxY) - max(frame.y, other.y)
                : min(frame.maxX, other.maxX) - max(frame.x, other.x)
            guard abs(gap) <= 1, overlap > 0 else { continue }
            let x = other.center.x - frame.center.x, y = other.center.y - frame.center.y
            let distance = x * x + y * y
            if best.map({ overlap > $0.overlap || (overlap == $0.overlap && distance < $0.distance) }) ?? true {
                best = (e, overlap, distance)
            }
        }
        return best?.display
    }
}
