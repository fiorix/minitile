import Foundation
import Darwin

let requestLimit = 64 * 1024

struct Request: Codable { var argv: [String] }

func address(_ path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    var result = sockaddr_un()
    guard !bytes.isEmpty, !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: result.sun_path) else {
        throw IPCError.invalidPath
    }
    result.sun_family = sa_family_t(AF_UNIX)
    result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &result.sun_path) { target in
        target.copyBytes(from: bytes + [0])
    }
    return result
}

func withAddress<T>(_ value: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &value) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

func makeSocket(nonblocking: Bool = false) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IPCError.system("socket", errno) }
    var yes: Int32 = 1
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
          !nonblocking || fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
        let error = errno
        Darwin.close(fd)
        throw IPCError.system("socket options", error)
    }
    return fd
}

func jsonLine<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(10)
    return data
}

func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw IPCError.system("send", errno) }
            offset += count
        }
    }
}

struct LineReader {
    var buffer = Data()

    mutating func next(from fd: Int32) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                return line
            }
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count == 0 {
                guard buffer.isEmpty else { throw IPCError.invalidResponse }
                return nil
            }
            guard count > 0 else { throw IPCError.system("recv", errno) }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}

extension IPCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPath: "Invalid Unix socket path (maximum 103 UTF-8 bytes)"
        case .system(let operation, let code): "\(operation): \(String(cString: strerror(code)))"
        case .alreadyRunning: "Another minitile instance is already running"
        case .invalidResponse: "Invalid response from minitile"
        case .requestTooLarge: "Request exceeds 64 KiB"
        case .disconnected: "minitile disconnected before replying"
        }
    }
}
