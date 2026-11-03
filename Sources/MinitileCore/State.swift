import Foundation

public enum Variant: String, Codable, Sendable { case standard, alternate }

/// Persistent page identity and ordered windows, including floating windows and reserved slots.
public struct PageState: Codable, Sendable, Equatable {
    public var id: UInt64
    public var windows: [WindowID] = []
    public var variant: Variant = .standard
    public var r1: Double = 0.5
    public var r2: Double = 0.5
    public var lastFocus: WindowID?
    public var layoutCount: Int = 0
    public init(id: UInt64) { self.id = id }
}

/// Home UUID is retained when the workspace moves onto another display.
public struct WorkspaceState: Codable, Sendable, Equatable {
    public var id: UInt64
    public var home: DisplayID
    public var pages: [PageState]
    public var currentPage: UInt64
    public init(id: UInt64, home: DisplayID, pages: [PageState], currentPage: UInt64) {
        self.id = id; self.home = home; self.pages = pages; self.currentPage = currentPage
    }
}

/// Display metadata and its current grid, including workspaces from disconnected displays.
public struct DisplayState: Codable, Sendable, Equatable {
    public var info: DisplayInfo
    public var workspaces: [WorkspaceState]
    public var currentWorkspace: UInt64?
    public init(info: DisplayInfo, workspaces: [WorkspaceState] = [], currentWorkspace: UInt64? = nil) {
        self.info = info; self.workspaces = workspaces; self.currentWorkspace = currentWorkspace
    }
}

/// Window metadata plus explicit hide/float state and focus recency.
public struct WindowState: Codable, Sendable, Equatable {
    public var info: WindowInfo
    public var display: DisplayID
    public var floating: Bool
    public var floatingOverride: Bool?
    public var hidden: Bool = false
    public var hiddenHome: DisplayID?
    public var lastFocused: UInt64 = 0
    public init(info: WindowInfo, display: DisplayID, floating: Bool) {
        self.info = info; self.display = display; self.floating = floating
    }
}

/// JSON-encodable snapshot. Restore only windows whose ID and pid still match current observations.
public struct SavedState: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var displays: [DisplayState] = []
    public var windows: [WindowID: WindowState] = [:]
    public var focus: WindowID?
    public var activeDisplay: DisplayID?
    public var displayViews: [DisplayID: UInt64] = [:]
    public var serial: UInt64 = 0
    public init() {}
}
