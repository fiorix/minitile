import Foundation
import TOMLDecoder

/// A config error names the offending key; the shell should retain its previous Config.
public struct ConfigError: Error, Sendable, LocalizedError, CustomStringConvertible {
    public let key: String
    public let message: String
    public init(key: String, message: String) { self.key = key; self.message = message }
    public var description: String { "\(key): \(message)" }
    public var errorDescription: String? { description }
}

extension Chord {
    /// Parse modifiers plus one supported key, accepting case and modifier-order variations.
    public init(_ text: String) throws {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let key = parts.last, !key.isEmpty else { throw ConfigError(key: "bindings.\(text)", message: "Expected one key") }
        let names: [String: Modifiers] = ["ctrl": .ctrl, "shift": .shift, "alt": .alt, "cmd": .cmd]
        var modifiers: Modifiers = []
        for name in parts.dropLast() {
            guard let modifier = names[name], !modifiers.contains(modifier) else {
                throw ConfigError(key: "bindings.\(text)", message: "Unknown or repeated modifier \(name)")
            }
            modifiers.insert(modifier)
        }
        let single = key.utf8.count == 1 && key.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
        let named = ["left", "right", "up", "down", "return", "space", "tab", "escape"].contains(key)
        let function = key.first == "f" && Int(key.dropFirst()).map { (1...20).contains($0) && key == "f\($0)" } == true
        guard single || named || function else { throw ConfigError(key: "bindings.\(text)", message: "Unknown key \(key)") }
        self.init(modifiers: modifiers, key: key)
    }
}

private struct ConfigKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct ConfigFields: Decodable {
    var gaps: Double?
    var padding: Double?
    var floatApps: [String]?
    var onlyApps: [String]?
    var bindings: [String: String]?
    var transitionMs: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ConfigKey.self)
        let known = Set(["gaps", "padding", "float_apps", "only_apps", "bindings", "transition_ms"])
        for key in container.allKeys where !known.contains(key.stringValue) {
            throw ConfigError(key: key.stringValue, message: "Unknown config key")
        }
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
            do { return try container.decodeIfPresent(type, forKey: ConfigKey(name)) }
            catch { throw ConfigError(key: name, message: "Invalid value: \(error)") }
        }
        gaps = try decode(Double.self, "gaps")
        padding = try decode(Double.self, "padding")
        floatApps = try decode([String].self, "float_apps")
        onlyApps = try decode([String].self, "only_apps")
        bindings = try decode([String: String].self, "bindings")
        transitionMs = try decode(Double.self, "transition_ms")
    }
}

extension Config {
    /// Decode TOML contents without I/O. Nil means the file is absent and returns defaults.
    public static func parse(_ text: String?) throws -> Config {
        guard let text else { return .default }
        let fields: ConfigFields
        do { fields = try TOMLDecoder().decode(ConfigFields.self, from: text) }
        catch let error as ConfigError { throw error }
        catch { throw ConfigError(key: "TOML", message: String(describing: error)) }
        var config = Config()
        for (key, value) in [("gaps", fields.gaps), ("padding", fields.padding)] {
            if let value, !value.isFinite || value < 0 { throw ConfigError(key: key, message: "Expected finite nonnegative points") }
        }
        config.gaps = fields.gaps ?? config.gaps
        config.padding = fields.padding ?? config.padding
        if let ms = fields.transitionMs {
            guard ms.isFinite, (0...2000).contains(ms) else { throw ConfigError(key: "transition_ms", message: "Expected milliseconds from 0 to 2000") }
            config.transitionMs = ms
        }
        config.floatApps = fields.floatApps ?? []
        config.onlyApps = fields.onlyApps ?? []
        for (key, apps) in [("float_apps", config.floatApps), ("only_apps", config.onlyApps)] {
            guard apps.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
                throw ConfigError(key: key, message: "Expected nonempty bundle IDs without surrounding whitespace")
            }
        }
        var seen = Set<Chord>()
        for (raw, command) in (fields.bindings ?? [:]).sorted(by: { $0.key < $1.key }) {
            let chord = try Chord(raw)
            guard seen.insert(chord).inserted else { throw ConfigError(key: "bindings.\(raw)", message: "Duplicate normalized chord") }
            if command.isEmpty { config.bindings.removeValue(forKey: chord); continue }
            let argv = command.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !argv.isEmpty else { throw ConfigError(key: "bindings.\(raw)", message: "Expected a command or an empty string to unbind") }
            config.bindings[chord] = argv
        }
        return config
    }
}
