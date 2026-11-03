import AppKit
import CSkyLight
import MinitileCore

struct NativeSpace: Codable, Equatable {
    var id: UInt64
    var type: Int
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

    static func near(_ a: Rect, _ b: Rect, tolerance: Double = 1) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

@MainActor
final class DisplayCatalog {
    private(set) var displays: [NativeDisplay] = []
    private(set) var desktopNumbers: [UInt64: Int] = [:]
    var infos: [DisplayInfo] { displays.map(\.info) }

    /// Compare topology and usable geometry, excluding which desktop is currently showing.
    @discardableResult func refresh() -> Bool {
        let raw = csl_copy_managed_display_spaces() as? [[String: Any]] ?? []
        desktopNumbers = [:]
        for display in raw {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if (space["type"] as? NSNumber)?.intValue == 0, let id = space["id64"] as? NSNumber {
                    desktopNumbers[id.uint64Value] = desktopNumbers.count + 1
                }
            }
        }
        let screens = NSScreen.screens
        let height = screens.first?.frame.height ?? 0
        let fresh: [NativeDisplay] = screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid) as String
            let native = raw.first { ($0["Display Identifier"] as? String) == id }
                ?? (index == 0 ? raw.first { ($0["Display Identifier"] as? String) == "Main" } : nil)
            let spaces = (native?["Spaces"] as? [[String: Any]] ?? []).compactMap { row -> NativeSpace? in
                guard let id = row["id64"] as? NSNumber, let type = row["type"] as? NSNumber else { return nil }
                return NativeSpace(id: id.uint64Value, type: type.intValue)
            }
            let users = spaces.filter { $0.type == 0 }
            let reason: String? = !NSScreen.screensHaveSeparateSpaces ? "Displays have separate Spaces is disabled"
                : users.count < 2 ? "Create two desktops in Mission Control" : nil
            let info = DisplayInfo(id: id, frame: Geometry.cgFrame(screen.frame, primaryHeight: height),
                                   visibleFrame: Geometry.cgFrame(screen.visibleFrame, primaryHeight: height),
                                   isPrimary: index == 0, unmanagedReason: reason,
                                   visibleSpace: users.first?.id, stashSpace: users.count >= 2 ? users.last?.id : nil)
            let identifier = native?["Display Identifier"] as? String ?? id
            return NativeDisplay(info: info, identifier: identifier, spaces: spaces,
                                 current: csl_current_space(identifier as CFString))
        }.sorted { $0.info.id < $1.info.id }
        let changed = fresh.map(\.info) != infos || fresh.map(\.spaces) != displays.map(\.spaces)
            || fresh.map(\.identifier) != displays.map(\.identifier)
        displays = fresh
        return changed
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

    func windowSpaces(_ id: WindowID) -> [UInt64] {
        var id = id
        return (csl_copy_window_spaces(&id, 1) as? [NSNumber] ?? []).map(\.uint64Value)
    }
}
