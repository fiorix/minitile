import Foundation
import Darwin

/// Newline-delimited JSON server. All mutable state and socket sources belong to `io`.
public final class Server: @unchecked Sendable {
    public typealias Completion = @Sendable (Reply) -> Void
    public typealias Handler = @Sendable ([String], @escaping Completion) -> Void

    private let path: String
    private let handlerQueue: DispatchQueue
    private let handler: Handler
    private let io = DispatchQueue(label: "minitile.ipc")
    private var listener: DispatchSourceRead?
    private var identity: stat?
    private var connections: [Int32: Connection] = [:]

    // Sources and handler completions capture connections across queues; fields are used only on io.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        let reader: DispatchSourceRead
        let writer: DispatchSourceWrite
        var writing = false
        var input = Data()
        var output = Data()
        var offset = 0
        var handled = false
        var replied = false
        var watching = false
        var closeAfterWrite = false

        init(fd: Int32, queue: DispatchQueue) {
            self.fd = fd
            reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        }
    }

    /// Construction does not bind. The handler runs on the supplied queue; use MainActor.assumeIsolated with `.main`.
    public init(path: String, handlerQueue: DispatchQueue, handler: @escaping Handler) {
        self.path = path
        self.handlerQueue = handlerQueue
        self.handler = handler
    }

    /// Bind a mode-0600 socket, rejecting live instances and preserving non-socket paths.
    public func start() throws {
        try io.sync {
            guard listener == nil else { throw IPCError.alreadyRunning }
            var addr = try address(path)
            var existing = stat()
            if lstat(path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid() else {
                    throw IPCError.system("socket path is not an owned socket", EEXIST)
                }
                let probe = try makeSocket(nonblocking: true)
                let result = withAddress(&addr) { Darwin.connect(probe, $0, $1) }
                let code = errno
                Darwin.close(probe)
                guard result != 0, code == ECONNREFUSED || code == ENOENT else { throw IPCError.alreadyRunning }
                var current = stat()
                if lstat(path, &current) == 0 {
                    guard current.st_ino == existing.st_ino, current.st_dev == existing.st_dev else {
                        throw IPCError.alreadyRunning
                    }
                    guard unlink(path) == 0 else { throw IPCError.system("unlink stale socket", errno) }
                }
            } else if errno != ENOENT {
                throw IPCError.system("inspect socket path", errno)
            }
            let fd = try makeSocket(nonblocking: true)
            do {
                guard withAddress(&addr, { Darwin.bind(fd, $0, $1) }) == 0 else {
                    throw IPCError.system("bind", errno)
                }
                var bound = stat()
                guard lstat(path, &bound) == 0 else { throw IPCError.system("inspect bound socket", errno) }
                identity = bound
                guard chmod(path, 0o600) == 0, Darwin.listen(fd, 128) == 0 else {
                    throw IPCError.system("listen", errno)
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
                source.setEventHandler { [weak self] in self?.acceptClients(fd) }
                source.setCancelHandler { Darwin.close(fd) }
                listener = source
                source.resume()
            } catch {
                Darwin.close(fd)
                removeOwnedPath()
                throw error
            }
        }
    }

    /// Stop accepting and disconnect all clients. Safe to call repeatedly.
    public func stop() {
        io.sync {
            listener?.cancel()
            listener = nil
            for connection in Array(connections.values) { disconnect(connection) }
            removeOwnedPath()
        }
    }

    /// Enqueue an event without blocking the caller. Slow watchers are dropped above 4 MiB of pending output.
    public func broadcast(event: Event) {
        io.async { [weak self] in
            guard let self, let data = try? jsonLine(event) else { return }
            for connection in Array(self.connections.values) where connection.watching {
                self.enqueue(data, on: connection)
            }
        }
    }

    private func removeOwnedPath() {
        defer { identity = nil }
        guard let identity else { return }
        var current = stat()
        if lstat(path, &current) == 0, current.st_ino == identity.st_ino, current.st_dev == identity.st_dev {
            unlink(path)
        }
    }

    private func acceptClients(_ listenerFD: Int32) {
        while true {
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            var yes: Int32 = 1
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
                Darwin.close(fd)
                continue
            }
            let connection = Connection(fd: fd, queue: io)
            connections[fd] = connection
            connection.reader.setEventHandler { [weak self] in self?.read(connection) }
            connection.writer.setEventHandler { [weak self] in self?.flush(connection) }
            let cancelled = DispatchGroup()
            cancelled.enter()
            cancelled.enter()
            connection.reader.setCancelHandler { cancelled.leave() }
            connection.writer.setCancelHandler { cancelled.leave() }
            cancelled.notify(queue: io) { Darwin.close(fd) }
            connection.reader.resume()
        }
    }

    private func disconnect(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.fd) != nil else { return }
        connection.reader.cancel()
        if !connection.writing { connection.writer.resume() }
        connection.writer.cancel()
    }

    private func read(_ connection: Connection) {
        guard connections[connection.fd] === connection else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.recv(connection.fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            if count == 0 {
                connection.reader.cancel()
                if !connection.handled { respond(Reply(ok: false, text: "Expected a newline-terminated request"), to: connection) }
                return
            }
            if count < 0 { disconnect(connection); return }
            if connection.handled { continue }
            connection.input.append(contentsOf: bytes.prefix(count))
            let end = connection.input.firstIndex(of: 10)
            if (end.map { connection.input.distance(from: connection.input.startIndex, to: $0) } ?? connection.input.count) > requestLimit {
                respond(Reply(ok: false, text: "Request exceeds 64 KiB"), to: connection)
                return
            }
            guard let end else { continue }
            connection.handled = true
            let line = Data(connection.input[..<end])
            connection.input.removeAll()
            guard let request = try? JSONDecoder().decode(Request.self, from: line) else {
                respond(Reply(ok: false, text: "Expected a JSON object with argv: [string]"), to: connection)
                return
            }
            handlerQueue.async { [weak self] in
                guard let self else { return }
                self.handler(request.argv) { [weak self] reply in
                    guard let self else { return }
                    self.io.async {
                        guard self.connections[connection.fd] === connection, !connection.replied else { return }
                        connection.watching = request.argv == ["watch"] && reply.ok
                        self.respond(reply, to: connection)
                    }
                }
            }
            return
        }
    }

    private func respond(_ reply: Reply, to connection: Connection) {
        connection.handled = true
        connection.replied = true
        connection.closeAfterWrite = !connection.watching
        guard let data = try? jsonLine(reply) else { disconnect(connection); return }
        enqueue(data, on: connection)
    }

    private func enqueue(_ data: Data, on connection: Connection) {
        guard connections[connection.fd] === connection else { return }
        if connection.offset > 0 {
            connection.output.removeFirst(connection.offset)
            connection.offset = 0
        }
        if connection.watching && connection.output.count + data.count > 4 * 1024 * 1024 {
            disconnect(connection)
            return
        }
        connection.output.append(data)
        flush(connection)
    }

    private func flush(_ connection: Connection) {
        guard connections[connection.fd] === connection else { return }
        while connection.offset < connection.output.count {
            let count = connection.output.withUnsafeBytes { bytes in
                Darwin.send(connection.fd, bytes.baseAddress!.advanced(by: connection.offset), bytes.count - connection.offset, 0)
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if !connection.writing { connection.writing = true; connection.writer.resume() }
                return
            }
            if count <= 0 { disconnect(connection); return }
            connection.offset += count
        }
        connection.output.removeAll(keepingCapacity: false)
        connection.offset = 0
        if connection.writing { connection.writing = false; connection.writer.suspend() }
        if connection.closeAfterWrite { disconnect(connection) }
    }
}
