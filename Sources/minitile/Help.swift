import CoreGraphics
import MinitileCore

/// Chords as macOS menus show them: control, option, shift and command symbols in that order, then the key.
enum HelpKeys {
    static func text(_ chord: Chord) -> String {
        let symbols: [(Modifiers, String)] = [(.ctrl, "\u{2303}"), (.alt, "\u{2325}"), (.shift, "\u{21E7}"), (.cmd, "\u{2318}")]
        return symbols.filter { chord.modifiers.contains($0.0) }.map(\.1).joined() + key(chord.key)
    }

    static func key(_ name: String) -> String {
        switch name {
        case "left": "\u{2190}"
        case "right": "\u{2192}"
        case "up": "\u{2191}"
        case "down": "\u{2193}"
        case "return": "Return"
        case "space": "Space"
        case "tab": "Tab"
        case "escape": "Esc"
        default: name.uppercased()
        }
    }
}

/// The help screen's text: the merged config's bindings grouped by what they do, then the gestures that are on.
struct HelpContent: Equatable {
    enum Group: Int, CaseIterable {
        case navigation, windows, layout, switcher, help, other

        var title: String {
            switch self {
            case .navigation: "Pages and workspaces"
            case .windows: "Windows"
            case .layout: "Layout"
            case .switcher: "Switcher"
            case .help: "Help"
            case .other: "Other"
            }
        }
    }

    struct Entry: Equatable {
        var keys: String
        var text: String
    }

    struct Section: Equatable {
        var title: String
        var entries: [Entry]
    }

    static let gesturesTitle = "Mouse and trackpad"

    /// Known commands in the order the screen lists them within their group.
    static let known: [(command: [String], group: Group, text: String)] = [
        (["page", "prev"], .navigation, "Previous page"),
        (["page", "next"], .navigation, "Next page"),
        (["workspace", "prev"], .navigation, "Workspace above"),
        (["workspace", "next"], .navigation, "Workspace below"),
        (["window", "focus", "next"], .windows, "Focus next window"),
        (["window", "focus", "prev"], .windows, "Focus previous window"),
        (["window", "focus", "left"], .windows, "Focus window to the left"),
        (["window", "focus", "right"], .windows, "Focus window to the right"),
        (["window", "focus", "up"], .windows, "Focus window above"),
        (["window", "focus", "down"], .windows, "Focus window below"),
        (["window", "nudge", "left"], .windows, "Nudge window left"),
        (["window", "nudge", "right"], .windows, "Nudge window right"),
        (["window", "move", "left"], .windows, "Nudge window left"),
        (["window", "move", "right"], .windows, "Nudge window right"),
        (["window", "move", "workspace", "prev"], .windows, "Carry to workspace above"),
        (["window", "move", "workspace", "next"], .windows, "Carry to workspace below"),
        (["window", "move", "up"], .windows, "Carry to workspace above"),
        (["window", "move", "down"], .windows, "Carry to workspace below"),
        (["window", "swap", "next"], .windows, "Swap with next slot"),
        (["window", "swap", "prev"], .windows, "Swap with previous slot"),
        (["window", "float"], .windows, "Toggle floating"),
        (["page", "variant"], .layout, "Cycle page layout"),
        (["window", "resize", "left"], .layout, "Resize window left"),
        (["window", "resize", "right"], .layout, "Resize window right"),
        (["window", "resize", "up"], .layout, "Resize window up"),
        (["window", "resize", "down"], .layout, "Resize window down"),
        (["switcher", "next"], .switcher, "Window switcher"),
        (["switcher", "prev"], .switcher, "Window switcher, backwards"),
        (["help", "show"], .help, "Show this help"),
        (["ignore"], .other, "Blocked"),
    ]

    var sections: [Section]

    init(config: Config) {
        typealias Row = (group: Group, rank: Int, command: String, chord: String, entry: Entry)
        let rows: [Row] = config.bindings.compactMap { chord, argv in
            guard !argv.isEmpty else { return nil }
            let command = argv.joined(separator: " ")
            let keys = HelpKeys.text(chord)
            if let rank = Self.known.firstIndex(where: { $0.command == argv }) {
                let known = Self.known[rank]
                return (known.group, rank, command, chord.description, Entry(keys: keys, text: known.text))
            }
            return (.other, Self.known.count, command, chord.description, Entry(keys: keys, text: command))
        }
        // Unknown commands follow the known ones by command text; a command's chords follow each other by name.
        let sorted = rows.sorted { a, b in
            (a.group.rawValue, a.rank, a.command, a.chord) < (b.group.rawValue, b.rank, b.command, b.chord)
        }
        sections = Group.allCases.compactMap { group in
            let entries = sorted.filter { $0.group == group }.map(\.entry)
            return entries.isEmpty ? nil : Section(title: group.title, entries: entries)
        }
        sections.append(Section(title: Self.gesturesTitle, entries: Self.gestures(swipes: config.trackpadSwipes)))
    }

