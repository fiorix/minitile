import AppKit
import MinitileIPC

@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var command: (([String]) -> Reply)?
    private var previous: (label: String, warnings: StatusWarnings, state: String)?

    func update(label: String, warnings: StatusWarnings, state: String) {
        if let previous, previous.label == label, previous.warnings == warnings, previous.state == state { return }
        previous = (label, warnings, state)
        item.button?.title = warnings.isEmpty ? label : "\(label) !"
        item.button?.toolTip = warnings.isEmpty ? state : warnings.titles.joined(separator: "\n")
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
            row.target = self
            row.representedObject = fix.url
        }
        for warning in warnings.others {
            let row = menu.addItem(withTitle: warning, action: nil, keyEquivalent: "")
            row.isEnabled = false
        }
        menu.addItem(.separator())
        for (title, argv) in [
            ("Toggle Floating", ["window", "float"]),
            ("Layout Variant", ["page", "variant"]),
            ("Reload Config", ["config", "reload"]),
            ("Open Config", ["config", "open"]),
            ("Quit Minitile", ["quit"]),
        ] {
            let row = menu.addItem(withTitle: title, action: #selector(run(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = argv
        }
        item.menu = menu
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
