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
