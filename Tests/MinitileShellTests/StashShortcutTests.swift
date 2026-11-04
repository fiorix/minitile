import Testing
@testable import minitile

@Test func directionalStashBlockersFollowNativeAdjacency() {
    let spaces = [NativeSpace(id: 1, type: 0), NativeSpace(id: 2, type: 0), NativeSpace(id: 3, type: 0)]
    #expect(StashShortcuts.ids(spaces: spaces, current: 1, stash: 3, desktopNumber: 3) == [120])
    #expect(StashShortcuts.ids(spaces: spaces, current: 2, stash: 3, desktopNumber: 3) == [120, 81])
    #expect(StashShortcuts.ids(spaces: spaces, current: 3, stash: 3, desktopNumber: 3) == [120])
    let fullscreen = spaces + [NativeSpace(id: 4, type: 4)]
    #expect(StashShortcuts.ids(spaces: fullscreen, current: 4, stash: 3, desktopNumber: 3) == [120, 79])
    #expect(StashShortcuts.ids(spaces: spaces, current: 99, stash: 3, desktopNumber: nil).isEmpty)
}

@Test func fullscreenBetweenDesktopsIsNotMistakenForTheStash() {
    let spaces = [NativeSpace(id: 1, type: 0), NativeSpace(id: 2, type: 4), NativeSpace(id: 3, type: 0)]
    #expect(StashShortcuts.ids(spaces: spaces, current: 1, stash: 3, desktopNumber: 2) == [119])
    #expect(StashShortcuts.ids(spaces: spaces, current: 2, stash: 3, desktopNumber: 2) == [119, 81])
}
