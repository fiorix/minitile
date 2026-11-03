import Foundation
import Darwin
import Testing
@testable import MinitileIPC

private struct Fixture {
    let path = "/tmp/mt-\(UUID().uuidString.prefix(12)).sock"
    let server: Server
    var client: Client { Client(path: path) }

    init(handler: @escaping Server.Handler = { argv, done in done(Reply(text: argv.joined(separator: " "))) }) throws {
        server = Server(path: path, handlerQueue: DispatchQueue(label: "test.handler"), handler: handler)
        try server.start()
    }
}

private func rawConnect(_ path: String) throws -> Int32 {
    var addr = try address(path)
    let fd = try makeSocket()
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    guard withAddress(&addr, { Darwin.connect(fd, $0, $1) }) == 0 else {
        Darwin.close(fd)
        throw IPCError.system("test connect", errno)
    }
    return fd
}

@Test func socketRoundTripsSuccessAndCommandError() throws {
    let fixture = try Fixture { argv, done in
        done(Reply(ok: argv != ["bad"], text: argv.joined(separator: " "), data: .array(argv.map(JSONValue.string))))
    }
    defer { fixture.server.stop() }
    #expect(try fixture.client.request(["hello", "world"]) == Reply(text: "hello world", data: .array([.string("hello"), .string("world")])))
    #expect(try !fixture.client.request(["bad"]).ok)
    var status = stat()
    #expect(lstat(fixture.path, &status) == 0)
    #expect(status.st_mode & 0o777 == 0o600)
}

@Test(arguments: ["no json\n", "{\"argv\":42}\n", "{}\n", "[]\n"])
func malformedRequestsReceiveAnErrorAndClose(_ input: String) throws {
    let fixture = try Fixture()
    defer { fixture.server.stop() }
    let fd = try rawConnect(fixture.path)
    defer { Darwin.close(fd) }
    try writeAll(Data(input.utf8), to: fd)
    var reader = LineReader()
    let line = try reader.next(from: fd)
    let bytes = try #require(line)
    let reply = try JSONDecoder().decode(Reply.self, from: bytes)
    #expect(!reply.ok)
    #expect(reply.text.contains("argv"))
    #expect(try reader.next(from: fd) == nil)
}

