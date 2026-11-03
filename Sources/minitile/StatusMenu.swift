import AppKit
import MinitileIPC

@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var command: (([String]) -> Reply)?
    private var previous: (label: String, warnings: [String], state: String)?

    func update(label: String, warnings: [String], state: String) {
        if let previous, previous.label == label, previous.warnings == warnings, previous.state == state { return }
        previous = (label, warnings, state)
        item.button?.title = warnings.isEmpty ? label : "\(label) !"
        item.button?.toolTip = warnings.isEmpty ? state : warnings.joined(separator: "\n")
        let menu = NSMenu()
        let summary = menu.addItem(withTitle: state, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        for warning in warnings {
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
}
