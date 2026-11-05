import CoreGraphics
import MinitileCore

/// Named keycaps, in the same modifier order as the website.
enum HelpKeys {
    static func caps(_ chord: Chord) -> [String] { caps(chord.modifiers, key: key(chord.key)) }

    static func caps(_ modifiers: Modifiers, key: String) -> [String] {
        let names: [(Modifiers, String)] = [(.ctrl, "Control"), (.alt, "Option"), (.shift, "Shift"), (.cmd, "Cmd")]
        return names.filter { modifiers.contains($0.0) }.map(\.1) + [key]
    }

    static func key(_ name: String) -> String {
        switch name {
        case "left": "Left"
        case "right": "Right"
        case "up": "Up"
        case "down": "Down"
        case "return": "Return"
        case "space": "Space"
        case "tab": "Tab"
        case "escape": "Esc"
        case "`": "Backtick"
        default: name.uppercased()
        }
    }

    static func combined(_ keys: [String]) -> String {
        switch Set(keys) {
        case ["left", "right", "up", "down"]: "Arrow keys"
        case ["left", "right"]: "Left / Right"
        case ["up", "down"]: "Up / Down"
        default: keys.map(key).joined(separator: " / ")
        }
    }
}

/// The website's shortcut table, using the merged config's actual bindings, followed by other commands and gestures.
struct HelpContent: Equatable {
    struct Entry: Equatable {
        var keys: [String]
        var text: String
        var detail: String? = nil
        /// False for a gesture, whose keys are a phrase rather than keycaps.
        var chord = true
    }

    struct Section: Equatable {
        var title: String
        var entries: [Entry]
    }

    private struct Action {
        var text: String
        /// One list of exact command aliases per direction, in reading order.
        var commands: [[String]]
        var directions: [String] = []
        var detail: String? = nil
        var reverse: String? = nil
    }

    static let gesturesTitle = "Mouse and trackpad"
    private static let actions: [Action] = [
        // Pages run sideways and workspaces up and down, but to the user the arrows simply move around the grid.
        Action(text: "Move around", commands: [["page prev"], ["page next"], ["workspace prev"], ["workspace next"]],
               directions: ["left", "right", "up", "down"]),
        Action(text: "Move a window", commands: [["window nudge left", "window move left"], ["window nudge right", "window move right"],
                                                 ["window move workspace prev", "window move up"],
                                                 ["window move workspace next", "window move down"]],
               directions: ["left", "right", "up", "down"]),
        Action(text: "Resize a window", commands: [["window resize left"], ["window resize right"], ["window resize up"], ["window resize down"]],
               directions: ["left", "right", "up", "down"]),
        Action(text: "Cycle layouts", commands: [["page variant"]]),
        Action(text: "Find a window anywhere", commands: [["switcher next"]],
               detail: "Hold Cmd, choose with Tab or arrows, then release to jump.", reverse: "switcher prev"),
        Action(text: "Cycle windows on this page", commands: [["window focus next"]], reverse: "window focus prev"),
        Action(text: "Swap a window with its neighbour", commands: [["window swap next"]], reverse: "window swap prev"),
        Action(text: "Show every shortcut", commands: [["help show"]], detail: "Press Esc or click anywhere else to close."),
    ]
    private static let other: [(command: String, text: String)] = [
        ("window focus prev", "Focus previous window"),
        ("window focus left", "Focus window to the left"), ("window focus right", "Focus window to the right"),
        ("window focus up", "Focus window above"), ("window focus down", "Focus window below"),
        ("window swap prev", "Swap with previous slot"), ("window float", "Toggle floating"),
        ("switcher prev", "Window switcher, backwards"),
    ]

    var sections: [Section]