@Test func oversizedRequestIsRejectedWithoutWaitingForNewline() throws {
    let fixture = try Fixture()
    defer { fixture.server.stop() }
    let fd = try rawConnect(fixture.path)
    defer { Darwin.close(fd) }
    try writeAll(Data(repeating: 32, count: requestLimit + 1), to: fd)
    var reader = LineReader()
    let line = try reader.next(from: fd)
    let reply = try JSONDecoder().decode(Reply.self, from: #require(line))
    #expect(!reply.ok)
    #expect(reply.text.contains("64 KiB"))
}

@Test func exactRequestLimitAndSplitFraming() throws {
    let fixture = try Fixture()
    defer { fixture.server.stop() }
    let fd = try rawConnect(fixture.path)
    defer { Darwin.close(fd) }
    let prefix = "{\"argv\":[\""
    let suffix = "\"]}"
    let text = String(repeating: "x", count: requestLimit - prefix.utf8.count - suffix.utf8.count)
    try writeAll(Data(prefix.utf8), to: fd)
    try writeAll(Data((text + suffix + "\n").utf8), to: fd)
    var reader = LineReader()
    let line = try reader.next(from: fd)
    let reply = try JSONDecoder().decode(Reply.self, from: #require(line))
    #expect(reply.ok)
    #expect(reply.text == text)
}

@Test func concurrentClientsHaveIndependentReplies() async throws {
    let fixture = try Fixture()
    defer { fixture.server.stop() }
    let replies = try await withThrowingTaskGroup(of: String.self) { group in
        for i in 0..<8 { group.addTask { try fixture.client.request([String(i)]).text } }
        var results = Set<String>()
        for try await reply in group { results.insert(reply) }
        return results
    }
    #expect(replies == Set((0..<8).map(String.init)))
}

@Test func watcherReceivesOrderedEventsAfterReply() throws {
    let fixture = try Fixture()
    defer { fixture.server.stop() }
    var events: [Event] = []
    try fixture.client.watch(onReply: { reply in
        #expect(reply.ok)
        fixture.server.broadcast(event: Event(type: "first", data: .number(1)))
        fixture.server.broadcast(event: Event(type: "second", data: .number(2)))
    }, onEvent: { event in
        events.append(event)
        return events.count < 2
    })
    #expect(events == [Event(type: "first", data: .number(1)), Event(type: "second", data: .number(2))])
    #expect(try fixture.client.request(["still", "alive"]).ok)
}

@Test func staleSocketIsReplacedAndRemovedOnStop() throws {
    let path = "/tmp/mt-\(UUID().uuidString.prefix(12)).sock"
    var addr = try address(path)
    let fd = try makeSocket()
    #expect(withAddress(&addr, { Darwin.bind(fd, $0, $1) }) == 0)
    Darwin.close(fd)
    let server = Server(path: path, handlerQueue: .global()) { _, done in done(Reply()) }
    try server.start()
    #expect(try Client(path: path).request(["help"]).ok)
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func liveSocketRejectsSecondServer() throws {
    let fixture = try Fixture()
    defer { fixture.server.stop() }
    let second = Server(path: fixture.path, handlerQueue: .global()) { _, done in done(Reply()) }
    #expect(throws: IPCError.self) { try second.start() }
    second.stop()
    #expect(try fixture.client.request(["first"]).text == "first")
}

@Test func regularFileAtSocketPathIsPreserved() throws {
    let path = "/tmp/mt-\(UUID().uuidString.prefix(12)).sock"
    try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }
    let server = Server(path: path, handlerQueue: .global()) { _, done in done(Reply()) }
    #expect(throws: IPCError.self) { try server.start() }
    server.stop()
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
}

@Test func slowWatcherDoesNotBlockOtherClients() throws {
    let fixture = try Fixture()
    defer { fixture.server.stop() }
    let fd = try rawConnect(fixture.path)
    defer { Darwin.close(fd) }
    try writeAll(Data("{\"argv\":[\"watch\"]}\n".utf8), to: fd)
    var reader = LineReader()
    #expect(try reader.next(from: fd) != nil)
    for _ in 0..<6 {
        fixture.server.broadcast(event: Event(type: "large", data: .string(String(repeating: "x", count: 1024 * 1024))))
    }
    #expect(try fixture.client.request(["responsive"]).text == "responsive")
}

@Test func invalidSocketPathsFail() {
    #expect(throws: IPCError.self) { try Client(path: String(repeating: "x", count: 104)).request([]) }
    #expect(throws: IPCError.self) { try Client(path: "/tmp/a\0b").request([]) }
}

@Test func halfClosedRequestStillReceivesItsReply() throws {
    let fixture = try Fixture()
    defer { fixture.server.stop() }
    let fd = try rawConnect(fixture.path)
    defer { Darwin.close(fd) }
    try writeAll(Data("{\"argv\":[\"done\"]}\n".utf8), to: fd)
    #expect(shutdown(fd, SHUT_WR) == 0)
    var reader = LineReader()
    let line = try reader.next(from: fd)
    let reply = try JSONDecoder().decode(Reply.self, from: #require(line))
    #expect(reply.text == "done")
}

@Test func largeReplyHandlesPartialWrites() throws {
    let payload = String(repeating: "x", count: 1024 * 1024)
    let fixture = try Fixture { _, done in done(Reply(text: payload)) }
    defer { fixture.server.stop() }
    #expect(try fixture.client.request(["large"]).text == payload)
}

private func runCLI(_ args: [String]) throws -> (Int32, String, String) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [".build/out/Products/Debug/mntl", ".build/debug/mntl"].map { root.appendingPathComponent($0) }
    let executable = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    let process = Process()
    let stdout = Pipe(), stderr = Pipe()
    process.executableURL = executable
    process.arguments = args
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

@Test func cliPrintsTextAndJSONAndUsesAllExitStatuses() throws {
    let fixture = try Fixture { argv, done in
        done(Reply(ok: argv != ["bad"], text: argv.joined(separator: " "), data: .object(["value": .number(42)])))
    }
    defer { fixture.server.stop() }
    let plain = try runCLI(["--socket", fixture.path, "window", "list"])
    #expect(plain.0 == 0)
    #expect(plain.1 == "window list\n")
    let json = try runCLI(["--json", "--socket", fixture.path, "state"])
    #expect(json.0 == 0)
    #expect(json.1 == "{\"value\":42}\n")
    let help = try runCLI(["--socket", fixture.path])
    #expect(help.0 == 0)
    #expect(help.1 == "help\n")
    #expect(try runCLI(["--socket", fixture.path, "bad"]).0 == 1)
    let missing = try runCLI(["--socket", fixture.path + ".missing"])
    #expect(missing.0 == 2)
    #expect(missing.2.contains("Usage: mntl"))
}
