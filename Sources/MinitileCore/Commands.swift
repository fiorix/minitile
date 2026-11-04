import Foundation

struct CommandError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

extension Engine {
    /// Stable CLI grammar, shared by help, bindings and shell menu commands.
    public static let help = """
    help [show]
    ignore
    state
    watch
    window list
    window info|show|hide|close [ID]
    window focus [ID|left|right|up|down|next|prev]
    window float [ID] [on|off]
    window nudge [ID] left|right
    window move [ID] left|right|up|down
    window move [ID] page|workspace INDEX|next|prev
    window move [ID] display UUID|next|prev
    window swap [ID] OTHER_ID|next|prev
    window resize [ID] SHARE|WIDTHxHEIGHT|left|right|up|down
    window place [ID] standard|alternate|mirrored|stacked SLOT
    page list
    page info|show|variant [INDEX|next|prev]
    page next|prev [display UUID]
    page ratio R1 [R2]
    workspace list
    workspace info|show [INDEX|next|prev]
    workspace next|prev [display UUID]
    workspace new
    display list
    display info [UUID|next|prev]
    config list|info|reload|open
    switcher next|prev|commit|cancel
    quit

    Pages and workspaces use 1-based indices; tiled slots use 0-based indices.
    Window IDs default to the focused window. Page/workspace context is its display.
    Tiled resize uses fractional shares; floating resize uses WIDTHxHEIGHT in points.
    Directional resize moves an edge by 0.05 of the layout area.
    Place sets the page's layout and puts the window in that tile, counting active tiles.
    Ignore does nothing; a chord bound to it is swallowed.
    """

    mutating func command(_ argv: [String], output: inout Output) throws -> Reply {
        if argv.isEmpty || argv == ["help"] { return Reply(text: Self.help, data: .string(Self.help)) }
        if argv == ["state"] { let value = stateRecord(); return Reply(text: field(value), data: value) }
        if argv == ["watch"] { return Reply(text: "Watching events") }
        if argv == ["ignore"] { return Reply(text: "OK") }
        if argv == ["quit"] { output.actions.append(.quit); return Reply(text: "Quitting") }
        guard argv.count >= 2 else { throw CommandError("Expected a noun and verb; run help") }
        let noun = argv[0], verb = argv[1], args = Array(argv.dropFirst(2))
        switch noun {
        case "window": return try windowCommand(verb, args: args, output: &output)
        case "page", "workspace": return try gridCommand(noun, verb: verb, args: args, output: &output)
        case "display":
            if verb == "list", args.isEmpty {
                return listReply(state.displays.indices.map(displayRecord), columns: ["id", "primary", "workspace", "unmanaged_reason"])
            }
            guard verb == "info", args.count <= 1 else { throw CommandError("Expected display list or display info [UUID|next|prev]") }
            return infoReply(displayRecord(try addressedDisplay(args.first)))
        case "config":
            guard args.isEmpty else { throw CommandError("Expected config list|info|reload|open") }
            switch verb {
            case "list", "info": return infoReply(configRecord())
            case "reload": output.actions.append(.reloadConfig)
            case "open": output.actions.append(.openConfig)
            default: throw CommandError("Expected config list|info|reload|open")
            }
        default: throw CommandError("Expected window, page, workspace, display or config; run help")
        }
        return Reply(text: "OK")
    }

    func addressedDisplay(_ address: String?) throws -> Int {
        if let address, address != "next", address != "prev" {
            guard let d = displayIndex(address) else { throw CommandError("Expected a known display UUID, next or prev") }
            return d
        }
        guard let d = currentDisplay() ?? state.displays.indices.first else { throw CommandError("No display") }
        guard let address else { return d }
        return try addressedIndex(address, current: d, count: state.displays.count)
    }

    /// An explicit navigation target: unlike inspection, it must be a display minitile manages.
    func managedDisplay(_ id: String) throws -> Int {
        guard let d = displayIndex(id) else { throw CommandError("Unknown display \(id)") }
        guard state.displays[d].info.unmanagedReason == nil else { throw CommandError("Display \(id) is not managed") }
        return d
    }

