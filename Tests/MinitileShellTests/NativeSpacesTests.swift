import Foundation
import MinitileCore
import Testing
@testable import minitile

private func nativeRow(_ identifier: String, _ spaces: [(UInt64, Int)], current: UInt64 = 1) -> [String: Any] {
    ["Display Identifier": identifier,
     "Spaces": spaces.map { ["id64": NSNumber(value: $0.0), "type": NSNumber(value: $0.1)] },
     "Current Space": ["id64": NSNumber(value: current), "type": 0]]
}

@Test func addingADesktopChangesTopologyWithoutSwitchingDesktops() {
    let before = NativeDisplaySpaces.parse([nativeRow("external", [(1, 0)])])
    let after = NativeDisplaySpaces.parse([nativeRow("external", [(1, 0), (2, 0)])])
    #expect(before == [NativeDisplaySpaces(identifier: "external", spaces: [NativeSpace(id: 1, type: 0)])])
    #expect(after == [NativeDisplaySpaces(identifier: "external", spaces: [NativeSpace(id: 1, type: 0), NativeSpace(id: 2, type: 0)])])
    #expect(after != before)
}

@Test func topologyTracksDesktopIdentityOrderTypeAndDisplayMembership() {
    let laptop = nativeRow("laptop", [(10, 0), (20, 0)])
    let external = nativeRow("external", [(30, 0), (40, 0)])
    let before = NativeDisplaySpaces.parse([laptop, external])
    for rows in [
        [laptop],
        [external, laptop],
        [laptop, nativeRow("external", [(30, 0)])],
        [laptop, nativeRow("external", [(40, 0), (30, 0)])],
        [laptop, nativeRow("external", [(30, 0), (41, 0)])],
        [laptop, nativeRow("external", [(30, 0), (40, 4)])],
        [laptop, external, nativeRow("third", [(50, 0), (60, 0)])],
    ] {
        #expect(NativeDisplaySpaces.parse(rows) != before)
    }
}

@Test func desktopActivationAndMetadataDoNotChangeTopology() {
    let spaces: [(UInt64, Int)] = [(1, 0), (2, 0), (3, 4)]
    let before = NativeDisplaySpaces.parse([nativeRow("Main", spaces)])
    var switched = nativeRow("Main", spaces, current: 2)
    switched["unrelated"] = "metadata"
    #expect(NativeDisplaySpaces.parse([switched]) == before)
    #expect(before[0].spaces.map(\.id) == [1, 2, 3])
}

@Test func wakingNeedsSettlingOnlyWhenTheDisplaysChanged() {
    let info = DisplayInfo(id: "a", frame: .init(x: 0, y: 0, width: 1512, height: 982))
    let spaces = [NativeSpace(id: 1, type: 0), NativeSpace(id: 2, type: 0)]
    let before = [NativeDisplay(info: info, identifier: "a", spaces: spaces, current: 1)]
    var showingStash = before
    showingStash[0].current = 2
    #expect(!DisplayCatalog.changed(showingStash, from: before))
    var resized = before
    resized[0].info.visibleFrame = .init(x: 0, y: 24, width: 1512, height: 900)
    #expect(DisplayCatalog.changed(resized, from: before))
    var extraDesktop = before
    extraDesktop[0].spaces.append(NativeSpace(id: 3, type: 0))
    #expect(DisplayCatalog.changed(extraDesktop, from: before))
    let plugged = before + [NativeDisplay(info: DisplayInfo(id: "b", frame: .init(x: 1512, y: 0, width: 1920, height: 1080)),
                                          identifier: "b", spaces: spaces, current: 1)]
    #expect(DisplayCatalog.changed(plugged, from: before))
}

@Test func fullscreenSpacesAreNotDesktops() {
    let desktops = NativeDisplaySpaces.parse([nativeRow("laptop", [(1, 0), (2, 0)]), nativeRow("external", [(3, 0), (4, 0)])])
    let fullscreen = NativeDisplaySpaces.parse([nativeRow("laptop", [(1, 0), (7, 4), (2, 0)]), nativeRow("external", [(3, 0), (4, 0), (8, 4)])])
    #expect(fullscreen != desktops)
    #expect(NativeDisplaySpaces.desktops(fullscreen) == desktops)
    #expect(NativeDisplaySpaces.desktops(desktops) == desktops)
    let added = NativeDisplaySpaces.parse([nativeRow("laptop", [(1, 0), (7, 4), (2, 0), (9, 0)]), nativeRow("external", [(3, 0), (4, 0)])])
    #expect(NativeDisplaySpaces.desktops(added) != desktops)
}

@Test func windowStandsOnAFullscreenSpaceByItsType() {
    let displays = NativeDisplaySpaces.parse([nativeRow("laptop", [(1, 0), (7, 4), (2, 0)])])
    #expect(NativeDisplaySpaces.fullscreen([7], in: displays))
    #expect(!NativeDisplaySpaces.fullscreen([1], in: displays))
    #expect(!NativeDisplaySpaces.fullscreen([], in: displays))
    #expect(!NativeDisplaySpaces.fullscreen([99], in: displays))
    #expect(NativeDisplaySpaces.knows([1, 7], in: displays))
    #expect(NativeDisplaySpaces.knows([], in: displays))
    #expect(!NativeDisplaySpaces.knows([1, 99], in: displays))
}
