import Foundation
import Testing
@testable import MinitileCore

@Test func bootstrapCore() { _ = Engine() }

@Test func savedStateUsesValueTypesAndRoundTrips() throws {
    var state = SavedState()
    state.windows[42] = WindowState(info: WindowInfo(id: 42, pid: 7), display: "display", floating: false)
    state.focus = 42
    let data = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(SavedState.self, from: data) == state)
}

@Test func defaultBindingsUseCommandArguments() {
    #expect(Config.default.bindings[Chord(modifiers: [.ctrl, .shift], key: "down")] == ["window", "move", "workspace", "next"])
    #expect(Config.default.bindings[Chord(modifiers: .cmd, key: "`")] == ["window", "focus", "next"])
    #expect(Config.default.bindings[Chord(modifiers: [.cmd, .shift], key: "`")] == ["window", "focus", "prev"])
    #expect(Config.default.bindings[Chord(modifiers: .cmd, key: "tab")] == ["switcher", "next"])
    #expect(Config.default.bindings[Chord(modifiers: [.cmd, .shift], key: "tab")] == ["switcher", "prev"])
    #expect(Config.default.bindings.count == 13)
}

@Test func displayMetadataDefaultsToFullFrame() {
    let frame = Rect(x: -100, y: 30, width: 800, height: 600)
    let display = DisplayInfo(id: "display", frame: frame)
    #expect(display.visibleFrame == frame)
    #expect(display.unmanagedReason == nil)
    #expect(frame.contains(Point(x: -100, y: 30)))
    #expect(!frame.contains(Point(x: 700, y: 30)))
}
