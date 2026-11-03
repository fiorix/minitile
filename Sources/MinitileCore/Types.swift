import Foundation
import MinitileIPC

/// Native CGWindowID, valid only while its owning process exists.
public typealias WindowID = UInt32
/// Stable display UUID, rather than the transient CGDirectDisplayID.
public typealias DisplayID = String
public typealias Reply = MinitileIPC.Reply
public typealias Event = MinitileIPC.Event
public typealias JSONValue = MinitileIPC.JSONValue

/// Global display coordinates: primary top-left origin, y increasing downwards.
public struct Point: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A frame in global display coordinates, measured in points.
public struct Rect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }
    public func contains(_ point: Point) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }
}

/// The shell's latest observation of a window. Missing AX reads should retain prior values.
public struct WindowInfo: Codable, Sendable, Equatable {
    public var id: WindowID
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    public var title: String
    public var frame: Rect
    public var tileable: Bool
    public var minimized: Bool
    public var appHidden: Bool
    public var fromFrontmostApp: Bool
    public var display: DisplayID?
    public var onStash: Bool

    public init(id: WindowID, pid: Int32, bundleID: String? = nil, appName: String = "", title: String = "",
                frame: Rect = Rect(x: 0, y: 0, width: 0, height: 0), tileable: Bool = true,
                minimized: Bool = false, appHidden: Bool = false, fromFrontmostApp: Bool = false,
                display: DisplayID? = nil, onStash: Bool = false) {
        self.id = id; self.pid = pid; self.bundleID = bundleID; self.appName = appName
        self.title = title; self.frame = frame; self.tileable = tileable; self.minimized = minimized
        self.appHidden = appHidden; self.fromFrontmostApp = fromFrontmostApp
        self.display = display; self.onStash = onStash
    }
}

/// Debounced display metadata. A non-nil reason excludes the display from management.
public struct DisplayInfo: Codable, Sendable, Equatable {
    public var id: DisplayID
    public var frame: Rect
    public var visibleFrame: Rect
    public var isPrimary: Bool
    public var unmanagedReason: String?
    public var visibleSpace: UInt64?
    public var stashSpace: UInt64?

    public init(id: DisplayID, frame: Rect, visibleFrame: Rect? = nil, isPrimary: Bool = false,
                unmanagedReason: String? = nil, visibleSpace: UInt64? = nil, stashSpace: UInt64? = nil) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame ?? frame
        self.isPrimary = isPrimary; self.unmanagedReason = unmanagedReason
        self.visibleSpace = visibleSpace; self.stashSpace = stashSpace
    }
}

/// All external observations and commands accepted by the pure engine.
public enum Input: Sendable {
    case started(saved: SavedState?, windows: [WindowInfo], displays: [DisplayInfo], focus: WindowID?)
    case configLoaded(Config)
    case displaysChanged([DisplayInfo])
    case windowAppeared(WindowInfo)
    case windowUpdated(WindowInfo)
    case windowGone(WindowID)
    case focusChanged(WindowID?)
    case appActivated(pid: Int32)
    case dragEnded(WindowID, frame: Rect, cursor: Point)
    case command([String])
}

/// Side effects for the shell; focus must be applied after moves and frame writes.
public enum Action: Sendable, Equatable {
    case focus(WindowID)
    case close(WindowID)
    case reloadConfig
    case quit
}

/// Desired placement on one managed display. Minimized/hidden-app windows still have desktop ownership.
public struct DisplayScene: Codable, Sendable, Equatable {
    public var visible: [WindowID]
    public var frames: [WindowID: Rect]
    public var stashed: [WindowID]
    public var label: String
    public init(visible: [WindowID] = [], frames: [WindowID: Rect] = [:], stashed: [WindowID] = [], label: String = "1:1") {
        self.visible = visible; self.frames = frames; self.stashed = stashed; self.label = label
    }
}

/// Complete desired placement, including each window's destination stash display.
public struct Scene: Codable, Sendable, Equatable {
    public var displays: [DisplayID: DisplayScene]
    public init(displays: [DisplayID: DisplayScene] = [:]) { self.displays = displays }
}

/// Reconcile moves first, then changed frames (plus `rewrite`), then actions with focus last.
public struct Output: Sendable {
    public var scene: Scene
    public var actions: [Action]
    public var rewrite: Set<WindowID>
    public var reply: Reply?
    public var events: [Event]
    public var stateChanged: Bool
    public init(scene: Scene = Scene(), actions: [Action] = [], rewrite: Set<WindowID> = [],
                reply: Reply? = nil, events: [Event] = [], stateChanged: Bool = false) {
        self.scene = scene; self.actions = actions; self.rewrite = rewrite
        self.reply = reply; self.events = events; self.stateChanged = stateChanged
    }
}
