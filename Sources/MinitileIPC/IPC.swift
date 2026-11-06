import Foundation

/// Errors in local transport, distinct from command errors returned as `Reply(ok: false)`.
public enum IPCError: Error, Sendable {
    case invalidPath
    case system(String, Int32)
    case alreadyRunning
    case invalidResponse
    case requestTooLarge
    case disconnected
}

/// Resolve MINITILE_SOCKET or the Darwin per-user temporary directory plus minitile.sock.
public func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
    if let path = environment["MINITILE_SOCKET"], !path.isEmpty { return path }
    let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    guard size > 0 else { throw IPCError.system("confstr", errno) }
    var bytes = [CChar](repeating: 0, count: size)
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, size) > 0 else { throw IPCError.system("confstr", errno) }
    let directory = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return (directory as NSString).appendingPathComponent("minitile.sock")
}

/// The version of the app bundle holding `executable`, as "0.2.1 (3)", following symlinks such as the one Homebrew
/// links mntl through. Nil outside an app bundle.
public func bundleVersion(executable: URL) -> String? {
    let macOS = executable.resolvingSymlinksInPath().deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS",
          let info = Bundle(url: macOS.deletingLastPathComponent().deletingLastPathComponent())?.infoDictionary,
          let version = info["CFBundleShortVersionString"] as? String else { return nil }
    return (info["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
}

