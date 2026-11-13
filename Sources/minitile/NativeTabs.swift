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
    /// The window waiting to replace the selection, while that is undecided.
    var settling: WindowID? { pending?.id }

    init(_ selected: WindowID) { self.selected = selected }

    mutating func select(_ id: WindowID, now: TimeInterval, previousInactive: Bool) -> Change? {
        guard id != selected else { pending = nil; return nil }
        if previousInactive {
            let previous = selected
            selected = id
            pending = nil
            return .selected(previous: previous)
        }
        let until = pending.flatMap { $0.id == id ? $0.until : nil } ?? now + 0.15
        pending = (id, until)
        guard now >= until else { return .waiting }
        selected = id
        pending = nil
        return .detached
    }
}

/// Each app's last focused window that discovery knows: the one whose slot a new tab may take. A window focused
/// before it is discovered takes that place only when it is discovered, after its own tab selection was decided, so
/// a new tab never names itself and a window opened a moment ago still counts.
struct FocusMemory {
    private var known: [Int32: WindowID] = [:]
    private var awaited: [Int32: WindowID] = [:]

    func last(pid: Int32) -> WindowID? { known[pid] }

    mutating func focused(_ id: WindowID, pid: Int32, discovered: Bool) {
        if discovered { known[pid] = id; awaited[pid] = nil } else { awaited[pid] = id }
    }

    mutating func discovered(_ id: WindowID, pid: Int32) {
        guard awaited[pid] == id else { return }
        known[pid] = id
        awaited[pid] = nil
    }

    mutating func forget(pid: Int32) { known[pid] = nil; awaited[pid] = nil }
}

/// Resize bursts need one tab probe after the last event, while echoes of minitile's frame writes need none.
struct ResizeTabReads {
    static let interval: TimeInterval = 0.05
    enum Action: Equatable {
        case none
        case wait(TimeInterval)
        case read
    }
    private var deadlines: [WindowID: TimeInterval] = [:]

    /// True when the window needs its first timer; later events extend that timer's deadline.
    mutating func request(_ id: WindowID, now: TimeInterval, suppressed: Bool) -> Bool {
        guard !suppressed else { return false }
        let scheduled = deadlines[id] != nil
        deadlines[id] = now + Self.interval
        return !scheduled
    }

    mutating func fired(_ id: WindowID, now: TimeInterval, suppressed: Bool) -> Action {
        guard let deadline = deadlines[id] else { return .none }
        if suppressed { deadlines.removeValue(forKey: id); return .none }
        guard now >= deadline else { return .wait(deadline - now) }
        deadlines.removeValue(forKey: id)
        return .read
    }

    mutating func forget(_ id: WindowID) { deadlines.removeValue(forKey: id) }
}

/// AppKit moves the same accessibility tab bar between the group's selected windows. Its identity survives a
/// selection even though the window ID changes. Window titles and frames do not identify a tab group.
@MainActor
struct NativeTabs {
    struct Selection {
        var previous: WindowID?
        var waiting = false
        var leftBehind = false

        /// AX focus can lag behind an ordinary new window, but a tab left by a detach follows the reappearance rule.
        func takesFocus(_ id: WindowID, active: Bool, focus: () -> FocusObservation) -> Bool {
            guard active else { return false }
            return !leftBehind || OrderedOutChecks.takesFocus(id, active: active, focus: focus())
        }
    }
    private struct Group {
        var element: AXRef
        var pid: Int32
        var selection: TabSelection
        var members: Set<WindowID>
        /// A selection observed with this bar or confirmed by a tab switch. Prior focus alone is only a candidate.
        var established: Bool
        /// The bar owner named as the selection's successor, and how often.
        var prompted: (owner: WindowID, count: Int)?
    }