    init(config: Config) {
        let bindings = config.bindings.filter { !$0.value.isEmpty && $0.value != ["ignore"] }
            .sorted { $0.key.description < $1.key.description }
        var used = Set<Chord>(), entries: [Entry] = []
        for action in Self.actions {
            let matches = bindings.compactMap { chord, argv -> (chord: Chord, direction: Int)? in
                guard let direction = action.commands.firstIndex(where: { $0.contains(argv.joined(separator: " ")) }) else { return nil }
                return (chord, direction)
            }.sorted { ($0.direction, $0.chord.description) < ($1.direction, $1.chord.description) }
            for match in matches where !used.contains(match.chord) {
                let peers = matches.filter { !used.contains($0.chord) && $0.chord.modifiers == match.chord.modifiers }
                var group = action.commands.indices.compactMap { direction in peers.first { $0.direction == direction } }
                if group.count != action.commands.count {
                    // A partial resize can still show an opposite pair together.
                    let pair = match.direction < 2 ? [0, 1] : [2, 3]
                    group = action.commands.count == 4 ? pair.compactMap { direction in peers.first { $0.direction == direction } } : []
                    if group.count != 2 { group = [match] }
                }
                used.formUnion(group.map(\.chord))
                let suffix = group.count == action.commands.count ? "" : " (\(group.map { action.directions[$0.direction] }.joined(separator: " / ")))"
                var detail = action.detail
                if let reverse = action.reverse, !match.chord.modifiers.contains(.shift) {
                    let backwards = Chord(modifiers: match.chord.modifiers.union(.shift), key: match.chord.key)
                    if config.bindings[backwards]?.joined(separator: " ") == reverse {
                        used.insert(backwards)
                        detail = [detail, "Add Shift to go back."].compactMap { $0 }.joined(separator: " ")
                    }
                }
                entries.append(Entry(keys: HelpKeys.caps(match.chord.modifiers, key: HelpKeys.combined(group.map { $0.chord.key })),
                                     text: action.text + suffix, detail: detail))
            }
        }
        sections = entries.isEmpty ? [] : [Section(title: "", entries: entries)]
        let others = bindings.filter { !used.contains($0.key) }.sorted { a, b in
            func order(_ binding: (key: Chord, value: [String])) -> (Int, String, String) {
                let command = binding.value.joined(separator: " ")
                return (Self.other.firstIndex { $0.command == command } ?? Self.other.count, command, binding.key.description)
            }
            return order(a) < order(b)
        }.map { chord, argv in
            let command = argv.joined(separator: " ")
            return Entry(keys: HelpKeys.caps(chord), text: Self.other.first { $0.command == command }?.text ?? command)
        }
        if !others.isEmpty { sections.append(Section(title: "Other", entries: others)) }
        sections.append(Section(title: Self.gesturesTitle, entries: Self.gestures(swipes: config.trackpadSwipes)))
    }

    static func gestures(swipes: Bool) -> [Entry] {
        let swipe = [Entry(keys: ["Swipe in any direction"], text: "Move around", chord: false)]
        return (swipes ? swipe : []) + [
            Entry(keys: ["Drag an edge or corner"], text: "Resize tiles", chord: false),
            Entry(keys: ["Drag onto a tile"], text: "Swap the two windows", chord: false),
            Entry(keys: ["Drop on the picker"], text: "Set the layout and tile", chord: false),
            Entry(keys: ["Drag, then Control + arrows"], text: "Move the window", chord: false),
        ]
    }
}

/// Sections in flipped view coordinates, in one column or as few balanced columns as fit the usable area.
struct HelpLayout: Equatable {
    static let margin: CGFloat = 16
    static let titleHeight: CGFloat = 30
    static let headerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 34
    static let keyWidth: CGFloat = 280
    static let textWidth: CGFloat = 280
    static let columnWidth = keyWidth + textWidth
    static let columnGap: CGFloat = 24

    enum Line: Equatable {
        case header(String)
        case entry(HelpContent.Entry)

        var height: CGFloat {
            switch self {
            case .header: HelpLayout.headerHeight
            case .entry(let entry): entry.detail == nil ? HelpLayout.rowHeight : HelpLayout.rowHeight + 30
            }
        }
    }

    var columns: [[Line]]

    /// Content that cannot fit even in columns overflows the panel and is clipped to its usable area.
    init(content: HelpContent, bounds: CGSize) {
        let height = bounds.height - 2 * Self.margin - Self.titleHeight
        let width = bounds.width - 2 * Self.margin + Self.columnGap
        let fitting = max(1, Int((width / (Self.columnWidth + Self.columnGap)).rounded(.down)))
        let tallest = Self.pack(content.sections, limit: .infinity).first.map(Self.height) ?? 0
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

    func origin(column: Int) -> CGPoint { CGPoint(x: Self.margin + CGFloat(column) * (Self.columnWidth + Self.columnGap),
                                                 y: Self.margin + Self.titleHeight) }

    static func height(_ column: [Line]) -> CGFloat { column.reduce(0) { $0 + $1.height } }

    /// A section moves whole when it fits an empty column. Taller ones split, keeping a heading with its first row.
    static func pack(_ sections: [HelpContent.Section], limit: CGFloat) -> [[Line]] {
        var columns: [[Line]] = [[]], used: CGFloat = 0
        func add(_ line: Line, room: CGFloat) {
            if used + room > limit, !columns[columns.count - 1].isEmpty { columns.append([]); used = 0 }
            columns[columns.count - 1].append(line)
            used += line.height
        }
        for section in sections where !section.entries.isEmpty {
            let rows = section.entries.map { Line.entry($0) }
            let heading = section.title.isEmpty ? 0 : headerHeight
            let block = heading + height(rows)
            let room = block <= limit ? block : heading + rows[0].height
            if !section.title.isEmpty { add(.header(section.title), room: room) }
            else if used + room > limit, !columns[columns.count - 1].isEmpty { columns.append([]); used = 0 }
            for row in rows { add(row, room: row.height) }
        }
        return columns.filter { !$0.isEmpty }
    }
}