    /// The mouse and trackpad gestures, without swipes when `trackpad_swipes` leaves them to macOS.
    static func gestures(swipes: Bool) -> [Entry] {
        let swipe = [Entry(keys: "Swipe left or right", text: "Next or previous page"),
                     Entry(keys: "Swipe up or down", text: "Workspace below or above")]
        return (swipes ? swipe : []) + [
            Entry(keys: "Drag an edge or corner", text: "Resize tiles"),
            Entry(keys: "Drag onto a tile", text: "Swap the two windows"),
            Entry(keys: "Drop on the picker", text: "Set the layout and tile"),
            Entry(keys: "Drag, then \u{2303} arrows", text: "Nudge or carry the window"),
        ]
    }
}

/// The panel's layout in flipped view coordinates: sections in one column, or in as few balanced columns as fit the
/// usable area.
struct HelpLayout: Equatable {
    static let margin: CGFloat = 16
    static let titleHeight: CGFloat = 26
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 18
    static let keyWidth: CGFloat = 140
    static let textWidth: CGFloat = 180
    static let columnWidth = keyWidth + textWidth
    static let columnGap: CGFloat = 24

    enum Line: Equatable {
        case header(String)
        case entry(HelpContent.Entry)

        var height: CGFloat {
            switch self {
            case .header: HelpLayout.headerHeight
            case .entry: HelpLayout.rowHeight
            }
        }
    }

    var columns: [[Line]]

    /// `bounds` is the room the panel may take, the usable area less a margin. Content that does not fit even in
    /// columns overflows it.
    init(content: HelpContent, bounds: CGSize) {
        let height = bounds.height - 2 * Self.margin - Self.titleHeight
        let width = bounds.width - 2 * Self.margin + Self.columnGap
        let fitting = max(1, Int((width / (Self.columnWidth + Self.columnGap)).rounded(.down)))
        let tallest = Self.pack(content.sections, limit: .infinity).first.map(Self.height) ?? 0
        // The fewest columns that fit the height, then the lowest column height that needs no more of them.
        let count = min(fitting, Self.pack(content.sections, limit: height).count)
        var low: CGFloat = 0, high = tallest
        while high - low > 1 {
            let middle = ((low + high) / 2).rounded(.down)
            if Self.pack(content.sections, limit: middle).count <= count { high = middle } else { low = middle }
        }
        columns = Self.pack(content.sections, limit: high)
    }

    var size: CGSize {
        let count = CGFloat(columns.count)
        return CGSize(width: 2 * Self.margin + count * Self.columnWidth + max(0, count - 1) * Self.columnGap,
                      height: 2 * Self.margin + Self.titleHeight + (columns.map(Self.height).max() ?? 0))
    }

    func origin(column: Int) -> CGPoint {
        CGPoint(x: Self.margin + CGFloat(column) * (Self.columnWidth + Self.columnGap), y: Self.margin + Self.titleHeight)
    }

    static func height(_ column: [Line]) -> CGFloat { column.reduce(0) { $0 + $1.height } }

    /// Fills columns in order up to `limit`. A section moves to a new column when it would not fit the current one
    /// but fits an empty one; a taller one splits between rows, and a header always keeps a row below it.
    static func pack(_ sections: [HelpContent.Section], limit: CGFloat) -> [[Line]] {
        var columns: [[Line]] = [[]], used: CGFloat = 0
        func add(_ line: Line, room: CGFloat) {
            if used + room > limit, !columns[columns.count - 1].isEmpty { columns.append([]); used = 0 }
            columns[columns.count - 1].append(line)
            used += line.height
        }
        for section in sections {
            let block = headerHeight + CGFloat(section.entries.count) * rowHeight
            add(.header(section.title), room: block <= limit ? block : headerHeight + (section.entries.isEmpty ? 0 : rowHeight))
            for entry in section.entries { add(.entry(entry), room: rowHeight) }
        }
        return columns.filter { !$0.isEmpty }
    }
}
