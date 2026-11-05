import AppKit
import Carbon
import CSkyLight
import MinitileCore

struct NativeChord: Hashable {
    var keycode: UInt16
    var modifiers: Modifiers
}

enum StashShortcuts {
    static func ids(spaces: [NativeSpace], current: UInt64, stash: UInt64, desktopNumber: Int?) -> Set<Int32> {
        var ids: Set<Int32> = desktopNumber.map { [Int32(118 + $0 - 1)] } ?? []
        guard let index = spaces.firstIndex(where: { $0.id == current }) else { return ids }
        if index > 0, spaces[index - 1].id == stash { ids.insert(79) }
        if index + 1 < spaces.count, spaces[index + 1].id == stash { ids.insert(81) }
        return ids
    }
}

/// The "`" key is the key of macOS's Move focus to next window shortcut, so it follows the keyboard layout.
enum CycleKey {
    static let name = "`"
    static let hotkey: Int32 = 27
    static let fallback: UInt16 = 50

    /// A key that already has a name keeps it, so remapping the native shortcut onto a letter cannot steal its bindings.
    static func named(_ names: [UInt16: String], hotkey: UInt16?) -> [UInt16: String] {
        let code = hotkey.flatMap { $0 < 128 ? $0 : nil } ?? fallback
        var result = names
        if result[code] == nil { result[code] = name }
        return result
    }
}

enum SwitcherKey: Equatable, Sendable {
    /// `held` are the opening binding's modifiers other than Shift; releasing one commits. Empty keeps it open.
    case open(forward: Bool, held: Modifiers)
    case step(forward: Bool)
    case move(SwitcherDirection)
    case commit
    case cancel
}

enum HelpKey: Equatable, Sendable {
    case open
    case close
}

/// A switcher or help decision carries the session it belongs to, so the main thread can drop ones for a screen that
/// has closed. A command from a grabbing binding carries the grab's session, which `grabReleased` ends.
enum KeyDecision: Equatable, Sendable {
    case pass, swallow
    case command([String], grab: Int? = nil)
    case switcher(SwitcherKey, session: Int)
    case help(HelpKey, session: Int)
    case grabReleased(Int)

