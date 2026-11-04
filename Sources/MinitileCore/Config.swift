import Foundation

/// Only semantic modifiers participate in matching; the shell ignores fn/keypad flags.
public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let ctrl = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let alt = Modifiers(rawValue: 1 << 2)
    public static let cmd = Modifiers(rawValue: 1 << 3)
}

/// A normalized key name plus semantic modifiers, for event-tap matching.
public struct Chord: Codable, Sendable, Hashable {
    public var modifiers: Modifiers
    public var key: String
    public init(modifiers: Modifiers = [], key: String) { self.modifiers = modifiers; self.key = key }
}

extension Chord: CustomStringConvertible {
    public var description: String {
        let names: [(Modifiers, String)] = [(.ctrl, "ctrl"), (.shift, "shift"), (.alt, "alt"), (.cmd, "cmd")]
        return (names.filter { modifiers.contains($0.0) }.map(\.1) + [key]).joined(separator: "+")
    }
}

/// Validated configuration. Parse file contents outside `Engine.handle` and retain the old config on errors.
public struct Config: Sendable, Equatable {
    public var gaps: Double
    public var padding: Double
    public var floatApps: [String]
    public var onlyApps: [String]
    public var bindings: [Chord: [String]]
    /// Page slide duration in milliseconds; 0 turns slides and edge bounces off.
    public var transitionMs: Double = 500

    public init(gaps: Double = 8, padding: Double = 8, floatApps: [String] = [], onlyApps: [String] = [],
                bindings: [Chord: [String]] = Config.defaultBindings) {
        self.gaps = gaps; self.padding = padding; self.floatApps = floatApps
        self.onlyApps = onlyApps; self.bindings = bindings
    }

    public static let `default` = Config()
    public static let defaultBindings: [Chord: [String]] = [
        Chord(modifiers: .ctrl, key: "left"): ["page", "prev"],
        Chord(modifiers: .ctrl, key: "right"): ["page", "next"],
        Chord(modifiers: .ctrl, key: "up"): ["workspace", "prev"],
        Chord(modifiers: .ctrl, key: "down"): ["workspace", "next"],
        Chord(modifiers: [.ctrl, .shift], key: "left"): ["window", "nudge", "left"],
        Chord(modifiers: [.ctrl, .shift], key: "right"): ["window", "nudge", "right"],
        Chord(modifiers: [.ctrl, .shift], key: "up"): ["window", "move", "workspace", "prev"],
        Chord(modifiers: [.ctrl, .shift], key: "down"): ["window", "move", "workspace", "next"],
    ]
}
