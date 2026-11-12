import Foundation

extension Engine {
    func json<T: Encodable>(_ value: T) -> JSONValue { (try? .encoding(value)) ?? .null }

    func windowRecord(_ id: WindowID, positions: [WindowID: Location]) -> JSONValue {
        guard let window = state.windows[id] else { return .null }
        let at = positions[id]
        let slot = at?.tiledSlot
        return .object([
            "id": json(id), "pid": json(window.info.pid), "bundle_id": json(window.info.bundleID),
            "app": .string(window.info.appName), "title": .string(window.info.title), "frame": json(window.info.frame),
            "display": .string(window.display), "workspace": json(at.map { $0.workspace + 1 }),
            "page": json(at.map { $0.page + 1 }), "slot": json(slot),
            "floating": .bool(window.floating), "hidden": .bool(window.hidden), "focused": .bool(state.focus == id),
            "shown": .bool(at.map(isShown) == true && !window.info.minimized && !window.info.appHidden),
            "minimized": .bool(window.info.minimized), "app_hidden": .bool(window.info.appHidden),
            "ordered_out": .bool(window.info.orderedOut), "fullscreen": .bool(window.info.fullscreen),
            "tileable": .bool(window.info.tileable),
        ])
    }

    func pageRecord(_ at: Location) -> JSONValue {
        let p = page(at)
        return .object([
            "id": json(p.id), "index": json(at.page + 1), "display": json(state.displays[at.display].info.id),
            "workspace": json(at.workspace + 1), "shown": .bool(isShown(at)), "variant": json(p.variant),
            "r1": json(p.r1), "r2": json(p.r2), "windows": json(p.windows), "tiled": json(tiled(p)),
            "floating": json(p.windows.filter { state.windows[$0]?.floating == true }), "last_focus": json(p.lastFocus),
        ])
    }

    func workspaceRecord(display d: Int, workspace w: Int) -> JSONValue {
        let workspace = state.displays[d].workspaces[w]
        return .object([
            "id": json(workspace.id), "index": json(w + 1), "display": json(state.displays[d].info.id),
            "home": json(workspace.home), "shown": .bool(state.displays[d].currentWorkspace == workspace.id),
            "page": json(workspace.pages.firstIndex { $0.id == workspace.currentPage }.map { $0 + 1 }),
            "pages": .array(workspace.pages.indices.map { pageRecord(Location(display: d, workspace: w, page: $0)) }),
        ])
    }

    func displayRecord(_ d: Int) -> JSONValue {
        let display = state.displays[d]
        return .object([
            "id": json(display.info.id), "frame": json(display.info.frame), "visible_frame": json(display.info.visibleFrame),
            "primary": json(display.info.isPrimary), "unmanaged_reason": json(display.info.unmanagedReason),
            "visible_space": json(display.info.visibleSpace), "stash_space": json(display.info.stashSpace),
            "workspace": json(currentLocation(display: d).map { $0.workspace + 1 }),
            "workspaces": .array(display.workspaces.indices.map { workspaceRecord(display: d, workspace: $0) }),
            "home_workspaces": json(display.workspaces.enumerated().filter { $0.element.home == display.info.id }.map { $0.offset + 1 }),
            "merged_workspaces": json(display.workspaces.enumerated().filter { $0.element.home != display.info.id }.map { $0.offset + 1 }),
        ])
    }

    func stateRecord() -> JSONValue {
        let positions = locations()
        return .object([
            "version": .number(1), "focus": json(state.focus), "active_display": json(state.activeDisplay),
            "displays": .array(state.displays.indices.map(displayRecord)),
            "windows": .array(state.windows.keys.sorted().map { windowRecord($0, positions: positions) }),
        ])
    }

    func configRecord() -> JSONValue {
        var bindings: [String: JSONValue] = [:]
        for (chord, argv) in config.bindings { bindings[chord.description] = .string(argv.joined(separator: " ")) }
        return .object(["gaps": json(config.gaps), "padding": json(config.padding), "float_apps": json(config.floatApps),
                        "only_apps": json(config.onlyApps), "transition_ms": json(config.transitionMs),
                        "trackpad_swipes": .bool(config.trackpadSwipes), "bindings": .object(bindings)])
    }

    func field(_ value: JSONValue) -> String {
        switch value {
        case .null: return "-"
        case .string(let string): return string.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        case .bool(let bool): return bool ? "true" : "false"
        case .number(let number): return number.rounded() == number ? String(format: "%.0f", number) : String(number)
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
    }

    func infoReply(_ value: JSONValue) -> Reply {
        guard case .object(let fields) = value else { return Reply(text: field(value), data: value) }
        return Reply(text: fields.keys.sorted().map { "\($0): \(field(fields[$0]!))" }.joined(separator: "\n"), data: value)
    }

    func listReply(_ values: [JSONValue], columns: [String]) -> Reply {
        let rows = values.map { value -> [String] in
            guard case .object(let object) = value else { return columns.map { _ in "-" } }
            return columns.map { field(object[$0] ?? .null) }
        }
        let widths = columns.indices.map { i in ([columns[i].count] + rows.map { $0[i].count }).max()! }
        let text = ([columns] + rows).map { row in
            row.enumerated().map { i, cell in cell + String(repeating: " ", count: i == columns.count - 1 ? 0 : widths[i] - cell.count + 2) }.joined()
        }.joined(separator: "\n")
        return Reply(text: text, data: .array(values))
    }
}
