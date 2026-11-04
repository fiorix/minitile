import Foundation

extension Engine {
    mutating func move(_ id: WindowID, to target: Location, output: inout Output) {
        removeFromPage(id)
        let at = place(id, at: target)
        show(at, focusWindow: false, output: &output)
        focus(id, action: true, output: &output)
        output.events.append(Event(type: "window_moved", data: .number(Double(id))))
    }

    mutating func nudge(_ id: WindowID, direction: Int, output: inout Output) throws {
        guard let at = location(id) else { throw CommandError("Window must belong to a page") }
        if page(at).windows.count > 1 {
            removeFromPage(id)
            let created = PageState(id: nextSerial())
            let index = at.page + (direction > 0 ? 1 : 0)
            state.displays[at.display].workspaces[at.workspace].pages.insert(created, at: index)
            var target = at
            target.page = index
            move(id, to: target, output: &output)
        } else {
            let pages = state.displays[at.display].workspaces[at.workspace].pages
            var index = at.page + direction
            guard pages.indices.contains(index) else { return }
            while pages.indices.contains(index), state.windows[id]?.floating != true, tiled(pages[index]).count >= 4 {
                index += direction
            }
            if !pages.indices.contains(index) {
                index = direction < 0 ? 0 : pages.count
                let created = PageState(id: nextSerial())
                state.displays[at.display].workspaces[at.workspace].pages.insert(created, at: index)
            }
            var target = at
            target.page = index
            move(id, to: target, output: &output)
        }
    }

    mutating func moveTarget(_ id: WindowID, noun: String, address: String, output: inout Output) throws {
        guard let d = state.windows[id].flatMap({ displayIndex($0.display) }),
              var target = currentLocation(display: d) else { throw CommandError("No managed display") }
        if let source = location(id) { target = source }
        switch noun {
        case "page":
            let pages = state.displays[d].workspaces[target.workspace].pages
            let index = try addressedIndex(address, current: target.page, count: pages.count, allowNext: true)
            if index == pages.count {
                let created = PageState(id: nextSerial())
                state.displays[d].workspaces[target.workspace].pages.append(created)
            }
            target.page = index
        case "workspace":
            let workspaces = state.displays[d].workspaces
            let index = try addressedIndex(address, current: target.workspace, count: workspaces.count, allowNext: true)
            if index == workspaces.count {
                let created = newWorkspace(home: state.displays[d].info.id)
                state.displays[d].workspaces.append(created)
            }
            target.workspace = index
            let workspace = state.displays[d].workspaces[index]
            target.page = workspace.pages.firstIndex { $0.id == workspace.currentPage } ?? 0
        case "display":
            let destination: Int
            if address == "next" || address == "prev" {
                let managed = state.displays.indices.filter { state.displays[$0].info.unmanagedReason == nil }
                guard let current = managed.firstIndex(of: d) else { throw CommandError("No managed display") }
                let i = try addressedIndex(address, current: current, count: managed.count)
                destination = managed[i]
            } else {
                guard let found = displayIndex(address), state.displays[found].info.unmanagedReason == nil else {
                    throw CommandError("Expected a managed display UUID, next or prev")
                }
                destination = found
            }
            guard let at = currentLocation(display: destination) else { throw CommandError("Display has no workspace") }
            target = at
        default: throw CommandError("Expected page, workspace or display target")
        }
        if let source = location(id), source.display == target.display,
           source.workspace == target.workspace, source.page == target.page { return }
        move(id, to: target, output: &output)
    }

    func addressedIndex(_ address: String, current: Int, count: Int, allowNext: Bool = false) throws -> Int {
        if address == "prev" { return max(0, current - 1) }
        if address == "next" { return min(current + 1, allowNext ? count : count - 1) }
        guard let number = Int(address), number >= 1, number <= count else {
            throw CommandError("Expected an index in 1...\(count), next or prev")
        }
        return number - 1
    }

