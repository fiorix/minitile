import AppKit
import MinitileIPC

/// Requests made before the queued refresh runs share its read of the latest state.
@MainActor
final class MenuRefresh {
    typealias Work = @MainActor @Sendable () -> Void
    private let schedule: (@escaping Work) -> Void
    private var pending = false

    init(schedule: @escaping (@escaping Work) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.schedule = schedule
    }

    func request(_ refresh: @escaping Work) {
        guard !pending else { return }
        pending = true
        schedule { [weak self] in
            guard let self else { return }
            self.pending = false
            refresh()
        }
    }
}

@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var command: (([String]) -> Reply)?
    private var previous: (label: String?, warnings: StatusWarnings, state: String)?

    func update(label: String?, warnings: StatusWarnings, state: String) {
        if let previous, previous.label == label, previous.warnings == warnings, previous.state == state { return }
        previous = (label, warnings, state)
        item.button?.title = label ?? "minitile"
        item.button?.toolTip = warnings.isEmpty ? state : warnings.titles.joined(separator: "\n")
        let menu = Self.menu(warnings: warnings, state: state)
        for row in menu.items where row.action != nil { row.target = self }
        item.menu = menu
    }

    static func menu(warnings: StatusWarnings, state: String) -> NSMenu {
        let menu = NSMenu()
        let summary = menu.addItem(withTitle: state, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        // The menu wraps a long subtitle, so the explanation fits under its title.
        for advice in warnings.advice {
            let row = menu.addItem(withTitle: advice.title, action: nil, keyEquivalent: "")
            row.subtitle = advice.detail
            row.isEnabled = false
        }
        for fix in warnings.fixes {
            let row = menu.addItem(withTitle: fix.title, action: #selector(openFix(_:)), keyEquivalent: "")
            row.representedObject = fix.url
        }
        for warning in warnings.others {
            let row = menu.addItem(withTitle: warning, action: nil, keyEquivalent: "")
            row.isEnabled = false
        }
        menu.addItem(.separator())
        for (title, argv) in [
            ("Help", ["help", "show"]),
            ("Quit Minitile", ["quit"]),
        ] {
            let row = menu.addItem(withTitle: title, action: #selector(run(_:)), keyEquivalent: title == "Help" ? "h" : "")
            if title == "Help" { row.keyEquivalentModifierMask = .command }
            row.representedObject = argv
        }
        return menu
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let argv = sender.representedObject as? [String], let reply = command?(argv) else { return }
        if !reply.ok { logger.error("\(reply.text, privacy: .public)") }
    }

    @objc private func openFix(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if !NSWorkspace.shared.open(url) { logger.error("Could not open \(url.absoluteString, privacy: .public)") }
    }
}
