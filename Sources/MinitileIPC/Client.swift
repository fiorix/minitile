import Foundation
import Darwin

/// Blocking socket client. Run streaming calls off the main thread.
public struct Client: Sendable {
    public var path: String
    public init(path: String) { self.path = path }

    /// Send one request and read its reply. Transport errors throw; command errors return ok=false.
    public func request(_ argv: [String]) throws -> Reply {
        let fd = try connect()
        defer { Darwin.close(fd) }
        try send(argv, to: fd)
        var reader = LineReader()
        return try readReply(from: fd, reader: &reader)
    }

    /// Deliver the initial reply and then events until EOF or onEvent returns false.
    public func watch(onReply: (Reply) -> Void, onEvent: (Event) -> Bool) throws {
        let fd = try connect()
        defer { Darwin.close(fd) }
        try send(["watch"], to: fd)
        var reader = LineReader()
        let reply = try readReply(from: fd, reader: &reader)
        onReply(reply)
        guard reply.ok else { return }
        var unlimited = timeval(tv_sec: 0, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &unlimited, socklen_t(MemoryLayout.size(ofValue: unlimited))) == 0 else {
            throw IPCError.system("watch timeout", errno)
        }
        while let line = try reader.next(from: fd) {
            guard let event = try? JSONDecoder().decode(Event.self, from: line) else { throw IPCError.invalidResponse }
            if !onEvent(event) { return }
        }
    }

    private func connect() throws -> Int32 {
        var addr = try address(path)
        let fd = try makeSocket()
        do {
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                throw IPCError.system("socket timeout", errno)
            }
            guard withAddress(&addr, { Darwin.connect(fd, $0, $1) }) == 0 else { throw IPCError.system("connect", errno) }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func send(_ argv: [String], to fd: Int32) throws {
        let data = try jsonLine(Request(argv: argv))
        guard data.count - 1 <= requestLimit else { throw IPCError.requestTooLarge }
        try writeAll(data, to: fd)
    }

    private func readReply(from fd: Int32, reader: inout LineReader) throws -> Reply {
        guard let line = try reader.next(from: fd) else { throw IPCError.disconnected }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: line) else { throw IPCError.invalidResponse }
        return reply
    }
}
