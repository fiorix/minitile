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
        case .started(_, let windows, let displays, let focused):
            state = SavedState()
            for info in displays {
                var display = DisplayState(info: info)
                if info.unmanagedReason == nil {
                    let workspace = newWorkspace(home: info.id)
                    display.workspaces = [workspace]
                    display.currentWorkspace = workspace.id
                }
                state.displays.append(display)
            }
            for info in windows { appeared(info, output: &output) }
            if let focused, let at = location(focused) {
                show(at, focusWindow: false, output: &output)
                focus(focused, action: false, output: &output)
            }
        case .windowAppeared(let info): appeared(info, output: &output)
        case .windowGone(let id): gone(id, output: &output)
        case .windowUpdated(let info): state.windows[info.id]?.info = info
        case .focusChanged(let id):
            if let id, let at = location(id) { show(at, focusWindow: false, output: &output); focus(id, action: false, output: &output) }
            else if id == nil { focus(nil, action: false, output: &output) }
        case .appActivated(let pid): appActivated(pid, output: &output)
        case .command(let argv):
            do { output.reply = try command(argv, output: &output) }
            catch { state = previous; output = Output(reply: Reply(ok: false, text: String(describing: error))) }
        case .configLoaded(let config): self.config = config
        case .displaysChanged, .dragEnded: break
        }
        cleanup()
        resetLayouts()
        output.scene = makeScene()
        output.stateChanged = state != previous
        return output
    }

    /// Return a snapshot suitable for atomic JSON persistence by the shell.
    public func savedState() -> SavedState { state }
}
