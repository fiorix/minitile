import Foundation
import MinitileCore

/// A display setup minitile needs and cannot make itself, so the display is left unmanaged until the user makes it.
enum DisplayNeed: CaseIterable {
    /// minitile keeps hidden pages on a display's second desktop, and macOS does not let apps add desktops.
    case secondDesktop
    /// Without separate Spaces every display shares one set of desktops, so no display has a desktop pair of its own.
    case separateSpaces

    /// The display's `unmanagedReason`, which `mntl display list` and the state show.
    var reason: String {
        switch self {
        case .secondDesktop: "Needs a second desktop: open Mission Control and click + at the top of this display"
        case .separateSpaces: "Needs Displays have separate Spaces: turn it on in Desktop & Dock settings, then log out"
        }
    }

    init?(reason: String?) {
        guard let need = Self.allCases.first(where: { $0.reason == reason }) else { return nil }
        self = need
    }
}

/// Where the user makes a setup minitile needs.
enum SetupFix: Equatable, CaseIterable {
    case missionControl
    case desktopSettings

    var title: String {
        switch self {
        case .missionControl: "Open Mission Control"
        case .desktopSettings: "Open Desktop & Dock Settings"
        }
    }

    var url: URL {
        switch self {
        case .missionControl: URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        case .desktopSettings: URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
        }
    }
}

/// A setup the user has to make, in their words: what is missing, why minitile needs it, and where to make it.
struct SetupAdvice: Equatable {
    var title: String
    var detail: String
    var fix: SetupFix

    static func secondDesktop(name: String) -> SetupAdvice {
        SetupAdvice(title: "\(name) needs a second desktop", detail: """
            minitile keeps hidden pages on a second desktop. macOS does not let apps add one: open Mission Control and \
            click + at the top of this display.
            """, fix: .missionControl)
    }

    static let separateSpaces = SetupAdvice(title: "Displays have separate Spaces is off", detail: """
        minitile gives each display its own pair of desktops. Turn on Displays have separate Spaces in Desktop & Dock \
        settings, then log out and back in.
        """, fix: .desktopSettings)

    /// One advice per display that needs a second desktop, by its name, and one for separate Spaces, a single setting
    /// for every display, which also covers a startup that stopped for it before reading any display.
    static func list(displays: [DisplayInfo], names: [DisplayID: String], separateSpaces: Bool) -> [SetupAdvice] {
        let desktops = displays.filter { DisplayNeed(reason: $0.unmanagedReason) == .secondDesktop }
            .map { secondDesktop(name: names[$0.id] ?? "A display") }
        let spaces = !separateSpaces || displays.contains { DisplayNeed(reason: $0.unmanagedReason) == .separateSpaces }
        return (spaces ? [Self.separateSpaces] : []) + desktops
    }
}

/// What the status menu warns about: setup advice with its explanation, then other warnings, less any that repeat an
/// advice's title, as the startup failure for separate Spaces does.
struct StatusWarnings: Equatable {
    var advice: [SetupAdvice]
    var others: [String]

    init(_ warnings: some Sequence<String>, advice: [SetupAdvice]) {
        self.advice = advice
        others = warnings.filter { warning in !advice.contains { $0.title == warning } }.sorted()
    }

    var isEmpty: Bool { advice.isEmpty && others.isEmpty }
    var titles: [String] { advice.map(\.title) + others }

    /// Each place to make the advised setup, once.
    var fixes: [SetupFix] { SetupFix.allCases.filter { fix in advice.contains { $0.fix == fix } } }
}
