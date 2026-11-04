import Foundation
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
