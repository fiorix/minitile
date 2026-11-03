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
default: exit(1)
}
