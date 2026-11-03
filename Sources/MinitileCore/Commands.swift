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
            if argv.count == 3, argv[0] == "window", ["focus", "show"].contains(argv[1]),
               let id = WindowID(argv[2]), let at = location(id) {
                show(at, focusWindow: false, output: &output)
                focus(id, action: true, output: &output)
            } else { throw CommandError("Expected a command; run help") }
        }
        return Reply(text: "OK")
    }
}
