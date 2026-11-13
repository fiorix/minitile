import Testing
@testable import minitile

@Test func keyNamesReadOnceUntilTheInputSourceChanges() {
    var cache = KeyNameCache()
    var reads = 0
    var layout: [UInt16: String] = [0: "a", 1: "s", 48: "tab"]
    func read() -> [UInt16: String] { reads += 1; return layout }
    for _ in 0..<100 { #expect(cache.value(hotkey: nil, read: read)[0] == "a") }
    #expect(reads == 1)
    layout[0] = "q"
    cache.invalidate()
    #expect(cache.value(hotkey: nil, read: read)[0] == "q")
    #expect(cache.value(hotkey: nil, read: read)[48] == "tab")
    #expect(reads == 2)
}

@Test func cycleHotkeyChangesReuseTheUnmodifiedKeyNameTable() {
    var cache = KeyNameCache()
    var reads = 0
    func read() -> [UInt16: String] { reads += 1; return [0: "a", 1: "s"] }
    #expect(cache.value(hotkey: 10, read: read)[10] == CycleKey.name)
    let changed = cache.value(hotkey: 50, read: read)
    #expect(changed[10] == nil && changed[50] == CycleKey.name)
    #expect(cache.value(hotkey: 0, read: read)[0] == "a")
    #expect(cache.value(hotkey: nil, read: read)[50] == CycleKey.name)
    #expect(reads == 1)
}
