import AppKit

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "front": print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
case "restore":
    if arguments.count == 3, let pid = Int32(arguments[2]) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }
case "quit-empty":
    if arguments.count == 3, let pid = Int32(arguments[2]),
       let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "com.apple.TextEdit",
       let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
       !windows.contains(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
           && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }) {
        app.terminate()
    }
case "fullscreen":
    // fullscreen PID TITLE on|off: asks the app's window with that title to enter or leave full screen.
    guard arguments.count == 5, let pid = Int32(arguments[2]) else { exit(1) }
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
    for window in windows as? [AXUIElement] ?? [] {
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        guard title as? String == arguments[3] else { continue }
        let value: CFBoolean = arguments[4] == "on" ? kCFBooleanTrue : kCFBooleanFalse
        exit(AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, value) == .success ? 0 : 1)
    }
    exit(1)
default: exit(1)
}
