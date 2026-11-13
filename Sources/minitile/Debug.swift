import AppKit
import CSkyLight
import MinitileCore

extension AppDelegate {
    /// `received` is when the tap saw the event; nil for a decision made on the main thread.
    func handleKey(_ decision: KeyDecision, trace: KeyTrace?, received: TimeInterval? = nil) {
        let (route, argv) = decision.route
        // Pass and swallow reach the main thread only for traces.
        if let received, decision != .pass, decision != .swallow {
            inputWaited("Key \(([route] + argv).joined(separator: " "))", since: received)
        }
        if let trace {
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
        if case .switcher(let key, let session) = decision { switcherKey(key, session: session) }
        if case .help(let key, let session) = decision { helpKey(key, session: session) }
        if case .grabReleased(let session) = decision { grabHighlight.released(session); updateGrab() }
        if case .command(let argv, let grab) = decision {
            let start = ProcessInfo.processInfo.systemUptime
            let reply = command(argv, grab: grab)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if ms > Slow.keyCommand { logger.notice("Slow key command \(argv.joined(separator: " "), privacy: .public) took \(Int(ms)) ms") }
            if let trace {
                logKey(["phase": .string("result"), "event_time": .number(trace.time),
                        "ok": .bool(reply.ok), "text": .string(reply.text),
                        "focus": engine.savedState().focus.map { .number(Double($0)) } ?? .null])
            }
        }
    }

    /// Logs a key binding or swipe that waited long for the main thread, measured from its tap callback.
    func inputWaited(_ input: String, since received: TimeInterval) {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - received) * 1000
        if inputWaits.record(milliseconds) {
            logger.notice("\(input, privacy: .public) waited \(Int(milliseconds)) ms for the main thread")
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
                    var onScreen: Bool
                    var tileable: Bool
                    var fullscreen: Bool
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
                                     spaces: DisplayCatalog.windowSpaces(record.id), onScreen: record.onScreen, tileable: observed?.info.tileable ?? false,
                                     fullscreen: observed?.info.fullscreen ?? false, observed: observed != nil)
                }
                data = try .encoding(rows)
            case "scene":
                data = .object(["displays": .object(try (reconciler?.scene.displays ?? [:]).mapValues { scene in
                    .object(["visible": try .encoding(scene.visible), "stashed": try .encoding(scene.stashed),
                             "frames": .object(try Dictionary(uniqueKeysWithValues: scene.frames.map { (String($0.key), try .encoding($0.value)) })),
                             "label": .string(scene.label)])
                })])
            case "timings":
                data = .object(["reconcile_ms": .number(reconciler?.lastMilliseconds ?? 0),
                                "focus_ms": .number(reconciler?.lastFocusMilliseconds ?? 0),
                                "resume_ms": .number(lastResumeMilliseconds),
                                "input_wait_ms": .number(inputWaits.latest),
                                "input_wait_max_ms": .number(inputWaits.longest),
                                "main_ax_calls": .number(Double(AX.mainThreadTimings.count)),
                                "main_ax_ms": .number(AX.mainThreadTimings.total),
                                "main_ax_max_ms": .number(AX.mainThreadTimings.longest),
                                "drag_ticks": .number(Double(dragTicks.count)),
                                "drag_tick_ms": .number(dragTicks.total),
                                "drag_tick_max_ms": .number(dragTicks.longest),
                                "activation_moves": try .encoding(reconciler?.activationTimings ?? []),
                                "full_scans": .number(Double(discovery?.fullScans ?? 0)),
                                "full_scan_ms": .number(discovery?.fullScanMilliseconds ?? 0),
                                "recheck_requests": .number(Double(discovery?.recheckRequests ?? 0)),
                                "recheck_passes": .number(Double(discovery?.recheckPasses ?? 0))])
            case "health":
                // One read, so the window and its hovered edge belong to the same moment of the drag.
                let edgeDrop = edgeDrops?.preview
                data = .object(["started": .bool(started), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)), "suspended": .bool(discovery?.frozen == true),
                                "suspended_reasons": .array(suspendedReasons.sorted().map(JSONValue.string)),
                                "secure_input": .bool(csl_secure_input_enabled()), "tap_unavailable": .bool(keyboard?.unavailable == true),
                                "key_trace_enabled": .bool(keyboard?.traceEnabled == true),
                                "trackpad_swipes": .bool(engine.config.trackpadSwipes),
                                "edge_drops": .bool(engine.config.edgeDrops),
                                "edge_drop_tap_running": .bool(edgeDrops?.running == true),
                                "edge_drop_tap_unavailable": .bool(edgeDrops?.unavailable == true),
                                "edge_drop_window": edgeDrop.map { .number(Double($0.owner.window)) } ?? .null,
                                "edge_drop_hovered": edgeDrop?.edge.map { .string($0.rawValue) } ?? .null,
                                "swipe_tap_running": .bool(swipes?.running == true),
                                "swipe_tap_unavailable": .bool(swipes?.unavailable == true),
                                "last_swipe": try swipes?.last.map { last in
                                    .object(["location": try .encoding(last.location), "display": last.display.map(JSONValue.string) ?? .null,
                                             "command": last.command.map { .string($0.joined(separator: " ")) } ?? .null])
                                } ?? .null,
                                "grid_indicator_displays": .number(Double(gridIndicator.displayCount)),
                                "grid_indicator_visible_displays": .number(Double(gridIndicator.visibleCount)),
                                "grid_indicator_duration_ms": .number(GridIndicatorTiming.duration * 1000),
                                "switcher_open": .bool(windowSwitcher.isOpen),
                                "switcher_selected": windowSwitcher.selection?.selected.window.map { .number(Double($0)) } ?? .null,
                                "switcher_selected_app": windowSwitcher.selection?.selected.app.map { .number(Double($0)) } ?? .null,
                                "help_open": .bool(helpScreen.isOpen),
                                "grab_window": grabHighlight.window.map { .number(Double($0)) } ?? .null,
                                "grab_held": .bool(grabHighlight.session != nil),
                                "grab_visible": .bool(grabPanel.visible),
                                "transitions_enabled": .bool(transitions.enabled),
                                "transitions_disabled_reason": transitions.reason.map(JSONValue.string) ?? .null,
                                "startup_stash_windows": .number(Double(startupStashCount)),
                                "startup_immediate_stash_handles": .number(Double(startupImmediateHandles)),
                                "config": .string(paths.config.path), "state": .string(paths.state.path),
                                "desktop_notice_visible_displays": .number(Double(desktopNotice.visibleCount)),
                                "warnings": .array(statusWarnings.titles.map(JSONValue.string))])
            default: return Reply(ok: false, text: "debug spaces|windows|scene|timings|health")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return Reply(text: String(decoding: try encoder.encode(data), as: UTF8.self), data: data)
        } catch { return Reply(ok: false, text: String(describing: error)) }
    }
}