    mutating func gridCommand(_ noun: String, verb: String, args: [String], output: inout Output) throws -> Reply {
        guard let d = currentDisplay(), var at = currentLocation(display: d) else { throw CommandError("No managed display") }
        let workspace = state.displays[d].workspaces[at.workspace]
        let count = noun == "page" ? workspace.pages.count : state.displays[d].workspaces.count
        if verb == "list", args.isEmpty {
            if noun == "page" {
                return listReply(workspace.pages.indices.map { pageRecord(Location(display: d, workspace: at.workspace, page: $0)) },
                                 columns: ["index", "shown", "variant", "r1", "r2", "windows"])
            }
            return listReply(state.displays[d].workspaces.indices.map { workspaceRecord(display: d, workspace: $0) },
                             columns: ["index", "home", "shown", "page"])
        }
        if ["info", "show", "variant"].contains(verb), args.count <= 1, noun == "page" || verb != "variant" {
            let index = try args.first.map { try addressedIndex($0, current: noun == "page" ? at.page : at.workspace, count: count) }
                ?? (noun == "page" ? at.page : at.workspace)
            if noun == "page" { at.page = index }
            else {
                at.workspace = index
                let target = state.displays[d].workspaces[index]
                at.page = target.pages.firstIndex { $0.id == target.currentPage } ?? 0
            }
            if verb == "info" { return infoReply(noun == "page" ? pageRecord(at) : workspaceRecord(display: d, workspace: at.workspace)) }
            if verb == "show" { show(at, output: &output) }
            else { variant(at) }
        } else if verb == "next" || verb == "prev", args.isEmpty || (args.count == 2 && args[0] == "display") {
            let target = try args.last.map(managedDisplay) ?? d
            if noun == "page" { try navigatePage(verb == "next" ? 1 : -1, display: target, output: &output) }
            else { try navigateWorkspace(verb == "next" ? 1 : -1, display: target, output: &output) }
        } else if noun == "workspace", verb == "new", args.isEmpty {
            try navigateWorkspace(1, alwaysNew: true, output: &output)
        } else if noun == "page", verb == "ratio", (1...2).contains(args.count),
                  let a = Double(args[0]), a.isFinite,
                  args.count == 1 || (Double(args[1]).map(\.isFinite) == true) {
            setRatios(at, a, args.count == 2 ? Double(args[1])! : page(at).r2, preserveSecond: args.count == 1)
        } else { throw CommandError("Expected \(noun) list|info|show|next|prev\(noun == "page" ? "|variant|ratio" : "|new"); run help") }
        return Reply(text: "OK")
    }

