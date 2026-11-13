import Foundation
import MinitileCore

enum DropEdge: String, CaseIterable, Sendable {
    case left, right, top, bottom

    var title: String {
        switch self {
        case .left: "Move left"
        case .right: "Move right"
        case .top: "Move up"
        case .bottom: "Move down"
        }
    }

    func command(_ window: WindowID) -> [String] {
        switch self {
        case .left, .right: ["window", "nudge", String(window), rawValue]
        case .top, .bottom: ["window", "move", String(window), "workspace", self == .top ? "prev" : "next"]
        }
    }

    func target(in area: Rect) -> Rect {
        let inset = min(16, area.width / 12, area.height / 12), width = min(160, area.width / 3), height = min(44, area.height / 3)
        var frame = Rect(x: area.center.x - width / 2, y: area.center.y - height / 2, width: width, height: height)
        switch self {
        case .left: frame.x = area.x + inset
        case .right: frame.x = area.maxX - inset - width
        case .top: frame.y = area.y + inset
        case .bottom: frame.y = area.maxY - inset - height
        }
        return frame
    }
}

/// The source display owns all four bands for the duration of a window move. Coordinates are CG global points.
struct EdgeDropOwner: Equatable, Sendable {
    var window: WindowID
    var pid: Int32
    var display: DisplayID
    var bounds: Rect
    var area: Rect
    var origin: Rect

    init?(window: WindowState, display: DisplayInfo, origin: Rect, frame: Rect, currentSpace: UInt64, visible: Bool) {
        guard visible, !window.hidden, !window.info.minimized, !window.info.appHidden, !window.info.fullscreen,
              !window.info.orderedOut, !window.info.onStash,
              window.display == display.id, display.unmanagedReason == nil,
              display.visibleSpace == currentSpace,
              abs(frame.width - origin.width) <= DragMove.tolerance, abs(frame.height - origin.height) <= DragMove.tolerance,
              display.frame.width > 0, display.frame.height > 0 else { return nil }
        self.window = window.info.id
        pid = window.info.pid
        self.display = display.id
        bounds = display.frame
        area = display.visibleFrame
        self.origin = origin
    }

    // The physical-drag probe suppressed native top fill and sideways Space switching at this inset.
    static let inset = 60.0
    var insetX: Double { min(Self.inset, bounds.width / 4) }
    var insetY: Double { min(Self.inset, bounds.height / 4) }

    func clamp(_ point: Point) -> Point {
        Point(x: min(max(point.x, bounds.x + insetX), bounds.maxX - insetX),
              y: min(max(point.y, bounds.y + insetY), bounds.maxY - insetY))
    }

    /// Keep the previous edge through small corner movements; without one, the closest edge wins, horizontal on a tie.
    func edge(at point: Point, previous: DropEdge? = nil) -> DropEdge? {
        let distances: [(DropEdge, Double)] = [(.left, (point.x - bounds.x) / insetX), (.right, (bounds.maxX - point.x) / insetX),
                                               (.top, (point.y - bounds.y) / insetY), (.bottom, (bounds.maxY - point.y) / insetY)]
        guard let distance = distances.map(\.1).min(), distance <= 1 else {
            // Labels can lie beyond the physical band because of menu bars and Docks; the whole label is a target.
            return DropEdge.allCases.first { $0.target(in: area).contains(point) }
        }
        // A physical pointer can alternate between the screen boundary and fractions of a point inside it.
        // Require up to eight points of advantage before changing edges, while both bands still contain the pointer.
        if let previous, let held = distances.first(where: { $0.0 == previous })?.1,
           held <= 1, held - distance <= 8 / max(insetX, insetY) { return previous }
        return distances.first { $0.1 == distance }?.0
    }
}

struct EdgeDropRelease: Equatable, Sendable {
    var owner: EdgeDropOwner
    var edge: DropEdge?
    var location: Point
}

enum EdgeDropFinish: Equatable {
    case waiting
    case ready(EdgeDropRelease?)
}

/// Only an observed button-down followed by a confirmed window move can acquire the pointer. Cancelling cannot
/// acquire it again until another button-down. A release is consumed once, never inferred from a stale hover.
struct EdgeDropTracker {
    private(set) var sequence: UInt64 = 0
    private var down: Point?
    private(set) var owner: EdgeDropOwner?
    private(set) var hovered: DropEdge?
    private var release: EdgeDropRelease?
    private var releaseWait: TimeInterval?

    mutating func begin(at point: Point) {
        cancel()
        sequence &+= 1
        down = point
    }

    mutating func update(_ candidate: EdgeDropOwner?, moved: Bool, press: UInt64?) {
        if candidate != nil, press != sequence { cancel(); return }
        if let owner, owner != candidate { cancel(); return }
        if let release, release.owner != candidate { cancel(); return }
        if owner == nil, let down, let candidate, moved, candidate.origin.contains(down), candidate.bounds.contains(down) {
            owner = candidate
        }
    }

    mutating func drag(to point: Point) -> Point {
        guard let owner else { return point }
        hovered = owner.edge(at: point, previous: hovered)
        return owner.clamp(point)
    }

    mutating func end(at point: Point) -> Point {
        let location = drag(to: point)
        release = owner.map { EdgeDropRelease(owner: $0, edge: hovered, location: point) }
        down = nil
        owner = nil
        hovered = nil
        releaseWait = nil
        return location
    }

    mutating func cancel() {
        down = nil
        owner = nil
        hovered = nil
        release = nil
        releaseWait = nil
    }

    /// The main thread can observe the button up before its event reaches the tap. Wait briefly for that event;
    /// losing it cancels the edge action rather than committing whichever edge happened to be hovered last.
    mutating func finish(now: TimeInterval) -> EdgeDropFinish {
        if owner != nil {
            if releaseWait == nil { releaseWait = now }
            if now - releaseWait! < 0.1 { return .waiting }
        }
        let result = release
        cancel()
        return .ready(result)
    }
}
