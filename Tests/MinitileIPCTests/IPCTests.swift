import Foundation
import Testing
@testable import MinitileIPC

@Test func replyAlwaysEncodesData() throws {
    let reply = Reply(ok: false, text: "Expected a command")
    let bytes = try JSONEncoder().encode(reply)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["data"] is NSNull)
    #expect(try JSONDecoder().decode(Reply.self, from: bytes) == reply)
}

@Test func jsonValueRoundTripsNestedValues() throws {
    let value: JSONValue = .object(["nested": .array([.bool(true), .number(42), .string("line\nline"), .null])])
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
}

@Test func socketPathHonorsOverride() throws {
    #expect(try socketPath(environment: ["MINITILE_SOCKET": "/tmp/test.sock"]) == "/tmp/test.sock")
    #expect(try socketPath(environment: [:]).hasSuffix("/minitile.sock"))
}

@Test func bundleVersionReadsTheAppHoldingTheExecutableThroughSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "mntl-version-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let macOS = root.appending(path: "Minitile.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "app.minitile.test", "CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "3"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: macOS.deletingLastPathComponent().appending(path: "Info.plist"))
    let executable = macOS.appending(path: "mntl")
    try Data().write(to: executable)
    let link = root.appending(path: "mntl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
    #expect(bundleVersion(executable: executable) == "0.2.1 (3)")
    #expect(bundleVersion(executable: link) == "0.2.1 (3)")
    #expect(bundleVersion(executable: root.appending(path: "elsewhere/mntl")) == nil)
}
