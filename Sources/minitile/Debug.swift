import AppKit
import CSkyLight
import MinitileCore

extension AppDelegate {
    func debug(_ argv: [String]) -> Reply {
        guard argv.count == 1 else { return Reply(ok: false, text: "debug spaces|windows|scene|timings|health") }
        do {
            let data: JSONValue
            switch argv[0] {
            case "spaces":
                let current = displays.displays.map { display in
                    var display = display
                    display.current = csl_current_space(display.identifier as CFString)
                    return display
                }
                data = try .encoding(current)
            case "windows":
                struct RawWindow: Encodable {
                    var id: WindowID
                    var pid: Int32
                    var app: String
                    var bundleID: String?
                    var title: String
                    var frame: Rect
                    var spaces: [UInt64]
                    var tileable: Bool
                    var observed: Bool
                }
                let rows = (CGWindowRecord.snapshot() ?? [:]).values.filter { record in
                    guard record.real, let app = NSRunningApplication(processIdentifier: record.pid) else { return false }
                    return discovery?.allows(app) == true
                }.sorted { $0.id < $1.id }.map { record in
                    let observed = discovery?.windows[record.id]
                    return RawWindow(id: record.id, pid: record.pid, app: record.app,
                                     bundleID: NSRunningApplication(processIdentifier: record.pid)?.bundleIdentifier,
                                     title: observed?.info.title ?? record.title, frame: observed.flatMap { AX.frame($0.element) } ?? record.frame,
                                     spaces: displays.windowSpaces(record.id), tileable: observed?.info.tileable ?? false, observed: observed != nil)
                }
                data = try .encoding(rows)
            case "scene":
                data = .object(["displays": .object(try (reconciler?.scene.displays ?? [:]).mapValues { scene in
                    .object(["visible": try .encoding(scene.visible), "stashed": try .encoding(scene.stashed),
                             "frames": .object(try Dictionary(uniqueKeysWithValues: scene.frames.map { (String($0.key), try .encoding($0.value)) })),
                             "label": .string(scene.label)])
                })])
            case "timings": data = .object(["reconcile_ms": .number(reconciler?.lastMilliseconds ?? 0)])
            case "health":
                data = .object(["started": .bool(started), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)), "suspended": .bool(discovery?.frozen == true),
                                "secure_input": .bool(csl_secure_input_enabled()), "tap_unavailable": .bool(keyboard?.unavailable == true),
                                "startup_stash_windows": .number(Double(startupStashCount)),
                                "startup_immediate_stash_handles": .number(Double(startupImmediateHandles)),
                                "config": .string(paths.config.path), "state": .string(paths.state.path),
                                "warnings": .array(warnings.values.sorted().map(JSONValue.string))])
            default: return Reply(ok: false, text: "debug spaces|windows|scene|timings|health")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return Reply(text: String(decoding: try encoder.encode(data), as: UTF8.self), data: data)
        } catch { return Reply(ok: false, text: String(describing: error)) }
    }
}
