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

/// Reads are nonisolated so background discovery can use them; writes and focus reads stay on the main thread.
@MainActor
enum AX {
    static func focus(_ app: AXUIElement) -> FocusObservation {
        let (value, error) = copy(app, kAXFocusedWindowAttribute)
        guard error == .success else { return .unknown }
        guard let value else { return .known(nil) }
        guard CFGetTypeID(value) == AXUIElementGetTypeID(), let id = id(value as! AXUIElement) else { return .unknown }
        return .known(id)
    }

    nonisolated static func copy(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var result: CFTypeRef?
        let error = timed(element, attribute) { AXUIElementCopyAttributeValue(element, attribute as CFString, &result) }
        return (error == .success ? result : nil, error)
    }

    nonisolated static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        copy(element, attribute).value
    }

    nonisolated static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated static func id(_ element: AXUIElement) -> WindowID? {
        var id: UInt32 = 0
        return timed(element, "window id") { csl_window_id(element, &id) } ? id : nil
    }

    nonisolated static func frame(_ element: AXUIElement) -> Rect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return Rect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }

    /// Nil when the read fails.
    nonisolated static func settable(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var settable: DarwinBoolean = false
        let error = timed(element, attribute + " settable") { AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) }
        return error == .success ? settable.boolValue : nil
    }

    @discardableResult static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        timed(element, attribute) { AXUIElementSetAttributeValue(element, attribute as CFString, value) }
    }

    @discardableResult static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        timed(element, action) { AXUIElementPerformAction(element, action as CFString) }
    }

    /// Input waits behind the main thread, so an AX call that holds it for long is logged with its app.
    @discardableResult nonisolated static func timed<T>(_ element: AXUIElement, _ name: String, _ call: () -> T) -> T {
        guard Thread.isMainThread else { return call() }
        let start = ProcessInfo.processInfo.systemUptime
        let result = call()
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        if milliseconds > Slow.mainThreadAXCall {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown app"
            logger.notice("Slow AX call \(name, privacy: .public) to \(app, privacy: .public) (pid \(pid)) took \(Int(milliseconds)) ms on the main thread")
        }
        return result
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

struct CGWindowRecord: Codable, Sendable {
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
