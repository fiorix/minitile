import Foundation

/// A JSON value with no Foundation reference types in the wire contract.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let b = try? value.decode(Bool.self) { self = .bool(b) }
        else if let n = try? value.decode(Double.self) { self = .number(n) }
        else if let s = try? value.decode(String.self) { self = .string(s) }
        else if let a = try? value.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let b): try value.encode(b)
        case .number(let n): try value.encode(n)
        case .string(let s): try value.encode(s)
        case .array(let a): try value.encode(a)
        case .object(let o): try value.encode(o)
        }
    }

    /// Convert a Codable model to its JSON representation.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

/// A command response. `data` is always present, including null on errors.
public struct Reply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var text: String
    public var data: JSONValue

    public init(ok: Bool = true, text: String = "", data: JSONValue = .null) {
        self.ok = ok
        self.text = text
        self.data = data
    }
}

/// One watch notification, encoded as a JSON line after the initial reply.
public struct Event: Codable, Sendable, Equatable {
    public var type: String
    public var data: JSONValue

    public init(type: String, data: JSONValue = .null) {
        self.type = type
        self.data = data
    }
}
