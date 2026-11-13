import Testing
@testable import minitile

@Test func keyNamesReadOnceUntilTheLayoutIdentityChanges() {
    var cache = KeyNameCache()
    var identity = KeyNameCache.Identity(sourceID: "first", keyboardType: 40)
    var reads = 0
    var layout: [UInt16: String] = [0: "a", 1: "s", 48: "tab"]
    func read() -> [UInt16: String]? { reads += 1; return layout }
    for _ in 0..<100 { #expect(cache.value(identity: identity, hotkey: nil, read: read)[0] == "a") }
    #expect(reads == 1)
    layout[0] = "q"
    identity.sourceID = "second"
    #expect(cache.value(identity: identity, hotkey: nil, read: read)[0] == "q")
    #expect(cache.value(identity: identity, hotkey: nil, read: read)[48] == "tab")
    #expect(reads == 2)
    layout[0] = "z"
    identity.keyboardType = 41
    #expect(cache.value(identity: identity, hotkey: nil, read: read)[0] == "z")
    #expect(cache.value(identity: identity, hotkey: nil, read: read)[0] == "z")
    #expect(reads == 3)
}

@Test func keyNamesWithoutLayoutDataAreRetriedOnTheNextUpdate() {
    var cache = KeyNameCache()
    let identity = KeyNameCache.Identity(sourceID: "layout", keyboardType: 40)
    var reads = 0
    var layout: [UInt16: String]?
    func read() -> [UInt16: String]? { reads += 1; return layout }
    for _ in 0..<2 {
        let names = cache.value(identity: identity, hotkey: nil, read: read)
        #expect(names[0] == nil)
        #expect(names[53] == "escape" && names[48] == "tab" && names[122] == "f1")
    }
    #expect(reads == 2)
    layout = [0: "a"]
    #expect(cache.value(identity: identity, hotkey: nil, read: read)[0] == "a")
    #expect(cache.value(identity: identity, hotkey: nil, read: read)[0] == "a")
    #expect(reads == 3)
}

@Test func keyNamesDiscardTheOldLayoutWhenTheSourceIsUnavailable() {
    var cache = KeyNameCache()
    let identity = KeyNameCache.Identity(sourceID: "layout", keyboardType: 40)
    #expect(cache.value(identity: identity, hotkey: nil) { [0: "a"] }[0] == "a")
    #expect(cache.value(identity: nil, hotkey: nil) { nil }[0] == nil)
    #expect(cache.value(identity: identity, hotkey: nil) { [0: "q"] }[0] == "q")
}

@Test func cycleHotkeyChangesReuseTheUnmodifiedKeyNameTable() {
    var cache = KeyNameCache()
    let identity = KeyNameCache.Identity(sourceID: "layout", keyboardType: 40)
    var reads = 0
    func read() -> [UInt16: String]? { reads += 1; return [0: "a", 1: "s"] }
    #expect(cache.value(identity: identity, hotkey: 10, read: read)[10] == CycleKey.name)
    let changed = cache.value(identity: identity, hotkey: 50, read: read)
    #expect(changed[10] == nil && changed[50] == CycleKey.name)
    #expect(cache.value(identity: identity, hotkey: 0, read: read)[0] == "a")
    #expect(cache.value(identity: identity, hotkey: nil, read: read)[50] == CycleKey.name)
    #expect(reads == 1)
}
