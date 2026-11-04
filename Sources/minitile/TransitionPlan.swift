import CoreGraphics
import MinitileCore

/// Navigation direction: +dx is Ctrl+Right, +dy is Ctrl+Down. Content moves the opposite way.
struct TransitionDirection: Equatable, Hashable {
    var dx: Int
    var dy: Int
}

enum TransitionKind: Equatable {
    case slide(TransitionDirection)
    case bounce(TransitionDirection)
}

/// A display's shown workspace and page by persistent identity, so renumbering is not a change.
struct ShownView: Equatable {
    var workspace: UInt64
    var page: UInt64

    init?(_ display: DisplayState) {
        guard display.info.unmanagedReason == nil, let id = display.currentWorkspace,
              let workspace = display.workspaces.first(where: { $0.id == id }),
              workspace.pages.contains(where: { $0.id == workspace.currentPage }) else { return nil }
        self.workspace = id
        page = workspace.currentPage
    }
}

enum TransitionPlan {
    /// Navigation commands that bounce when they leave the view unchanged.
    static let bounces: [[String]: TransitionDirection] = [
        ["page", "next"]: TransitionDirection(dx: 1, dy: 0), ["page", "prev"]: TransitionDirection(dx: -1, dy: 0),
        ["workspace", "next"]: TransitionDirection(dx: 0, dy: 1), ["workspace", "prev"]: TransitionDirection(dx: 0, dy: -1),
    ]

    /// A navigation command's bounce direction and the display it addresses, if it names one.
    static func navigation(_ argv: [String]) -> (direction: TransitionDirection, display: DisplayID?)? {
        guard argv.count == 2 || (argv.count == 4 && argv[2] == "display"),
              let direction = bounces[Array(argv.prefix(2))] else { return nil }
        return (direction, argv.count == 4 ? argv[3] : nil)
    }

    /// Per display: slide where the shown page or workspace changed, bounce where a navigation command on the
    /// display it acts on changed nothing: the addressed display, else `context`.
    static func plan(before: SavedState, after: SavedState, argv: [String], context: DisplayID?) -> [DisplayID: TransitionKind] {
        let navigation = navigation(argv)
        let context = navigation?.display ?? context
        var result: [DisplayID: TransitionKind] = [:]
        for display in after.displays {
            guard let old = before.displays.first(where: { $0.info.id == display.info.id }),
                  let from = ShownView(old), let to = ShownView(display) else { continue }
            if from != to { result[display.info.id] = .slide(direction(before: old, after: display, from: from, to: to)) }
            else if display.info.id == context, let navigation { result[display.info.id] = .bounce(navigation.direction) }
        }
        return result
    }

    static func direction(before: DisplayState, after: DisplayState, from: ShownView, to: ShownView) -> TransitionDirection {
        guard from.workspace == to.workspace else {
            return TransitionDirection(dx: 0, dy: step(before.workspaces.map(\.id), after.workspaces.map(\.id), from.workspace, to.workspace))
        }
        let pages = { (display: DisplayState) in display.workspaces.first { $0.id == from.workspace }?.pages.map(\.id) ?? [] }
        return TransitionDirection(dx: step(pages(before), pages(after), from.page, to.page), dy: 0)
    }

    /// Order two identities in the state that holds both (cleanup removes the one left, navigation creates the
    /// one entered), else the old index before against the new index after.
    static func step(_ before: [UInt64], _ after: [UInt64], _ from: UInt64, _ to: UInt64) -> Int {
        for order in [before, after] {
            if let a = order.firstIndex(of: from), let b = order.firstIndex(of: to) { return b > a ? 1 : -1 }
        }
        guard let a = before.firstIndex(of: from), let b = after.firstIndex(of: to) else { return 1 }
        return b >= a ? 1 : -1
    }
}

enum TransitionGate {
    /// Nil when transitions may run.
    static func reason(milliseconds: Double, reduceMotion: Bool, screenRecording: Bool) -> String? {
        if milliseconds <= 0 { return "transition_ms is 0" }
        if reduceMotion { return "Reduce Motion is on" }
        if !screenRecording { return "Screen Recording is not granted" }
        return nil
    }

    /// Ask for Screen Recording only when it is the one thing keeping transitions off.
    static func needsPermission(milliseconds: Double, reduceMotion: Bool, screenRecording: Bool) -> Bool {
        milliseconds > 0 && !reduceMotion && !screenRecording
    }
}

/// Outputs held while a transition captures the page it leaves, merged so that one reconcile applies them.
struct PendingReconcile {
    private(set) var scene: Scene
    private(set) var rewrite: Set<WindowID> = []
    private(set) var actions: [Action] = []
    private(set) var focus: WindowID?

    init(_ output: Output) {
        scene = output.scene
        add(output)
    }

    /// The scene is complete in every output, so the latest wins; one-shot frame and close actions keep their order.
    mutating func add(_ output: Output) {
        scene = output.scene
        rewrite.formUnion(output.rewrite)
        for action in output.actions {
            switch action {
            case .focus(let id): focus = id
            case .setFrame, .close: actions.append(action)
            case .reloadConfig, .openConfig, .quit: break
            }
        }
    }

    /// Focus goes last, and only if the model still holds it: a later input may have moved focus elsewhere.
    func output(modelFocus: WindowID?) -> Output {
        var actions = actions
        if let focus, focus == modelFocus { actions.append(.focus(focus)) }
        return Output(scene: scene, actions: actions, rewrite: rewrite)
    }
}

enum TransitionGeometry {
    /// The usable area in display-local coordinates with a top-left origin, from Cocoa frames.
    static func sourceRect(frame: CGRect, visible: CGRect) -> CGRect {
        CGRect(x: visible.minX - frame.minX, y: frame.maxY - visible.maxY, width: visible.width, height: visible.height)
    }

    /// How far content travels in a layer whose y grows upwards: Right moves it left, Down moves it up.
    static func shift(_ direction: TransitionDirection, size: CGSize) -> CGSize {
        CGSize(width: -CGFloat(direction.dx) * size.width, height: CGFloat(direction.dy) * size.height)
    }
}
