import AppKit
import CSkyLight
import MinitileCore

extension AppDelegate {
    func handleKey(_ decision: KeyDecision, trace: KeyTrace?) {
        if let trace {
            let route: String
            let argv: [String]
            switch decision {
            case .pass: route = "pass"; argv = []
            case .swallow: route = "swallow"; argv = []
            case .command(let command): route = "command"; argv = command
            }
            let key = [123: "left", 124: "right", 125: "down", 126: "up"][Int(trace.keycode)] ?? String(trace.keycode)
            let chord = Chord(modifiers: KeyRouter.modifiers(CGEventFlags(rawValue: trace.flags)), key: key)
            logKey(["phase": .string("received"), "event_time": .number(trace.time),
                    "dispatch_delay_ms": .number((ProcessInfo.processInfo.systemUptime - trace.time) * 1000),
                    "event": .string(trace.down ? "down" : "up"), "keycode": .number(Double(trace.keycode)),
                    "flags": .string(String(trace.flags, radix: 16)), "chord": .string(chord.description),
                    "route": .string(route), "argv": .array(argv.map(JSONValue.string)),
                    "focus": engine.savedState().focus.map { .number(Double($0)) } ?? .null,
                    "suspended": .array(suspendedReasons.sorted().map(JSONValue.string))])
        }
        if case .command(let argv) = decision {
            let reply = command(argv)
            if let trace {
                logKey(["phase": .string("result"), "event_time": .number(trace.time),
                        "ok": .bool(reply.ok), "text": .string(reply.text),
                        "focus": engine.savedState().focus.map { .number(Double($0)) } ?? .null])
            }
        }
    }

    private func logKey(_ fields: [String: JSONValue]) {
        guard let data = try? JSONEncoder().encode(JSONValue.object(fields)) else { return }
        FileHandle.standardError.write(Data("minitile: key \(String(decoding: data, as: UTF8.self))\n".utf8))
    }

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
                                "suspended_reasons": .array(suspendedReasons.sorted().map(JSONValue.string)),
                                "secure_input": .bool(csl_secure_input_enabled()), "tap_unavailable": .bool(keyboard?.unavailable == true),
                                "key_trace_enabled": .bool(keyboard?.traceEnabled == true),
                                "grid_indicator_displays": .number(Double(gridIndicator.displayCount)),
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
