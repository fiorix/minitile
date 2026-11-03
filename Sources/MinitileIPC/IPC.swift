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

/// Newline-delimited JSON server. The handler runs only on `handlerQueue`; socket I/O never does.
public final class Server: Sendable {
    public typealias Completion = @Sendable (Reply) -> Void
    public typealias Handler = @Sendable ([String], @escaping Completion) -> Void

    /// Construction does not bind. Call `start()` once, and retain the server until `stop()`.
    public init(path: String, handlerQueue: DispatchQueue, handler: @escaping Handler) {}
    public func start() throws {}
    public func stop() {}
    /// Enqueue an event for all watch connections without blocking the caller.
    public func broadcast(event: Event) {}
}

/// Blocking socket client. Run streaming calls off the main thread.
public struct Client: Sendable {
    public var path: String
    public init(path: String) { self.path = path }
    public func request(_ argv: [String]) throws -> Reply { Reply(ok: false, text: "Not implemented") }
    /// Delivers the initial reply and then events until EOF or `onEvent` returns false.
    public func watch(onReply: (Reply) -> Void, onEvent: (Event) -> Bool) throws {}
}
