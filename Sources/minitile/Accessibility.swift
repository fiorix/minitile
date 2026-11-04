import AppKit
@preconcurrency import ApplicationServices
import CSkyLight
import MinitileCore

enum FocusObservation: Equatable {
    case unknown
    case known(WindowID?)

    var window: WindowID? {
        if case .known(let id) = self { return id }
        return nil
    }
}

@MainActor
enum AX {
    static func focus(_ app: AXUIElement) -> FocusObservation {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success else { return .unknown }
        guard let value else { return .known(nil) }
        guard CFGetTypeID(value) == AXUIElementGetTypeID(), let id = id(value as! AXUIElement) else { return .unknown }
        return .known(id)
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func id(_ element: AXUIElement) -> WindowID? {
        var id: UInt32 = 0
        return csl_window_id(element, &id) ? id : nil
    }

    static func frame(_ element: AXUIElement) -> Rect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return Rect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }

    @discardableResult static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    static func setFrame(_ element: AXUIElement, _ frame: Rect) {
        var size = CGSize(width: frame.width.rounded(), height: frame.height.rounded())
        var position = CGPoint(x: frame.x.rounded(), y: frame.y.rounded())
        func writeSize() {
            guard let value = AXValueCreate(.cgSize, &size) else { return }
            if set(element, kAXSizeAttribute, value).rawValue == -25205 {
                var nudge = CGSize(width: size.width + 1, height: size.height + 1)
                if let nudged = AXValueCreate(.cgSize, &nudge) { set(element, kAXSizeAttribute, nudged) }
                set(element, kAXSizeAttribute, value)
            }
        }
        writeSize()
        if let value = AXValueCreate(.cgPoint, &position) { set(element, kAXPositionAttribute, value) }
        writeSize()
    }
}

struct CGWindowRecord: Codable {
    var id: WindowID
    var pid: Int32
    var app: String
    var title: String
    var frame: Rect
    var layer: Int
    var alpha: Double

    var real: Bool { layer == 0 && alpha > 0.01 }

    static func snapshot() -> [WindowID: CGWindowRecord]? {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]], !rows.isEmpty else { return nil }
        var result: [WindowID: CGWindowRecord] = [:]
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? NSNumber,
                  let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            result[id.uint32Value] = CGWindowRecord(id: id.uint32Value, pid: pid.int32Value,
                app: row[kCGWindowOwnerName as String] as? String ?? "",
                title: row[kCGWindowName as String] as? String ?? "",
                frame: Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0)
        }
        return result
    }
}
