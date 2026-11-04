import AppKit
import Carbon
import CSkyLight
import MinitileCore

struct NativeChord: Hashable {
    var keycode: UInt16
    var modifiers: Modifiers
}

enum KeyDecision: Equatable, Sendable { case pass, swallow, command([String]) }

struct KeyTrace: Sendable {
    var time: TimeInterval
    var keycode: UInt16
    var flags: UInt64
    var down: Bool
}

struct KeyTraceFilter {
    private var held: Set<UInt16> = []

    mutating func includes(_ code: UInt16, modifiers: Modifiers, down: Bool) -> Bool {
        guard (123...126).contains(code) else { return false }
        if !down { return held.remove(code) != nil || modifiers.contains(.ctrl) }
        if modifiers.contains(.ctrl) { held.insert(code) }
        return held.contains(code)
    }
}

struct KeyRouter {
    var bindings: [Chord: [String]] = [:]
    var names: [UInt16: String] = [:]
    var blocked: Set<NativeChord> = []
    var dragged: WindowID?
    private var swallowed: Set<UInt16> = []

    static func modifiers(_ flags: CGEventFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.maskControl) { result.insert(.ctrl) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.alt) }
        if flags.contains(.maskCommand) { result.insert(.cmd) }
        return result
    }

    mutating func resetHeld() { swallowed.removeAll() }

    mutating func key(_ code: UInt16, modifiers: Modifiers, down: Bool, autorepeat: Bool = false) -> KeyDecision {
        if !down { return swallowed.remove(code) != nil ? .swallow : .pass }
        if autorepeat, swallowed.contains(code) { return .swallow }
        if !autorepeat { swallowed.remove(code) }
        let chord = names[code].map { Chord(modifiers: modifiers, key: $0) }
        var command: [String]?
        if let dragged, modifiers == .ctrl, let name = names[code] {
            switch name {
            case "left", "right": command = ["window", "nudge", String(dragged), name]
            case "up", "down": command = ["window", "move", String(dragged), "workspace", name == "up" ? "prev" : "next"]
            default: break
            }
        }
        command = command ?? chord.flatMap { bindings[$0] }
        if let command, !command.isEmpty {
            swallowed.insert(code)
            return autorepeat ? .swallow : .command(command)
        }
        if blocked.contains(NativeChord(keycode: code, modifiers: modifiers)) {
            swallowed.insert(code); return .swallow
        }
        return .pass
    }
}

final class KeyboardTap: @unchecked Sendable {
    // All shared state is under lock. The callback only matches a value snapshot;
    // AX, commands and WindowServer operations run on the main thread.
    private let lock = NSLock()
    private var router = KeyRouter()
    private var traceFilter = KeyTraceFilter()
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var stopping = false
    private var failed = false
    let traceEnabled: Bool
    private let handle: @MainActor @Sendable (KeyDecision, KeyTrace?) -> Void

    init(traceEnabled: Bool = false, handle: @escaping @MainActor @Sendable (KeyDecision, KeyTrace?) -> Void) {
        self.traceEnabled = traceEnabled
        self.handle = handle
    }

    @MainActor func update(config: Config, displays: DisplayCatalog, dragged: WindowID?) {
        var blocked = Set<NativeChord>()
        for display in displays.displays {
            guard display.info.unmanagedReason == nil, let stash = display.info.stashSpace,
                  let number = displays.desktopNumbers[stash] else { continue }
            var key: UInt16 = 0, modifiers: UInt32 = 0, enabled = false
            if csl_symbolic_hotkey(Int32(118 + number - 1), &key, &modifiers, &enabled), enabled {
                blocked.insert(NativeChord(keycode: key, modifiers: KeyRouter.modifiers(CGEventFlags(rawValue: UInt64(modifiers)))))
            }
        }
        let names = Self.keyNames()
        lock.withLock { router.bindings = config.bindings; router.names = names; router.blocked = blocked; router.dragged = dragged }
    }

    func drag(_ id: WindowID?) { lock.withLock { router.dragged = id } }

    var unavailable: Bool { lock.withLock { failed } }

    func start() {
        let thread = Thread { [self] in
            let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyboardTap>.fromOpaque(pointer).takeUnretainedValue().receive(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
                  let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                lock.withLock { failed = true }; return
            }
            let runLoop = CFRunLoopGetCurrent()!
            let shouldStop = lock.withLock { port = tap; loop = runLoop; return stopping }
            if !shouldStop {
                CFRunLoopAddSource(runLoop, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                CFRunLoopRun()
                CGEvent.tapEnable(tap: tap, enable: false)
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFMachPortInvalidate(tap)
            lock.withLock { port = nil; loop = nil }
        }
        thread.name = "minitile.keys"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        let values = lock.withLock { stopping = true; return (port, loop) }
        if let port = values.0 { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop = values.1 { CFRunLoopStop(loop) }
    }

    func checkHealth() {
        guard let port = lock.withLock({ port }), !CGEvent.tapIsEnabled(tap: port) else { return }
        resetHeld()
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func resetHeld() {
        lock.withLock { router.resetHeld(); traceFilter = KeyTraceFilter() }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetHeld()
            if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let down = type == .keyDown
        let flags = event.flags.rawValue
        let modifiers = KeyRouter.modifiers(event.flags)
        let (decision, trace): (KeyDecision, KeyTrace?) = lock.withLock {
            let decision = router.key(code, modifiers: modifiers, down: down,
                                      autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            let trace = traceEnabled && traceFilter.includes(code, modifiers: modifiers, down: down)
                ? KeyTrace(time: ProcessInfo.processInfo.systemUptime, keycode: code, flags: flags, down: down) : nil
            return (decision, trace)
        }
        switch decision {
        case .command:
            DispatchQueue.main.async { [handle] in handle(decision, trace) }
        case .pass, .swallow:
            if trace != nil { DispatchQueue.main.async { [handle] in handle(decision, trace) } }
        }
        return decision == .pass ? Unmanaged.passUnretained(event) : nil
    }

    @MainActor private static func keyNames() -> [UInt16: String] {
        var names: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 49: "space", 48: "tab", 53: "escape"]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionKeys.enumerated() { names[code] = "f\(index + 1)" }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return names }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return names }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code: UInt16 in 0..<128 where names[code] == nil {
            var dead: UInt32 = 0, count = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, characters.count, &count, &characters)
            if result == noErr, count == 1, let scalar = UnicodeScalar(characters[0]),
               ("a"..."z").contains(String(scalar).lowercased()) || ("0"..."9").contains(String(scalar)) {
                names[code] = String(scalar).lowercased()
            }
        }
        return names
    }
}
