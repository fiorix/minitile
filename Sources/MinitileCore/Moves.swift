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
            let index = at.page + direction
            guard state.displays[at.display].workspaces[at.workspace].pages.indices.contains(index) else { return }
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
            frame.width = first.rounded(); frame.height = second.rounded()
            state.windows[id]?.info.frame = frame
            output.actions.append(.setFrame(id, frame))
            return
        }
        guard let at = location(id), var target = frames(at)[id] else { throw CommandError("Window has no active tile") }
        let display = state.displays[at.display].info.visibleFrame
        let area = Layout.area(frame: display, padding: config.padding)
        let count = tiled(page(at), activeOnly: true).count
        let landscape = display.width >= display.height
        let longIsX = (count == 2 && page(at).variant == .alternate) ? !landscape : landscape
        func changeWidth(_ share: Double) {
            if abs(target.x - area.x) < 1.1 { target.width = area.width * share - config.gaps / 2 }
            else { let right = target.maxX; target.width = area.width * share - config.gaps / 2; target.x = right - target.width }
        }
        func changeHeight(_ share: Double) {
            if abs(target.y - area.y) < 1.1 { target.height = area.height * share - config.gaps / 2 }
            else { let bottom = target.maxY; target.height = area.height * share - config.gaps / 2; target.y = bottom - target.height }
        }
        if let second { changeWidth(first); changeHeight(second) }
        else if longIsX { changeWidth(first) } else { changeHeight(first) }
        resizeCuts(id, at: at, frame: target)
        output.rewrite.insert(id)
    }

    mutating func resizeCuts(_ id: WindowID, at: Location, frame: Rect) {
        guard let original = frames(at)[id] else { return }
        let p = page(at)
        let count = tiled(p, activeOnly: true).count
        let display = state.displays[at.display].info.visibleFrame
        let area = Layout.area(frame: display, padding: config.padding)
        let longX = display.width >= display.height
        var cuts: [(x: Bool, second: Bool, ratio: Double)] = []
        if count == 2 { cuts = [(p.variant == .alternate ? !longX : longX, false, p.r1)] }
        if count == 3 { cuts = [(longX, false, p.r1), (p.variant == .alternate ? longX : !longX, true, p.r2)] }
        if count == 4 { cuts = [(longX, false, p.r1), (!longX, true, p.r2)] }
        var a = p.r1, b = p.r2
        for cut in cuts {
            let origin = cut.x ? area.x : area.y
            let length = cut.x ? area.width : area.height
            guard length > 0 else { continue }
            let position = origin + length * cut.ratio
            let edges: [(Double, Double, Double)] = cut.x
                ? [(original.x, frame.x, -config.gaps / 2), (original.maxX, frame.maxX, config.gaps / 2)]
                : [(original.y, frame.y, -config.gaps / 2), (original.maxY, frame.maxY, config.gaps / 2)]
            for (old, new, correction) in edges where abs(old + correction - position) <= 1.1 && abs(old - new) > 3 {
                let ratio = (new + correction - origin) / length
                if cut.second { b = ratio } else { a = ratio }
            }
        }
        setRatios(at, a, b)
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