    mutating func windowCommand(_ verb: String, args supplied: [String], output: inout Output) throws -> Reply {
        if verb == "list", supplied.isEmpty {
            let positions = locations()
            return listReply(state.windows.keys.sorted().map { windowRecord($0, positions: positions) },
                             columns: ["id", "app", "title", "display", "workspace", "page", "slot", "floating"])
        }
        if verb == "focus", supplied.count == 1, ["left", "right", "up", "down", "next", "prev"].contains(supplied[0]) {
            if supplied[0] == "next" || supplied[0] == "prev" { try cycleFocus(supplied[0] == "next" ? 1 : -1, output: &output) }
            else { try spatialFocus(supplied[0], output: &output) }
            return Reply(text: "OK")
        }
        var args = supplied
        let operands = verb == "place" ? 2 : ["move", "nudge", "swap", "resize"].contains(verb) ? 1 : 0
        let id: WindowID
        if args.count > operands, let first = args.first, let explicit = WindowID(first) { id = explicit; args.removeFirst() }
        else if let focused = state.focus { id = focused }
        else { throw CommandError("Expected a window ID; no window is focused") }
        guard state.windows[id] != nil else { throw CommandError("Unknown window ID \(id)") }
        switch verb {
        case "info", "show", "focus", "hide", "close":
            guard args.isEmpty else { throw CommandError("Expected window \(verb) [ID]") }
            if verb == "info" { return infoReply(windowRecord(id, positions: locations())) }
            if verb == "hide" { hideWindow(id, output: &output) }
            else if verb == "close" { output.actions.append(.close(id)) }
            else { try showWindow(id, output: &output) }
        case "float":
            guard args.isEmpty || (args.count == 1 && ["on", "off"].contains(args[0])) else { throw CommandError("Expected window float [ID] [on|off]") }
            try setFloating(id, value: args.first.map { $0 == "on" }, output: &output)
        case "nudge":
            guard args.count == 1, ["left", "right"].contains(args[0]) else { throw CommandError("Expected window nudge [ID] left|right") }
            try nudge(id, direction: args[0] == "left" ? -1 : 1, output: &output)
        case "move":
            if args.count == 1, ["left", "right", "up", "down"].contains(args[0]) {
                if args[0] == "left" || args[0] == "right" { try nudge(id, direction: args[0] == "left" ? -1 : 1, output: &output) }
                else { try moveTarget(id, noun: "workspace", address: args[0] == "up" ? "prev" : "next", output: &output) }
            } else {
                guard args.count == 2 else { throw CommandError("Expected a direction or page|workspace|display ADDRESS") }
                try moveTarget(id, noun: args[0], address: args[1], output: &output)
            }
        case "swap":
            if args == ["next"] || args == ["prev"] { try swapNeighbour(id, step: args[0] == "next" ? 1 : -1, output: &output); break }
            guard args.count == 1, let other = WindowID(args[0]) else { throw CommandError("Expected window swap [ID] OTHER_ID|next|prev") }
            try swap(id, other, output: &output)
        case "resize":
            guard args.count == 1 else { throw CommandError("Expected window resize [ID] SHARE|WIDTHxHEIGHT|left|right|up|down") }
            if ["left", "right", "up", "down"].contains(args[0]) { try resizeStep(id, direction: args[0], output: &output) }
            else { try resize(id, size: args[0], output: &output) }
        case "place":
            guard args.count == 2, let variant = Variant(rawValue: args[0]), let slot = Int(args[1]) else {
                throw CommandError("Expected window place [ID] standard|alternate|mirrored|stacked SLOT")
            }
            try place(id, variant: variant, slot: slot, output: &output)
        default: throw CommandError("Expected window list|info|show|hide|focus|float|move|nudge|swap|resize|place|close")
        }
        return Reply(text: "OK")
    }

    mutating func spatialFocus(_ direction: String, output: inout Output) throws {
        guard let id = state.focus, let at = location(id) else { throw CommandError("No focused window") }
        let tiledFrames = frames(at)
        guard let origin = (tiledFrames[id] ?? state.windows[id]?.info.frame)?.center else { return }
        var best: WindowID?, distance = Double.infinity
        for other in page(at).windows where other != id && canFocus(other) {
            guard let point = (tiledFrames[other] ?? state.windows[other]?.info.frame)?.center else { continue }
            let dx = point.x - origin.x, dy = point.y - origin.y
            let inDirection = direction == "left" ? dx < -1 : direction == "right" ? dx > 1 : direction == "up" ? dy < -1 : dy > 1
            let candidate = dx * dx + dy * dy
            if inDirection && candidate < distance { best = other; distance = candidate }
        }
        if let best { focus(best, action: true, output: &output) }
    }

    /// Walks the focused window's page, or the shown page when no managed window has focus.
    mutating func cycleFocus(_ step: Int, output: inout Output) throws {
        let current = state.focus.flatMap { id in location(id).map { (id: id, at: $0) } }
        guard let at = current?.at ?? currentDisplay().flatMap({ currentLocation(display: $0) }) else {
            throw CommandError("No managed display")
        }
        let order = tiled(page(at)) + page(at).windows.filter { state.windows[$0]?.floating == true }
        if let target = Self.cycle(order, from: current?.id, step: step, focusable: canFocus) { try showWindow(target, output: &output) }
    }

    /// Wraps around `order`; without a current window in it, picks the first focusable one.
    static func cycle(_ order: [WindowID], from current: WindowID?, step: Int, focusable: (WindowID) -> Bool) -> WindowID? {
        guard let current, let start = order.firstIndex(of: current) else { return order.first(where: focusable) }
        let n = order.count
        return (1..<n).lazy.map { order[((start + $0 * step) % n + n) % n] }.first(where: focusable)
    }
}