    /// How often one window is named as a selection's successor before the periodic scan is left to read it.
    static let successorPrompts = 3
    private var groups: [Group] = []
    /// The window a tab bar currently belongs to, or nil once the bar is gone.
    var owner: (AXRef) -> WindowID? = { AX.id($0.element) }

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
        if group == nil, let index = groups.firstIndex(where: {
            $0.pid == pid && $0.selection.selected == id && $0.members == [id] && $0.selection.settling == nil
        }), owner(groups[index].element) == nil {
            groups.remove(at: index)
            return nil
        }
        if group == nil, !inactive(id) {
            // A window shown without the bar, while the bar stays on another shown window, was detached.
            for index in groups.indices where groups[index].pid == pid && groups[index].selection.selected != id {
                if let current = owner(groups[index].element), current != id, !inactive(current) {
                    groups[index].members.remove(id)
                }
            }
        }
        let index = groups.firstIndex { entry in
            guard entry.pid == pid else { return false }
            if let group { return CFEqual(entry.element.element, group.element) }
            if owner(entry.element) == id { return true }
            // A bar that is gone left with a closed selection or with a split of its last two tabs. WindowServer
            // drops a closed selection a moment after the other window shows, so the selection settles that too.
            return entry.members.contains(id) && !inactive(id)
                && (owner(entry.element) == nil || inactive(entry.selection.selected))
        }
        guard let index else {
            if let group {
                let previous = previousFocus.flatMap { $0 == id ? nil : $0 }
                groups.removeAll { entry in
                    entry.pid == pid && owner(entry.element) == nil
                        && (entry.members.contains(id) || previous.map(entry.members.contains) == true)
                }
                groups.append(Group(element: group, pid: pid, selection: TabSelection(previous ?? id),
                                    members: Set([id] + (previous.map { [$0] } ?? [])), established: previous == nil))
                if previous != nil {
                    return select(id, pid: pid, group: group, previousFocus: nil, now: now, inactive: inactive)
                }
                return Selection()
            }
            return nil
        }
        let previous = groups[index].selection.selected
        // Without a bar, the selected window says nothing about a window waiting to replace it.
        if group == nil, previous == id { return nil }
        switch groups[index].selection.select(id, now: now, previousInactive: previous != id && inactive(previous)) {
        case .waiting: return Selection(waiting: true)
        case .selected(let previous):
            groups[index].members.insert(id)
            groups[index].established = true
            groups[index].prompted = nil
            return Selection(previous: previous)
        case .detached:
            let current = owner(groups[index].element)
            let leftBehind = groups[index].established && (group != nil || current == id)
            if current == nil {
                // Two windows that both stay without a bar are independent, and so is every other tab they had.
                groups.remove(at: index)
            } else {
                groups[index].members.remove(previous)
                groups[index].members.insert(id)
                groups[index].established = true
                groups[index].prompted = nil
            }
            return Selection(leftBehind: leftBehind)
        case nil:
            if group != nil { groups[index].established = true }
            return nil
        }
    }

    /// The window that took the bar from `id`, a group's recorded selection that now stands without it, as the
    /// selected tab does once it is detached from three or more. No notification reads that window's tabs, so
    /// discovery rereads it and its selection settles. Each owner is named `successorPrompts` times at most: an app
    /// whose accessibility tree never agrees with itself costs that many rereads and then waits for the scan.
    mutating func successor(of id: WindowID, pid: Int32) -> WindowID? {
        for index in groups.indices where groups[index].pid == pid && groups[index].selection.selected == id {
            guard let current = owner(groups[index].element), current != id else { continue }
            let count = groups[index].prompted.flatMap { $0.owner == current ? $0.count : nil } ?? 0
            guard count < Self.successorPrompts else { continue }
            groups[index].prompted = (current, count + 1)
            return current
        }
        return nil
    }

    func changing(pids: Set<Int32>, answers: (Int32) -> Bool) -> Set<WindowID> {
        var ids: Set<WindowID> = []
        for group in groups where pids.contains(group.pid) {
            if let settling = group.selection.settling { ids.formUnion([group.selection.selected, settling]) }
            guard answers(group.pid) else { continue }
            guard let current = owner(group.element), current != group.selection.selected else { continue }
            ids.formUnion([group.selection.selected, current])
        }
        return ids
    }

    /// A closed selection ends its group. Any other closed tab leaves it, so a reused window ID never inherits a slot.
    mutating func forget(_ id: WindowID) {
        groups.removeAll { $0.selection.selected == id }
        for index in groups.indices { groups[index].members.remove(id) }
    }
    mutating func forget(pid: Int32) { groups.removeAll { $0.pid == pid } }
}
