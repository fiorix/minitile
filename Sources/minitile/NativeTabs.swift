import AppKit
import MinitileCore

/// AppKit changes the tab bar's owner before WindowServer orders out the old selection. Keep that selection until
/// it disappears; if both windows remain independent after the short settling interval, a tab was detached.
struct TabSelection {
    enum Change: Equatable {
        case waiting
        case selected(previous: WindowID)
        case detached
    }

    private(set) var selected: WindowID
    private var pending: (id: WindowID, until: TimeInterval)?

    init(_ selected: WindowID) { self.selected = selected }

    mutating func select(_ id: WindowID, now: TimeInterval, previousInactive: Bool) -> Change? {
        guard id != selected else { pending = nil; return nil }
        if previousInactive {
            let previous = selected
            selected = id
            pending = nil
            return .selected(previous: previous)
        }
        if pending?.id != id { pending = (id, now + 0.15) }
        guard now >= pending!.until else { return .waiting }
        selected = id
        pending = nil
        return .detached
    }
}

/// AppKit moves the same accessibility tab bar between the group's selected windows. Its identity survives a
/// selection even though the window ID changes. Window titles and frames do not identify a tab group.
@MainActor
struct NativeTabs {
    struct Selection {
        var previous: WindowID?
        var waiting = false
    }
    private struct Group {
        var element: AXRef
        var pid: Int32
        var selection: TabSelection
        var members: Set<WindowID>
    }

    private var groups: [Group] = []

    func hasGroups(pid: Int32) -> Bool { groups.contains { $0.pid == pid } }

    nonisolated static func group(_ window: AXUIElement) -> AXRef? {
        for child in AX.value(window, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            guard AX.value(child, kAXRoleAttribute) as? String == kAXTabGroupRole,
                  let tabs = AX.value(child, kAXTabsAttribute) as? [AXUIElement], let tab = tabs.first,
                  AX.value(tab, kAXSubroleAttribute) as? String == "AXTabButton" else { continue }
            return AXRef(child)
        }
        return nil
    }

    /// The bar identifies an existing group. A new tab can establish its first group from the previous focus only
    /// once that window leaves all Spaces. Known membership survives closing the bar with its penultimate tab.
    mutating func select(_ id: WindowID, pid: Int32, group: AXRef?, previousFocus: WindowID?, now: TimeInterval,
                         inactive: (WindowID) -> Bool) -> Selection? {
        guard group != nil || hasGroups(pid: pid) else { return nil }
        if group == nil, !inactive(id) {
            // An invalid bar with two surviving independent windows belongs to a dissolved group.
            groups.removeAll { entry in
                entry.pid == pid && entry.members.contains(id) && AX.id(entry.element.element) == nil
                    && entry.members.contains { $0 != id && !inactive($0) }
            }
            for index in groups.indices where groups[index].pid == pid && groups[index].selection.selected != id {
                if let current = AX.id(groups[index].element.element), current != id, !inactive(current) {
                    groups[index].members.remove(id)
                }
            }
        }
        let index = groups.firstIndex { entry in
            guard entry.pid == pid else { return false }
            if let group { return CFEqual(entry.element.element, group.element) }
            if AX.id(entry.element.element) == id { return true }
            return entry.members.contains(id) && !inactive(id) && inactive(entry.selection.selected)
        }
        guard let index else {
            if let group {
                let previous = previousFocus.flatMap { $0 == id ? nil : $0 }
                groups.removeAll { entry in
                    entry.pid == pid && AX.id(entry.element.element) == nil
                        && (entry.members.contains(id) || previous.map(entry.members.contains) == true)
                }
                groups.append(Group(element: group, pid: pid, selection: TabSelection(previous ?? id),
                                    members: Set([id] + (previous.map { [$0] } ?? []))))
                if previous != nil {
                    return select(id, pid: pid, group: group, previousFocus: nil, now: now, inactive: inactive)
                }
                return Selection()
            }
            return nil
        }
        let previous = groups[index].selection.selected
        switch groups[index].selection.select(id, now: now, previousInactive: previous != id && inactive(previous)) {
        case .waiting: return Selection(waiting: true)
        case .selected(let previous):
            groups[index].members.insert(id)
            return Selection(previous: previous)
        case .detached:
            groups[index].members.remove(previous)
            groups[index].members.insert(id)
            return Selection()
        case nil: return nil
        }
    }

    var changing: Set<WindowID> {
        var ids: Set<WindowID> = []
        for group in groups {
            guard let current = AX.id(group.element.element), current != group.selection.selected else { continue }
            ids.formUnion([group.selection.selected, current])
        }
        return ids
    }

    mutating func forget(_ id: WindowID) { groups.removeAll { $0.selection.selected == id } }
    mutating func forget(pid: Int32) { groups.removeAll { $0.pid == pid } }
}
