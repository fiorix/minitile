/// Pure value-type state machine. Call from the shell's serialized handler queue.
public struct Engine: Sendable {
    public private(set) var config: Config
    var state = SavedState()

    public init(config: Config = .default) { self.config = config }

    /// Process one observation or command without I/O, sleeping, or touching windows.
    public mutating func handle(_ input: Input) -> Output { Output() }

    /// Return a snapshot suitable for atomic JSON persistence by the shell.
    public func savedState() -> SavedState { state }
}
