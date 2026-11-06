import AppKit
import CSkyLight
import MinitileCore

struct NativeSpace: Codable, Equatable {
    var id: UInt64
    var type: Int
}

struct NativeDisplaySpaces: Equatable {
    var identifier: String
    var spaces: [NativeSpace]

    /// Keep native order for Desktop N shortcuts; current Space is not topology.
    static func parse(_ raw: [[String: Any]]) -> [Self] {
        raw.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { row -> NativeSpace? in
                guard let id = row["id64"] as? NSNumber, let type = row["type"] as? NSNumber else { return nil }
                return NativeSpace(id: id.uint64Value, type: type.intValue)
            }
            return Self(identifier: identifier, spaces: spaces)
        }
    }
}

struct NativeDisplay: Codable, Equatable {
    var info: DisplayInfo
    var identifier: String
    var spaces: [NativeSpace]
    var current: UInt64

    var userSpaces: [UInt64] { spaces.filter { $0.type == 0 }.map(\.id) }
}

enum Geometry {
    static func cgFrame(_ frame: CGRect, primaryHeight: Double) -> Rect {
        Rect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The inverse of `cgFrame`: AppKit's origin is the primary display's bottom-left, with y up.
    static func cocoaFrame(_ frame: Rect, primaryHeight: Double) -> CGRect {
        CGRect(x: frame.x, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func near(_ a: Rect, _ b: Rect, tolerance: Double = 1) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

@MainActor
final class DisplayCatalog {
    private(set) var displays: [NativeDisplay] = []
    private(set) var desktopNumbers: [UInt64: Int] = [:]
    private var nativeSpaces: [NativeDisplaySpaces] = []
    var infos: [DisplayInfo] { displays.map(\.info) }

    static func id(for screen: NSScreen) -> DisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Displays' names as the user knows them, such as "Built-in Retina Display", by ID.
    static func names() -> [DisplayID: String] {
        Dictionary(NSScreen.screens.compactMap { screen in id(for: screen).map { ($0, screen.localizedName) } }) { first, _ in first }
    }

    private func readSpaces() -> [NativeDisplaySpaces]? {
        guard let raw = csl_copy_managed_display_spaces() as? [[String: Any]] else { return nil }
        let parsed = NativeDisplaySpaces.parse(raw)
        return parsed.isEmpty ? nil : parsed
    }

    /// Probe without committing a change before the lifecycle debounce completes.
    func spacesChanged() -> Bool {
        guard let fresh = readSpaces() else { return false }
        return fresh != nativeSpaces
    }

    /// Compare topology and usable geometry, excluding which desktop is currently showing.
    @discardableResult func refresh() -> Bool {
        guard let (raw, fresh) = read() else { return false }
        desktopNumbers = [:]
        for display in raw {
            for space in display.spaces where space.type == 0 {
                desktopNumbers[space.id] = desktopNumbers.count + 1
            }
        }
        let changed = Self.changed(fresh, from: displays)
        displays = fresh
        nativeSpaces = raw
        return changed
    }

    /// True when the displays read now match the catalog, so waking needs no reconfiguration settling.
    func unchanged() -> Bool {
        guard let (_, fresh) = read() else { return false }
        return !Self.changed(fresh, from: displays)
    }

    nonisolated static func changed(_ fresh: [NativeDisplay], from old: [NativeDisplay]) -> Bool {
        fresh.map(\.info) != old.map(\.info) || fresh.map(\.spaces) != old.map(\.spaces) || fresh.map(\.identifier) != old.map(\.identifier)
    }

    private func read() -> (raw: [NativeDisplaySpaces], fresh: [NativeDisplay])? {
        guard let raw = readSpaces() else { return nil }
        let screens = NSScreen.screens
        let height = screens.first?.frame.height ?? 0
        let fresh: [NativeDisplay] = screens.enumerated().compactMap { index, screen in
            guard let id = Self.id(for: screen) else { return nil }
            let native = raw.first { $0.identifier == id }
                ?? (index == 0 ? raw.first { $0.identifier == "Main" } : nil)
            let spaces = native?.spaces ?? []
            let users = spaces.filter { $0.type == 0 }
            let need: DisplayNeed? = !NSScreen.screensHaveSeparateSpaces ? .separateSpaces : users.count < 2 ? .secondDesktop : nil
            let info = DisplayInfo(id: id, frame: Geometry.cgFrame(screen.frame, primaryHeight: height),
                                   visibleFrame: Geometry.cgFrame(screen.visibleFrame, primaryHeight: height),
                                   isPrimary: index == 0, unmanagedReason: need?.reason,
                                   visibleSpace: users.first?.id, stashSpace: users.count >= 2 ? users.last?.id : nil)
            let identifier = native?.identifier ?? id
            return NativeDisplay(info: info, identifier: identifier, spaces: spaces,
                                 current: csl_current_space(identifier as CFString))
        }.sorted { $0.info.id < $1.info.id }
        return (raw, fresh)
    }

    func owner(spaces: [UInt64]) -> NativeDisplay? {
        displays.first { display in
            display.info.unmanagedReason == nil && spaces.contains { $0 == display.info.visibleSpace || $0 == display.info.stashSpace }
        }
    }

    func bounceFromStash() {
        for display in displays where display.info.unmanagedReason == nil {
            guard let visible = display.info.visibleSpace, let stash = display.info.stashSpace,
                  csl_current_space(display.identifier as CFString) == stash else { continue }
            if !csl_switch_space(display.identifier as CFString, visible, stash) {
                logger.error("Could not switch display \(display.info.id, privacy: .public) off its stash")
            }
        }
    }

    nonisolated static func windowSpaces(_ id: WindowID) -> [UInt64] {
        var id = id
        return (csl_copy_window_spaces(&id, 1) as? [NSNumber] ?? []).map(\.uint64Value)
    }
}
