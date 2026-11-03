/// Pure value-type state machine. Call from the shell's serialized handler queue.
public struct Engine: Sendable {
    public private(set) var config: Config
    var state = SavedState()

    public init(config: Config = .default) { self.config = config }

    /// Process one observation or command without I/O, sleeping, or touching windows.
    public mutating func handle(_ input: Input) -> Output {
        let previous = state
        var output = Output()
        switch input {
        case .started(let saved, let windows, let displays, let focused):
            start(saved: saved, windows: windows, displays: displays, focused: focused, output: &output)
        case .windowAppeared(let info): appeared(info, output: &output)
        case .windowGone(let id): gone(id, output: &output)
        case .windowUpdated(let info): updateWindow(info, output: &output)
        case .focusChanged(let id):
            if let id, let at = location(id) { show(at, focusWindow: false, output: &output); focus(id, action: false, output: &output) }
            else { focus(nil, action: false, output: &output) }
        case .appActivated(let pid): appActivated(pid, output: &output)
        case .command(let argv):
            do { output.reply = try command(argv, output: &output) }
            catch { state = previous; output = Output(reply: Reply(ok: false, text: String(describing: error))) }
        case .configLoaded(let config):
            self.config = config
            loadConfig(output: &output)
        case .dragEnded(let id, let frame, let cursor): dragEnded(id, frame: frame, cursor: cursor, output: &output)
        case .displaysChanged(let displays): changeDisplays(displays, output: &output)
        }
        cleanup()
        resetLayouts()
        for i in output.events.indices where output.events[i].type == "page_shown" {
            if case .object(var data) = output.events[i].data, case .string(let id) = data["display"],
               let d = displayIndex(id), let at = currentLocation(display: d) {
                data["workspace"] = .number(Double(at.workspace + 1))
                data["page"] = .number(Double(at.page + 1))
                output.events[i].data = .object(data)
            }
        }
        output.scene = makeScene()
        output.stateChanged = state != previous
        return output
    }

    /// Return a snapshot suitable for atomic JSON persistence by the shell.
    public func savedState() -> SavedState { state }
}
