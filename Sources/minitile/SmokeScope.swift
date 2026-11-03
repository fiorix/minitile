import Foundation
import MinitileCore

/// Optional test-run restriction, in addition to only_apps. Restarts may expose
/// only the ID/pid pairs that the smoke runner observed in its own documents.
struct SmokeScope {
    let directory: URL?
    let windows: [WindowID: Int32]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        directory = environment["MINITILE_SMOKE_DIRECTORY"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        var windows: [WindowID: Int32] = [:]
        for pair in environment["MINITILE_SMOKE_WINDOWS", default: ""].split(separator: ",") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, let id = WindowID(parts[0]), let pid = Int32(parts[1]) { windows[id] = pid }
        }
        self.windows = windows
    }

    func allows(document: String?) -> Bool {
        guard let directory else { return true }
        guard let document, let url = URL(string: document), url.isFileURL else { return false }
        return url.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.path
    }

    func allowsStash(id: WindowID, pid: Int32) -> Bool { directory == nil || windows[id] == pid }
}
