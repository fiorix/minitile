import Foundation

struct CommandError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

extension Engine {
    mutating func command(_ argv: [String], output: inout Output) throws -> Reply {
        switch argv {
        case ["help"], []: return Reply(text: "page next|prev; workspace next|prev|new; window focus <id>")
        case ["watch"]: return Reply(text: "Watching events")
        case ["page", "next"]: try navigatePage(1, output: &output)
        case ["page", "prev"]: try navigatePage(-1, output: &output)
        case ["workspace", "next"]: try navigateWorkspace(1, output: &output)
        case ["workspace", "prev"]: try navigateWorkspace(-1, output: &output)
        case ["workspace", "new"]: try navigateWorkspace(1, alwaysNew: true, output: &output)
        default:
            if argv.count >= 2, argv[0] == "window", ["move", "nudge", "swap", "resize"].contains(argv[1]) {
                var args = Array(argv.dropFirst(2))
                let id: WindowID
                if args.count >= 2, let explicit = WindowID(args[0]) { id = explicit; args.removeFirst() }
                else if let focused = state.focus { id = focused }
                else { throw CommandError("Expected a window ID; no window is focused") }
                guard state.windows[id] != nil else { throw CommandError("Unknown window ID \(id)") }
                switch argv[1] {
                case "nudge":
                    guard args.count == 1, ["left", "right"].contains(args[0]) else { throw CommandError("Expected left or right") }
                    try nudge(id, direction: args[0] == "left" ? -1 : 1, output: &output)
                case "move":
                    if args.count == 1, ["left", "right", "up", "down"].contains(args[0]) {
                        if args[0] == "left" || args[0] == "right" {
                            try nudge(id, direction: args[0] == "left" ? -1 : 1, output: &output)
                        } else { try moveTarget(id, noun: "workspace", address: args[0] == "up" ? "prev" : "next", output: &output) }
                    } else {
                        guard args.count == 2 else { throw CommandError("Expected a direction or page|workspace|display ADDRESS") }
                        try moveTarget(id, noun: args[0], address: args[1], output: &output)
                    }
                case "swap":
                    guard args.count == 1, let other = WindowID(args[0]) else { throw CommandError("Expected another window ID") }
                    try swap(id, other, output: &output)
                default:
                    guard args.count == 1 else { throw CommandError("Expected a share or WIDTHxHEIGHT") }
                    try resize(id, size: args[0], output: &output)
                }
            } else if argv == ["page", "variant"], let d = currentDisplay(), let at = currentLocation(display: d) {
                variant(at)
            } else if argv.count == 4, argv.prefix(2) == ["page", "ratio"],
                      let a = Double(argv[2]), a.isFinite, let b = Double(argv[3]), b.isFinite,
                      let d = currentDisplay(), let at = currentLocation(display: d) {
                setRatios(at, a, b)
            } else if argv.count >= 2, argv[0] == "window", ["focus", "show", "hide", "float", "close"].contains(argv[1]) {
                var args = Array(argv.dropFirst(2))
                let id: WindowID
                if let first = args.first, let explicit = WindowID(first) { id = explicit; args.removeFirst() }
                else if let focused = state.focus { id = focused }
                else { throw CommandError("Expected a window ID; no window is focused") }
                guard state.windows[id] != nil else { throw CommandError("Unknown window ID \(id)") }
                if argv[1] == "float" {
                    guard args.isEmpty || (args.count == 1 && ["on", "off"].contains(args[0])) else { throw CommandError("Expected on or off") }
                    try setFloating(id, value: args.first.map { $0 == "on" }, output: &output)
                } else {
                    guard args.isEmpty else { throw CommandError("Expected an optional window ID") }
                    if argv[1] == "hide" { hideWindow(id, output: &output) }
                    else if argv[1] == "close" { output.actions.append(.close(id)) }
                    else { try showWindow(id, output: &output) }
                }
            } else { throw CommandError("Expected a command; run help") }
        }
        return Reply(text: "OK")
    }
}
