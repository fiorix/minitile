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
            guard pages.indices.contains(index) else {
                carryAcross(id, from: at, dx: direction, dy: 0, output: &output)
                return
            }
            while pages.indices.contains(index), !hasRoom(pages[index], for: id) { index += direction }
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

    /// Moves the window onto the shown page of the display on the side a unit step (dx, dy) points to, by the
    /// placement rules, with focus following it. False, changing nothing, without a display there or while the mouse
    /// drags the window, since the pointer still holds it on this display.
    @discardableResult
    mutating func carryAcross(_ id: WindowID, from at: Location, dx: Int, dy: Int, output: inout Output) -> Bool {
        guard id != dragging, let e = neighbour(of: at.display, dx: dx, dy: dy),
              let start = currentLocation(display: e) else { return false }
        removeFromPage(id)
        leave(at.display, output: &output)
        move(id, to: start, output: &output)
        output.crossed = state.displays[e].info.id
        return true
    }

    /// A carry up from the first workspace, or down from a last workspace the window is alone in, would change
    /// nothing on its display, so it goes to the display above or below.
    mutating func carryPastGrid(_ id: WindowID, from at: Location, address: String, output: inout Output) -> Bool {
        let workspaces = state.displays[at.display].workspaces
        if address == "prev", at.workspace == 0 { return carryAcross(id, from: at, dx: 0, dy: -1, output: &output) }
        guard address == "next", at.workspace == workspaces.count - 1,
              workspaces[at.workspace].pages.allSatisfy({ $0.windows.allSatisfy { $0 == id } }) else { return false }
        return carryAcross(id, from: at, dx: 0, dy: 1, output: &output)
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
            if let source = location(id), carryPastGrid(id, from: source, address: address, output: &output) { return }
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

    private enum AddressedGridTarget: Equatable {
        case index(Int)
        case new(Int?)
    }

    private enum ResolvedMoveTarget: Equatable {
        case existing(display: Int, workspace: Int, page: Int)
        case newPage(display: Int, workspace: Int, index: Int)
        case newWorkspace(display: Int, index: Int)
    }

    mutating func moveAddressed(_ id: WindowID, args: [String], stay: Bool, output: inout Output) throws {
        guard !args.isEmpty else { throw CommandError("Expected a direction or page|workspace|display ADDRESS") }
        guard let ownD = state.windows[id].flatMap({ displayIndex($0.display) }) else {
            throw CommandError("No managed display")
        }
        let preSource = location(id)
        let resolved: ResolvedMoveTarget
        if args.count == 2, args[0] == "page" || args[0] == "workspace", args[1] == "next" || args[1] == "prev" {
            guard state.displays[ownD].info.unmanagedReason == nil,
                  let base = preSource ?? currentLocation(display: ownD) else { throw CommandError("No managed display") }
            if args[0] == "page" {
                let pages = state.displays[ownD].workspaces[base.workspace].pages
                let index = try addressedIndex(args[1], current: base.page, count: pages.count, allowNext: true)
                resolved = index == pages.count
                    ? .newPage(display: ownD, workspace: base.workspace, index: pages.count)
                    : .existing(display: ownD, workspace: base.workspace, page: index)
            } else {
                let workspaces = state.displays[ownD].workspaces
                let index = try addressedIndex(args[1], current: base.workspace, count: workspaces.count, allowNext: true)
                if index == workspaces.count {
                    resolved = .newWorkspace(display: ownD, index: workspaces.count)
                } else {
                    let workspace = workspaces[index]
                    let page = workspace.pages.firstIndex { $0.id == workspace.currentPage } ?? 0
                    resolved = .existing(display: ownD, workspace: index, page: page)
                }
            }
        } else {
            var i = 0
            var displayAddr: String?
            var workspaceSpec: AddressedGridTarget?
            var pageSpec: AddressedGridTarget?
            if i < args.count, args[i] == "display" {
                guard i + 1 < args.count else { throw CommandError("Expected display UUID, next or prev") }
                displayAddr = args[i + 1]
                i += 2
            }
            if i < args.count, args[i] == "workspace" {
                guard i + 1 < args.count else { throw CommandError("Expected workspace INDEX or new [INDEX]") }
                if args[i + 1] == "new" {
                    i += 2
                    if i < args.count, args[i] != "page" {
                        guard let index = Int(args[i]) else { throw CommandError("Expected workspace new [INDEX]") }
                        workspaceSpec = .new(index)
                        i += 1
                    } else {
                        workspaceSpec = .new(nil)
                    }
                } else {
                    guard let index = Int(args[i + 1]) else { throw CommandError("Expected workspace INDEX or new [INDEX]") }
                    workspaceSpec = .index(index)
                    i += 2
                }
            }
            if i < args.count, args[i] == "page" {
                guard i + 1 < args.count else { throw CommandError("Expected page INDEX or new [INDEX]") }
                if args[i + 1] == "new" {
                    i += 2
                    if i < args.count {
                        guard let index = Int(args[i]) else { throw CommandError("Expected page new [INDEX]") }
                        pageSpec = .new(index)
                        i += 1
                    } else {
                        pageSpec = .new(nil)
                    }
                } else {
                    guard let index = Int(args[i + 1]) else { throw CommandError("Expected page INDEX or new [INDEX]") }
                    pageSpec = .index(index)
                    i += 2
                }
            }
            guard i == args.count, displayAddr != nil || workspaceSpec != nil || pageSpec != nil else {
                throw CommandError("Expected [display UUID|next|prev] [workspace INDEX|new [INDEX]] [page INDEX|new [INDEX]] [stay]")
            }
            let destDisplay: Int
            if let displayAddr {
                if displayAddr == "next" || displayAddr == "prev" {
                    let managed = state.displays.indices.filter { state.displays[$0].info.unmanagedReason == nil }
                    guard let current = managed.firstIndex(of: ownD) else { throw CommandError("No managed display") }
                    let idx = try addressedIndex(displayAddr, current: current, count: managed.count)
                    destDisplay = managed[idx]
                } else {
                    guard let found = displayIndex(displayAddr), state.displays[found].info.unmanagedReason == nil else {
                        throw CommandError("Expected a managed display UUID, next or prev")
                    }
                    destDisplay = found
                }
            } else {
                guard state.displays[ownD].info.unmanagedReason == nil else { throw CommandError("No managed display") }
                destDisplay = ownD
            }
            let workspaces = state.displays[destDisplay].workspaces
            if case .new(let requested) = workspaceSpec {
                let count = workspaces.count
                let number = requested ?? (count + 1)
                guard (1...(count + 1)).contains(number) else {
                    throw CommandError("Expected a workspace index in 1...\(count + 1)")
                }
                if let pageSpec, pageSpec != .index(1), pageSpec != .new(1) {
                    throw CommandError("workspace new accepts only page 1 or page new 1")
                }
                resolved = .newWorkspace(display: destDisplay, index: number - 1)
            } else {
                let targetWorkspace: Int
                if let workspaceSpec, case .index(let number) = workspaceSpec {
                    guard (1...workspaces.count).contains(number) else {
                        throw CommandError("Expected a workspace index in 1...\(workspaces.count)")
                    }
                    targetWorkspace = number - 1
                } else if displayAddr == nil, destDisplay == ownD, let preSource {
                    targetWorkspace = preSource.workspace
                } else {
                    guard let current = currentLocation(display: destDisplay) else {
                        throw CommandError("Display has no workspace")
                    }
                    targetWorkspace = current.workspace
                }
                let pages = workspaces[targetWorkspace].pages
                switch pageSpec {
                case nil:
                    let page = workspaces[targetWorkspace].pages.firstIndex { $0.id == workspaces[targetWorkspace].currentPage } ?? 0
                    resolved = .existing(display: destDisplay, workspace: targetWorkspace, page: page)
                case .index(let number):
                    guard (1...pages.count).contains(number) else {
                        throw CommandError("Expected a page index in 1...\(pages.count)")
                    }
                    resolved = .existing(display: destDisplay, workspace: targetWorkspace, page: number - 1)
                case .new(let requested):
                    let number = requested ?? (pages.count + 1)
                    guard (1...(pages.count + 1)).contains(number) else {
                        throw CommandError("Expected a page index in 1...\(pages.count + 1)")
                    }
                    resolved = .newPage(display: destDisplay, workspace: targetWorkspace, index: number - 1)
                }
            }
        }
        if let preSource {
            switch resolved {
            case .existing(let d, let w, let p):
                if preSource.display == d, preSource.workspace == w, preSource.page == p { return }
            case .newPage(let d, let w, let index):
                if preSource.display == d, preSource.workspace == w, page(preSource).windows == [id],
                   index == preSource.page || index == preSource.page + 1 { return }
            case .newWorkspace(let d, let index):
                if preSource.display == d,
                   state.displays[d].workspaces[preSource.workspace].pages.allSatisfy({ $0.windows.allSatisfy { $0 == id } }),
                   index == preSource.workspace || index == preSource.workspace + 1 { return }
            }
        }
        let target: Location
        switch resolved {
        case .existing(let d, let w, let p):
            target = Location(display: d, workspace: w, page: p)
        case .newPage(let d, let w, let index):
            let created = PageState(id: nextSerial())
            state.displays[d].workspaces[w].pages.insert(created, at: index)
            target = Location(display: d, workspace: w, page: index)
        case .newWorkspace(let d, let index):
            let created = newWorkspace(home: state.displays[d].info.id)
            state.displays[d].workspaces.insert(created, at: index)
            target = Location(display: d, workspace: index, page: 0)
        }
        let source = location(id)
        guard stay else {
            move(id, to: target, output: &output)
            return
        }
        removeFromPage(id)
        let dest = place(id, at: target)
        if let source, isShown(source), page(source).windows.isEmpty {
            vacate(source, excluding: id, output: &output)
        }
        if let source {
            keepFocusInView(id, from: source.display, to: dest, output: &output)
        }
        output.events.append(Event(type: "window_moved", data: .number(Double(id))))
    }

    /// After `id` left `display` without the view following it, focus stays on what that display shows.
    mutating func keepFocusInView(_ id: WindowID, from d: Int, to dest: Location, output: inout Output) {
        guard state.focus == id, !(dest.display == d && isShown(dest)) else { return }
        let active = state.activeDisplay
        if let current = currentLocation(display: d),
           page(current).windows.contains(where: { $0 != id && canFocus($0) }) {
            show(current, output: &output)
            state.activeDisplay = active
        } else if isShown(dest) {
            // Nothing is left to focus on the source display, so the active display goes with the focus.
            state.activeDisplay = state.displays[dest.display].info.id
        } else {
            focus(nil, action: false, output: &output)
        }
    }

    mutating func swap(_ first: WindowID, _ second: WindowID, follow: Bool = true, output: inout Output) throws {
        guard let a = location(first), let b = location(second),
              state.windows[first]?.floating == false, state.windows[second]?.floating == false else {
            throw CommandError("Expected two tiled windows")
        }
        guard !isFullscreen(first), !isFullscreen(second) else { throw CommandError("A full screen window keeps its page") }
        guard first != second else { return }
        state.displays[a.display].workspaces[a.workspace].pages[a.page].windows[a.slot] = second
        state.displays[b.display].workspaces[b.workspace].pages[b.page].windows[b.slot] = first
        state.windows[first]?.display = state.displays[b.display].info.id
        state.windows[second]?.display = state.displays[a.display].info.id
        let crossPage = a.display != b.display || a.workspace != b.workspace || a.page != b.page
        if crossPage {
            if page(a).lastFocus == first { state.displays[a.display].workspaces[a.workspace].pages[a.page].lastFocus = nil }
            if page(b).lastFocus == second { state.displays[b.display].workspaces[b.workspace].pages[b.page].lastFocus = nil }
        }
        if follow {
            show(b, focusWindow: false, output: &output)
            focus(first, action: true, output: &output)
        } else if crossPage {
            if state.focus == first { keepFocusInView(first, from: a.display, to: b, output: &output) }
            else if state.focus == second { keepFocusInView(second, from: b.display, to: a, output: &output) }
        }
        output.events += [Event(type: "window_moved", data: .number(Double(first))), Event(type: "window_moved", data: .number(Double(second)))]
    }

    /// Trades the window with the active tile after or before it on its page, wrapping around; reserved slots of
    /// minimized and app-hidden windows are skipped. Focus stays with the window.
    mutating func swapNeighbour(_ id: WindowID, step: Int, follow: Bool = true, output: inout Output) throws {
        guard let (at, _) = activeTile(id) else { throw CommandError("Window has no active tile") }
        let active = tiled(page(at), activeOnly: true)
        guard active.count > 1, let index = active.firstIndex(of: id) else { return }
        try swap(id, active[((index + step) % active.count + active.count) % active.count], follow: follow, output: &output)
    }

    /// Sets the page's variant and puts the window in that tile of the layout. `standard` stands for the count's first
    /// layout. Slots count the page's active tiles; the other active tiles keep their order, and reserved and floating
    /// windows keep their places in the page's list.
    mutating func place(_ id: WindowID, variant requested: Variant, slot: Int, output: inout Output) throws {
        guard let (at, _) = activeTile(id) else { throw CommandError("Window has no active tile") }
        let active = tiled(page(at), activeOnly: true)
        let variant = requested == .standard ? Layout.effective(.standard, count: active.count) : requested
        guard Layout.variants(count: active.count).contains(variant) else {
            throw CommandError("\(variant.rawValue) is not a layout for \(active.count) windows")
        }
        guard active.indices.contains(slot) else { throw CommandError("Expected a slot in 0...\(active.count - 1)") }
        state.displays[at.display].workspaces[at.workspace].pages[at.page].nativeLayout = nil
        // A dropped window snaps to its tile even when nothing changes.
        output.rewrite.insert(id)
        let current = page(at)
        let reset = Layout.effective(current.variant, count: active.count) != variant
        guard current.variant != variant || active[slot] != id else { return }
        if active[slot] != id {
            var windows = current.windows
            windows.removeAll { $0 == id }
            let others = active.filter { $0 != id }
            let index = slot < others.count ? windows.firstIndex(of: others[slot])! : windows.firstIndex(of: others[slot - 1])! + 1
            windows.insert(id, at: index)
            state.displays[at.display].workspaces[at.workspace].pages[at.page].windows = windows
        }
        state.displays[at.display].workspaces[at.workspace].pages[at.page].variant = variant
        if reset {
            let (a, b) = Layout.defaults(count: active.count, variant: variant)
            setRatios(at, a, b)
        }
        show(at, focusWindow: false, output: &output)
        focus(id, action: true, output: &output)
        for (old, new) in zip(active, tiled(page(at), activeOnly: true)) where old != new {
            output.events.append(Event(type: "window_moved", data: .number(Double(new))))
        }
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
