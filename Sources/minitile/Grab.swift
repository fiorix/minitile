import Foundation
import MinitileCore

/// A keyboard move or resize the grab highlight follows: nudge, carry, slot swap and directional resize.
struct GrabCommand: Equatable {
    private enum Target { case focused, window(WindowID) }

    /// What follows the optional window ID, by verb.
    private static let operands: [String: Set<[String]>] = [
        "nudge": [["left"], ["right"]],
        "move": [["left"], ["right"], ["up"], ["down"], ["workspace", "prev"], ["workspace", "next"]],
        "resize": [["left"], ["right"], ["up"], ["down"]],
        "swap": [["next"], ["prev"]],
    ]

    var window: WindowID
    /// False for a command that changed nothing, which keeps a grab of its window but starts none.
    var acted: Bool

    init(window: WindowID, acted: Bool) { self.window = window; self.acted = acted }

    /// Nil unless `argv` grabs and succeeded. A command without a window ID acts on `focus`, the focus before it ran.
    init?(argv: [String], focus: WindowID?, output: Output) {
        guard output.reply?.ok == true, let target = Self.target(argv) else { return nil }
        switch target {
        case .window(let id): window = id
        case .focused:
            guard let focus else { return nil }
            window = focus
        }
        acted = output.stateChanged
    }

    static func grabs(_ argv: [String]) -> Bool { target(argv) != nil }

    private static func target(_ argv: [String]) -> Target? {
        guard argv.count >= 3, argv[0] == "window", let shapes = operands[argv[1]] else { return nil }
        let args = Array(argv.dropFirst(2))
        if shapes.contains(args) { return .focused }
        guard let id = WindowID(args[0]), shapes.contains(Array(args.dropFirst())) else { return nil }
        return .window(id)
    }
}

/// How long a grab lasts. One a binding started lasts while the binding's modifiers are held, which the key router
/// reports by session; one without held modifiers, from `mntl` or the menu, lasts `timeout` after its last command.
struct GrabLifetime: Equatable {
    static let timeout: TimeInterval = 1

    struct Grab: Equatable {
        var window: WindowID
        /// The key router's session while the binding's modifiers are held; nil for a timed grab.
        var session: Int?
        var until: TimeInterval?
        /// The focus when the grab last moved; focus moving elsewhere, except to the window itself, ends it.
        var focus: WindowID?
    }

    private(set) var grab: Grab?

    /// A grabbing command ran. One that changed nothing starts nothing, but counts like any other on the grabbed
    /// window. A command without a session continues a held grab of its window, since the keys still hold it.
    mutating func command(_ command: GrabCommand, session: Int?, focus: WindowID?, now: TimeInterval) {
        guard command.acted || grab?.window == command.window else { return }
        if session == nil, let grab, grab.window == command.window, grab.session != nil {
            self.grab?.focus = focus
            return
        }
        grab = Grab(window: command.window, session: session, until: session == nil ? now + Self.timeout : nil, focus: focus)
    }

    /// One of the binding's modifiers was released. A release for an older session leaves a newer grab alone.
    mutating func released(_ session: Int) {
        if grab?.session == session { grab = nil }
    }

    mutating func end() { grab = nil }

    /// Ends a timed grab that is due, and any grab whose window closed, was minimized or hidden, or lost focus to
    /// another window.
    mutating func check(_ state: SavedState, now: TimeInterval) {
        guard let grab else { return }
        if let until = grab.until, now >= until { self.grab = nil; return }
        guard let window = state.windows[grab.window], !window.hidden, !window.info.minimized, !window.info.appHidden else {
            self.grab = nil; return
        }
        if state.focus == grab.window { self.grab?.focus = grab.window }
        else if state.focus != grab.focus { self.grab = nil }
    }
}

enum GrabPlacement {
    /// The window's tile in the applied scene, or its frame in the model when it floats. Nil unless the window is on
    /// its display's visible desktop with a place there.
    static func frame(of id: WindowID, scene: Scene, state: SavedState) -> (display: DisplayID, frame: Rect)? {
        guard let (display, desired) = scene.displays.first(where: { $0.value.visible.contains(id) }) else { return nil }
        if let tile = desired.frames[id] { return (display, tile) }
        guard let window = state.windows[id], window.floating else { return nil }
        return (display, window.info.frame)
    }
}

@MainActor
protocol GrabPresenting: AnyObject {
    /// `frame` is the window's tile in CG global points.
    func show(_ frame: Rect)
    func hide()
}

/// The grab's main-thread side: its lifetime, the timer of a timed grab, and where the outline goes.
@MainActor
final class GrabHighlight {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    private(set) var lifetime = GrabLifetime()
    private(set) var shown: Rect?
    /// Runs when a timed grab may be due, so the shell updates the outline with the current model.
    var due: (() -> Void)?
    private let presenter: any GrabPresenting
    private let schedule: Schedule
    private let now: @MainActor () -> TimeInterval

    init(presenter: any GrabPresenting, now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
         }) {
        self.presenter = presenter
        self.now = now
        self.schedule = schedule
    }

    var window: WindowID? { lifetime.grab?.window }
    /// The key router's session of a grab held by a binding's modifiers.
    var session: Int? { lifetime.grab?.session }

    func command(_ command: GrabCommand, session: Int?, focus: WindowID?) {
        let time = now()
        lifetime.command(command, session: session, focus: focus, now: time)
        if let until = lifetime.grab?.until {
            schedule(max(0, until - time)) { [weak self] in self?.due?() }
        }
    }

    func released(_ session: Int) { lifetime.released(session) }

    func end() { lifetime.end() }

    /// Ends the grab when it is due or its window went away, then outlines the window, unless `covered` says a slide
    /// is hiding its display.
    func update(state: SavedState, scene: Scene, covered: (DisplayID) -> Bool) {
        lifetime.check(state, now: now())
        guard let window = lifetime.grab?.window, let target = GrabPlacement.frame(of: window, scene: scene, state: state),
              !covered(target.display) else {
            if shown != nil { shown = nil; presenter.hide() }
            return
        }
        guard shown != target.frame else { return }
        shown = target.frame
        presenter.show(target.frame)
    }
}
