import MinitileCore
import Testing

@Test func displaySmokeFixtureRestoresBothGrids() throws {
    let home = DisplayInfo(id: "home", frame: Rect(x: 0, y: 0, width: 1200, height: 900),
                           isPrimary: true, visibleSpace: 1, stashSpace: 2)
    let external = DisplayInfo(id: "external", frame: Rect(x: 1200, y: 0, width: 1200, height: 900),
                               visibleSpace: 3, stashSpace: 4)
    var engine = Engine()
    let windows = (1...5).map { WindowInfo(id: WindowID($0), pid: 100, display: home.id) }
    _ = engine.handle(.started(saved: nil, windows: windows, displays: [home], focus: 5))
    _ = engine.handle(.displaysChanged([home, external]))
    func command(_ text: String) throws {
        let output = engine.handle(.command(text.split(separator: " ").map(String.init)))
        try #require(output.reply?.ok == true)
    }
    func scene() -> Scene { engine.handle(.command(["state"])).scene }
    for id in 3...5 { try command("window move \(id) display external") }
    try command("window nudge 5 right")
    try command("window focus 1")
    try command("window focus 5")
    #expect(scene().displays[home.id]?.visible == [1, 2])
    #expect(scene().displays[external.id]?.visible == [5])

    for (anchor, other) in [(3, home.id), (1, external.id)] {
        try command("window focus \(anchor)")
        let unchanged = scene().displays[other]
        try command("page next")
        #expect(scene().displays[other] == unchanged)
        try command("page prev")
        #expect(scene().displays[other] == unchanged)
    }
    try command("window focus 1")
    try command("workspace next")
    try command("window focus 5")
    try command("workspace next")
    #expect(scene().displays.values.allSatisfy { $0.visible.isEmpty })
    _ = engine.handle(.appActivated(pid: 100))
    #expect(scene().displays[external.id]?.visible == [5])

    try command("window focus 1")
    try command("window focus 5")
    let before = engine.savedState().displays
    _ = engine.handle(.focusChanged(nil))
    _ = engine.handle(.displaysChanged([home]))
    #expect(engine.savedState().windows.count == 5)
    #expect(engine.savedState().windows.values.allSatisfy { $0.display == home.id })
    #expect(engine.savedState().displays[0].workspaces.last?.home == external.id)
    try command("window focus 3")
    try command("window focus 5")
    _ = engine.handle(.focusChanged(nil))
    _ = engine.handle(.displaysChanged([home, external]))
    #expect(engine.savedState().displays == before)
    #expect(engine.savedState().windows[1]?.display == home.id)
    #expect(engine.savedState().windows[5]?.display == external.id)
}
