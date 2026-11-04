import Testing
@testable import MinitileCore

@Test func absentAndEmptyConfigUseDefaults() throws {
    #expect(try Config.parse(nil) == .default)
    #expect(try Config.parse("") == .default)
    #expect(try Config.parse("# comment\n[bindings]\n") == .default)
}

@Test func configDecodesEveryKeyAndMergesBindings() throws {
    let config = try Config.parse("""
    gaps = 12
    padding = 3.5
    float_apps = ["com.example.float"]
    only_apps = ["com.apple.TextEdit"]
    [bindings]
    "ctrl+left" = ""
    "shift+CMD+f20" = "window float on"
    "ctrl+right" = "workspace next"
    "alt+a" = "debug spaces"
    """)
    #expect(config.gaps == 12)
    #expect(config.padding == 3.5)
    #expect(config.floatApps == ["com.example.float"])
    #expect(config.onlyApps == ["com.apple.TextEdit"])
    #expect(config.bindings[try Chord("ctrl+left")] == nil)
    #expect(config.bindings[try Chord("ctrl+down")] == ["workspace", "next"])
    #expect(config.bindings[try Chord("cmd+shift+f20")] == ["window", "float", "on"])
    #expect(config.bindings[try Chord("ctrl+right")] == ["workspace", "next"])
    #expect(config.bindings[try Chord("alt+a")] == ["debug", "spaces"])
}

@Test(arguments: ["a", "9", "ctrl+left", "cmd+shift+alt+ctrl+f1", "F20", " return ", "alt+escape", "cmd+space", "shift+tab", "cmd+`", "`"])
func validChordsRoundTripCanonicalText(_ text: String) throws {
    let chord = try Chord(text)
    #expect(try Chord(chord.description) == chord)
}

@Test func backtickKeyParsesAndDisplaysCanonically() throws {
    #expect(try Chord("CMD + Shift + `") == Chord(modifiers: [.cmd, .shift], key: "`"))
    #expect(try Chord("cmd+shift+`").description == "shift+cmd+`")
    let config = try Config.parse("""
    [bindings]
    "cmd+`" = ""
    "alt+`" = "window focus prev"
    """)
    #expect(config.bindings[try Chord("cmd+`")] == nil)
    #expect(config.bindings[try Chord("shift+cmd+`")] == ["window", "focus", "prev"])
    #expect(config.bindings[try Chord("alt+`")] == ["window", "focus", "prev"])
}

@Test(arguments: ["", "ctrl", "ctrl+", "+a", "ctrl+ctrl+a", "fn+left", "hyper+a", "a+b", "f0", "f21", "f01", "é", "cmd++", "cmd+``", "cmd+~", "cmd+'"])
func invalidChordsNameBinding(_ text: String) {
    do { _ = try Chord(text); Issue.record("Expected invalid chord") }
    catch let error as ConfigError { #expect(error.key.hasPrefix("bindings.")) }
    catch { Issue.record("Expected ConfigError") }
}

@Test(arguments: [
    ("gaps = -1", "gaps"), ("padding = nan", "padding"), ("gaps = inf", "gaps"),
    ("padding = 'bad'", "padding"), ("float_apps = [3]", "float_apps"),
    ("transition_ms = -1", "transition_ms"), ("transition_ms = 2001", "transition_ms"),
    ("transition_ms = nan", "transition_ms"), ("transition_ms = 'fast'", "transition_ms"),
    ("trackpad_swipes = 1", "trackpad_swipes"), ("trackpad_swipes = 'no'", "trackpad_swipes"),
    ("only_apps = ['']", "only_apps"), ("other = 3", "other"),
    ("[bindings]\n'ctrl+a' = 3", "bindings"),
    ("[bindings]\n'ctrl+a' = '   '", "bindings.ctrl+a"),
    ("[bindings]\n'ctrl+shift+a' = 'help'\n'shift+ctrl+a' = 'state'", "bindings."),
])
func configErrorsNameTheKey(_ test: (String, String)) {
    do { _ = try Config.parse(test.0); Issue.record("Expected invalid config") }
    catch let error as ConfigError { #expect(error.key.contains(test.1)) }
    catch { Issue.record("Expected ConfigError") }
}

@Test func parseFailureLeavesPriorEngineConfigIntact() {
    var e = engine(1, config: Config(gaps: 22))
    do { _ = try Config.parse("gaps = -1"); Issue.record("Expected parse error") } catch {}
    #expect(e.config.gaps == 22)
    _ = e.handle(.configLoaded(Config(gaps: 4)))
    #expect(e.config.gaps == 4)
}

@Test func transitionDurationDefaultsAndAcceptsZeroAndBounds() throws {
    #expect(Config.default.transitionMs == 500)
    #expect(try Config.parse("transition_ms = 0").transitionMs == 0)
    #expect(try Config.parse("transition_ms = 250.5").transitionMs == 250.5)
    #expect(try Config.parse("transition_ms = 2000").transitionMs == 2000)
    var e = engine(1)
    _ = e.handle(.configLoaded(try Config.parse("transition_ms = 300")))
    guard case .object(let fields)? = command(&e, "config info").reply?.data else { Issue.record("Expected config object"); return }
    #expect(fields["transition_ms"] == .number(300))
}

@Test func trackpadSwipesDefaultOnAndShowInConfigInfo() throws {
    #expect(Config.default.trackpadSwipes)
    #expect(try Config.parse("gaps = 4").trackpadSwipes)
    #expect(try Config.parse("trackpad_swipes = true").trackpadSwipes)
    let off = try Config.parse("trackpad_swipes = false")
    #expect(!off.trackpadSwipes)
    var e = engine(1)
    guard case .object(let on)? = command(&e, "config list").reply?.data else { Issue.record("Expected config object"); return }
    #expect(on["trackpad_swipes"] == .bool(true))
    _ = e.handle(.configLoaded(off))
    guard case .object(let fields)? = command(&e, "config info").reply?.data else { Issue.record("Expected config object"); return }
    #expect(fields["trackpad_swipes"] == .bool(false))
}