    /// The route and arguments for key traces and logs.
    var route: (name: String, argv: [String]) {
        switch self {
        case .pass: ("pass", [])
        case .swallow: ("swallow", [])
        case .command(let command, _): ("command", command)
        case .switcher(let key, _): ("switcher", [String(describing: key)])
        case .help(let key, _): ("help", [String(describing: key)])
        case .grabReleased: ("grab_released", [])
        }
    }
}

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
    /// The screens that take the keyboard while open. At most one is open: opening one replaces the other.
    enum Modal: Equatable, Sendable { case switcher, help }

    struct OpenModal: Equatable {
        var kind: Modal
        var session: Int
        /// The switcher's opening modifiers other than Shift; help always leaves these empty.
        var held: Modifiers
    }

    /// A grab started by a binding, held while all of the binding's modifiers are.
    struct HeldGrab: Equatable {
        var session: Int
        var held: Modifiers
    }

    var bindings: [Chord: [String]] = [:]
    var names: [UInt16: String] = [:]
    var blocked: Set<NativeChord> = []
    var dragged: WindowID?
    var frontmostManaged = true
    /// Started and not suspended. Otherwise the switcher's bindings pass, so Cmd+Tab reaches macOS.
    var switcherAvailable = false {
        didSet { if !switcherAvailable, modal?.kind == .switcher { modal = nil } }
    }
    /// Started and not suspended. Otherwise `help show` bindings pass, so Cmd+H hides the app.
    var helpAvailable = false {
        didSet { if !helpAvailable, modal?.kind == .help { modal = nil } }
    }
    private(set) var modal: OpenModal?
    var switcher: OpenModal? { modal?.kind == .switcher ? modal : nil }
    var help: OpenModal? { modal?.kind == .help ? modal : nil }
    private(set) var grab: HeldGrab?
    private var sessions = 0
    private var grabSessions = 0
    private var swallowed: Set<UInt16> = []
    /// Held keys whose press ran a repeating binding.
    private var repeating: Set<UInt16> = []

    /// Spelled out because the private state makes the memberwise initializer private before Swift 6.4.
    init(bindings: [Chord: [String]] = [:], names: [UInt16: String] = [:], blocked: Set<NativeChord> = [],
         dragged: WindowID? = nil) {
        self.bindings = bindings
        self.names = names
        self.blocked = blocked
        self.dragged = dragged
    }

    static func modifiers(_ flags: CGEventFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.maskControl) { result.insert(.ctrl) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.alt) }
        if flags.contains(.maskCommand) { result.insert(.cmd) }
        return result
    }

    /// Directional resize is the keyboard version of dragging an edge, so it repeats while its keys are held.
    static func repeats(_ argv: [String]) -> Bool {
        (3...4).contains(argv.count) && argv[0] == "window" && argv[1] == "resize"
            && ["left", "right", "up", "down"].contains(argv[argv.count - 1])
    }

    mutating func resetHeld() { swallowed.removeAll(); repeating.removeAll() }

    mutating func key(_ code: UInt16, modifiers: Modifiers, down: Bool, autorepeat: Bool = false) -> KeyDecision {
        if !down { repeating.remove(code); return swallowed.remove(code) != nil ? .swallow : .pass }
        // The open switcher takes its keys whatever the modifiers, repeats included.
        if let open = switcher, let key = Self.switcherKey(names[code], shift: modifiers.contains(.shift)) {
            swallowed.insert(code)
            if key == .commit || key == .cancel { modal = nil }
            return .switcher(key, session: open.session)
        }
        if let open = help, names[code] == "escape" {
            swallowed.insert(code)
            modal = nil
            return .help(.close, session: open.session)
        }
        if autorepeat, swallowed.contains(code), !repeating.contains(code) { return .swallow }
        if !autorepeat { swallowed.remove(code); repeating.remove(code) }
        // In apps minitile does not manage, the window-cycling key keeps its native meaning.
        let name = names[code].flatMap { $0 == CycleKey.name && !frontmostManaged ? nil : $0 }
        let chord = name.map { Chord(modifiers: modifiers, key: $0) }
        var command: [String]?
        if let dragged, modifiers == .ctrl, let name {
            switch name {
            case "left", "right": command = ["window", "nudge", String(dragged), name]
            case "up", "down": command = ["window", "move", String(dragged), "workspace", name == "up" ? "prev" : "next"]
            default: break
            }
        }
        // The pointer already holds a dragged window, so its keys never grab it.
        let bound = command == nil
        command = command ?? chord.flatMap { bindings[$0] }
        if let argv = command, argv.count == 2, argv[0] == "switcher", argv[1] == "next" || argv[1] == "prev" {
            if switcherAvailable {
                return switcherBinding(code, forward: argv[1] == "next", held: modifiers.subtracting(.shift), autorepeat: autorepeat)
            }
            command = nil
        }
        if command == ["help", "show"] {
            if helpAvailable { return helpBinding(code, autorepeat: autorepeat) }
            command = nil
        }
        // The switcher takes all keys; help leaves other shortcuts and bindings usable.
        if switcher != nil {
            swallowed.insert(code)
            return .swallow
        }
        if let command, !command.isEmpty {
            swallowed.insert(code)
            if !autorepeat {
                if Self.repeats(command) { repeating.insert(code) }
                return .command(command, grab: bound ? grabSession(command, modifiers) : nil)
            }
            // A held repeating binding runs again while its chord still names one; every other binding fires once.
            return repeating.contains(code) && Self.repeats(command) ? .command(command, grab: grabSession(command, modifiers)) : .swallow
        }
        if autorepeat, swallowed.contains(code) { return .swallow }
        if blocked.contains(NativeChord(keycode: code, modifiers: modifiers)) {
            swallowed.insert(code); return .swallow
        }
        return .pass
    }

    /// A switcher opened by a binding commits once one of its modifiers other than Shift is released.
    mutating func flags(_ modifiers: Modifiers) -> KeyDecision {
        guard let open = switcher, !open.held.isEmpty, !modifiers.isSuperset(of: open.held) else { return .pass }
        modal = nil
        return .switcher(.commit, session: open.session)
    }

    /// A grab started by a binding ends once any of the binding's modifiers, Shift included, is released.
    mutating func grabFlags(_ modifiers: Modifiers) -> KeyDecision {
        guard let open = grab, !modifiers.isSuperset(of: open.held) else { return .pass }
        grab = nil
        return .grabReleased(open.session)
    }

    /// A grabbing binding with modifiers holds its window while they are held. Further presses with the same
    /// modifiers, resize repeats included, continue the grab; without modifiers there is nothing to hold.
    private mutating func grabSession(_ command: [String], _ modifiers: Modifiers) -> Int? {
        guard !modifiers.isEmpty, GrabCommand.grabs(command) else { return nil }
        if let grab, grab.held == modifiers { return grab.session }
        grabSessions += 1
        grab = HeldGrab(session: grabSessions, held: modifiers)
        return grabSessions
    }

    /// The main thread opened a screen without a key, as `mntl switcher next` and `mntl help show` do; it stays open
    /// until closed.
    mutating func open(_ kind: Modal) -> Int {
        sessions += 1
        modal = OpenModal(kind: kind, session: sessions, held: [])
        return sessions
    }

    /// The main thread closed a screen. A newer session a key opened meanwhile stays open.
    mutating func close(_ session: Int) {
        if modal?.session == session { modal = nil }
    }

    /// A bound `switcher next|prev` opens the switcher, or steps it when it is already open. Repeats of a press that
    /// did not open it never do.
    private mutating func switcherBinding(_ code: UInt16, forward: Bool, held: Modifiers, autorepeat: Bool) -> KeyDecision {
        swallowed.insert(code)
        if let open = switcher { return .switcher(.step(forward: forward), session: open.session) }
        if autorepeat { return .swallow }
        sessions += 1
        modal = OpenModal(kind: .switcher, session: sessions, held: held)
        return .switcher(.open(forward: forward, held: held), session: sessions)
    }

    /// A bound `help show` toggles help, replacing an open switcher. Repeats never toggle it again.
    private mutating func helpBinding(_ code: UInt16, autorepeat: Bool) -> KeyDecision {
        swallowed.insert(code)
        if autorepeat { return .swallow }
        if let open = help {
            modal = nil
            return .help(.close, session: open.session)
        }
        sessions += 1
        modal = OpenModal(kind: .help, session: sessions, held: [])
        return .help(.open, session: sessions)
    }

    private static func switcherKey(_ name: String?, shift: Bool) -> SwitcherKey? {
        switch name {
        case "tab": .step(forward: !shift)
        case "left": .move(.left)
        case "right": .move(.right)
        case "up": .move(.up)
        case "down": .move(.down)
        case "return": .commit
        case "escape": .cancel
        default: nil
        }
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
    /// Every dispatched decision carries the uptime its event reached the tap, so the main thread can tell how long it
    /// waited.
    private let handle: @MainActor @Sendable (KeyDecision, KeyTrace?, TimeInterval) -> Void

    init(traceEnabled: Bool = false, handle: @escaping @MainActor @Sendable (KeyDecision, KeyTrace?, TimeInterval) -> Void) {
        self.traceEnabled = traceEnabled
        self.handle = handle
    }

    @MainActor func update(config: Config, displays: DisplayCatalog, dragged: WindowID?) {
        var blocked = Set<NativeChord>()
        for display in displays.displays {
            guard display.info.unmanagedReason == nil, let stash = display.info.stashSpace else { continue }
            let current = csl_current_space(display.identifier as CFString)
            for id in StashShortcuts.ids(spaces: display.spaces, current: current, stash: stash, desktopNumber: displays.desktopNumbers[stash]) {
                var key: UInt16 = 0, modifiers: UInt32 = 0, enabled = false
                if csl_symbolic_hotkey(id, &key, &modifiers, &enabled), enabled {
                    blocked.insert(NativeChord(keycode: key, modifiers: KeyRouter.modifiers(CGEventFlags(rawValue: UInt64(modifiers)))))
                }
            }
        }
        var key: UInt16 = 0, modifiers: UInt32 = 0, enabled = false
        let cycle = csl_symbolic_hotkey(CycleKey.hotkey, &key, &modifiers, &enabled) ? key : nil
        let names = CycleKey.named(Self.keyNames(), hotkey: cycle)
        lock.withLock { router.bindings = config.bindings; router.names = names; router.blocked = blocked; router.dragged = dragged }
    }

    func drag(_ id: WindowID?) { lock.withLock { router.dragged = id } }

    func frontmost(managed: Bool) { lock.withLock { router.frontmostManaged = managed } }

    func availability(switcher: Bool, help: Bool) {
        lock.withLock { router.switcherAvailable = switcher; router.helpAvailable = help }
    }

    func open(_ kind: KeyRouter.Modal) -> Int { lock.withLock { router.open(kind) } }

    func close(_ session: Int) { lock.withLock { router.close(session) } }

    /// Catches a modifier release the tap missed, as while macOS had it disabled.
    func checkModalModifiers() -> KeyDecision {
        let modifiers = KeyRouter.modifiers(CGEventSource.flagsState(.combinedSessionState))
        return lock.withLock { router.flags(modifiers) }
    }

    /// Whether the grab's binding modifiers are still held, rereading them in case the tap missed a release. False
    /// also when the router has moved on to another grab.
    func grabHeld(_ session: Int) -> Bool {
        let modifiers = KeyRouter.modifiers(CGEventSource.flagsState(.combinedSessionState))
        return lock.withLock { _ = router.grabFlags(modifiers); return router.grab?.session == session }
    }

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
            lock.withLock {
                port = nil; loop = nil
                if !stopping { failed = true }
                router.resetHeld()
                traceFilter = KeyTraceFilter()
            }
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
        let received = ProcessInfo.processInfo.systemUptime
        if type == .flagsChanged {
            let modifiers = KeyRouter.modifiers(event.flags)
            let decisions = lock.withLock { [router.flags(modifiers), router.grabFlags(modifiers)] }
            for decision in decisions where decision != .pass { DispatchQueue.main.async { [handle] in handle(decision, nil, received) } }
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
                ? KeyTrace(time: received, keycode: code, flags: flags, down: down) : nil
            return (decision, trace)
        }
        switch decision {
        case .command, .switcher, .help, .grabReleased:
            DispatchQueue.main.async { [handle] in handle(decision, trace, received) }
        case .pass, .swallow:
            if trace != nil { DispatchQueue.main.async { [handle] in handle(decision, trace, received) } }
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
        return withExtendedLifetime((source, data)) {
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
}