    mutating func swap(_ first: WindowID, _ second: WindowID, follow: Bool = true, output: inout Output) throws {
        guard let a = location(first), let b = location(second),
              state.windows[first]?.floating == false, state.windows[second]?.floating == false else {
            throw CommandError("Expected two tiled windows")
        }
        guard first != second else { return }
        state.displays[a.display].workspaces[a.workspace].pages[a.page].windows[a.slot] = second
        state.displays[b.display].workspaces[b.workspace].pages[b.page].windows[b.slot] = first
        state.windows[first]?.display = state.displays[b.display].info.id
        state.windows[second]?.display = state.displays[a.display].info.id
        if a.display != b.display || a.workspace != b.workspace || a.page != b.page {
            if page(a).lastFocus == first { state.displays[a.display].workspaces[a.workspace].pages[a.page].lastFocus = nil }
            if page(b).lastFocus == second { state.displays[b.display].workspaces[b.workspace].pages[b.page].lastFocus = nil }
        }
        if follow { show(b, focusWindow: false, output: &output); focus(first, action: true, output: &output) }
        output.events += [Event(type: "window_moved", data: .number(Double(first))), Event(type: "window_moved", data: .number(Double(second)))]
    }

    mutating func resize(_ id: WindowID, size: String, output: inout Output) throws {
        let parts = size.split(separator: "x", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = Double(parts[0]), first.isFinite, first > 0,
              parts.count == 1 || (Double(parts[1]).map { $0.isFinite && $0 > 0 } == true) else {
            throw CommandError("Expected a positive share or WIDTHxHEIGHT")
        }
        let second = parts.count == 2 ? Double(parts[1])! : nil
        guard let window = state.windows[id] else { throw CommandError("Unknown window") }
        if window.floating {
            guard let second else { throw CommandError("Floating size requires WIDTHxHEIGHT in points") }
            var frame = window.info.frame
            frame.width = max(1, first.rounded()); frame.height = max(1, second.rounded())
            state.windows[id]?.info.frame = frame
            output.actions.append(.setFrame(id, frame))
            return
        }
        guard let (at, tile) = activeTile(id) else { throw CommandError("Window has no active tile") }
        let p = page(at)
        let landscape = isLandscape(at)
        // A single share applies along the axis r1 cuts, the layout's split axis.
        let splitLong = Layout.tiles(count: tiled(p, activeOnly: true).count, variant: p.variant)
            .contains { $0.long.start == 0 || $0.long.end == 0 }
        let shares: [(long: Bool, share: Double)] = second.map { [(true, landscape ? first : $0), (false, landscape ? $0 : first)] }
            ?? [(splitLong, first)]
        var cuts = [p.r1, p.r2], changed = [false, false]
        for (long, share) in shares {
            let span = tile.span(long: long)
            switch (span.start, span.end) {
            case (nil, let end?): cuts[end] = share; changed[end] = true
            case (let start?, nil): cuts[start] = 1 - share; changed[start] = true
            // The middle of three slices keeps its end cut and moves its start cut.
            case (let start?, let end?): cuts[start] = cuts[end] - share; changed[start] = true
            case (nil, nil): break
            }
        }
        setRatios(at, cuts[0], cuts[1], preserveFirst: !changed[0], preserveSecond: !changed[1])
        output.rewrite.insert(id)
    }

    /// Moves the cut on the arrow's side of the window, or the one on the opposite side when the arrow's side lies on the
    /// layout area's border, by 0.05 in the arrow's direction. A floating window changes its width or height instead.
    mutating func resizeStep(_ id: WindowID, direction: String, output: inout Output) throws {
        guard let window = state.windows[id] else { throw CommandError("Unknown window") }
        let horizontal = direction == "left" || direction == "right"
        let forward = direction == "right" || direction == "down"
        if window.floating {
            guard let d = displayIndex(window.display) else { throw CommandError("Window has no display") }
            let area = Layout.area(frame: state.displays[d].info.visibleFrame, padding: config.padding)
            var frame = window.info.frame
            let (origin, size) = horizontal ? (frame.x, frame.width) : (frame.y, frame.height)
            let (start, length) = horizontal ? (area.x, area.width) : (area.y, area.height)
            // Grows until its far edge reaches the layout area's and shrinks to a fifth of the area; past a limit it stays.
            let target = forward ? min(size + 0.05 * length, max(size, start + length - origin))
                : max(size - 0.05 * length, min(size, 0.2 * length))
            guard target.rounded() != size else { return }
            if horizontal { frame.width = target.rounded() } else { frame.height = target.rounded() }
            state.windows[id]?.info.frame = frame
            output.actions.append(.setFrame(id, frame))
            return
        }
        guard let (at, tile) = activeTile(id) else { throw CommandError("Window has no active tile") }
        let span = tile.span(long: horizontal == isLandscape(at))
        guard let cut = (forward ? span.end : span.start) ?? (forward ? span.start : span.end) else { return }
        var cuts = [page(at).r1, page(at).r2]
        cuts[cut] += forward ? 0.05 : -0.05
        setRatios(at, cuts[0], cuts[1], preserveFirst: cut != 0, preserveSecond: cut != 1)
    }

    mutating func resizeCuts(_ id: WindowID, at: Location, frame: Rect) {
        guard let original = frames(at)[id], let (_, tile) = activeTile(id) else { return }
        let p = page(at)
        let area = Layout.area(frame: state.displays[at.display].info.visibleFrame, padding: config.padding)
        let landscape = isLandscape(at)
        var cuts = [p.r1, p.r2], changed = [false, false]
        for x in [true, false] {
            let origin = x ? area.x : area.y
            let length = x ? area.width : area.height
            guard length > 0 else { continue }
            let span = tile.span(long: x == landscape)
            // Tile edges sit half a gap from their cut.
            let edges: [(Int?, Double, Double, Double)] = x
                ? [(span.start, original.x, frame.x, -config.gaps / 2), (span.end, original.maxX, frame.maxX, config.gaps / 2)]
                : [(span.start, original.y, frame.y, -config.gaps / 2), (span.end, original.maxY, frame.maxY, config.gaps / 2)]
            for case let (cut?, old, new, correction) in edges where abs(old - new) > 3 {
                cuts[cut] = (new + correction - origin) / length
                changed[cut] = true
            }
        }
        setRatios(at, cuts[0], cuts[1], preserveFirst: !changed[0], preserveSecond: !changed[1])
    }

    /// The window's page and its tile in the layout, for a tiled window that is neither minimized nor app-hidden.
    func activeTile(_ id: WindowID) -> (Location, Layout.Tile)? {
        guard state.windows[id]?.floating == false, let at = location(id) else { return nil }
        let active = tiled(page(at), activeOnly: true)
        guard let slot = active.firstIndex(of: id) else { return nil }
        return (at, Layout.tiles(count: active.count, variant: page(at).variant)[slot])
    }

    /// A square visible frame counts as landscape, as in `Layout.frames`.
    func isLandscape(_ at: Location) -> Bool {
        let display = state.displays[at.display].info.visibleFrame
        return display.width >= display.height
    }

    mutating func dragEnded(_ id: WindowID, frame: Rect, cursor: Point, output: inout Output) {
        guard let window = state.windows[id], let at = location(id) else { return }
        if window.floating { state.windows[id]?.info.frame = frame; return }
        guard let original = frames(at)[id] else { return }
        if abs(frame.width - original.width) <= 3 && abs(frame.height - original.height) <= 3 {
            let targets = frames(at)
            if let other = page(at).windows.first(where: { $0 != id && targets[$0]?.contains(cursor) == true }) {
                try? swap(id, other, follow: false, output: &output)
            } else { output.rewrite.insert(id) }
        } else {
            resizeCuts(id, at: at, frame: frame)
            output.rewrite.insert(id)
        }
    }
}
