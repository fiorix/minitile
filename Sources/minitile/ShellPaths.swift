import AppKit

struct ShellPaths {
    let config: URL
    let state: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        config = environment["MINITILE_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config/minitile/minitile.toml")
        state = environment["MINITILE_STATE"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/state/minitile/state.json")
    }

    func configContents() throws -> String? {
        do { return try String(contentsOf: config, encoding: .utf8) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    @MainActor func openConfig() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: config.path) {
            try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# minitile configuration\ngaps = 8\npadding = 8\n".write(to: config, atomically: true, encoding: .utf8)
        }
        guard NSWorkspace.shared.open(config) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: config.path])
        }
    }
}
