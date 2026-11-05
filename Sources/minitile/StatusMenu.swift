import AppKit
import MinitileIPC

/// The brand mark in menu-bar points. Only alpha matters in a template image.
enum StatusMark {
    static func image(label: String?) -> NSImage {
        let font = PanelStyle.font(size: 9, weight: .bold, monospaced: true)
        let text = NSAttributedString(string: label ?? "", attributes: [.font: font, .foregroundColor: NSColor.black])
        let width = max(16, ceil(text.size().width) + (label == nil ? 0 : 2))
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: (rect.width - 16) / 2, yBy: 0)
            transform.scale(by: 0.4)
            transform.concat()
            NSColor.black.set()
            for (rect, radius) in [(NSRect(x: 3, y: 3, width: 34, height: 34), CGFloat(7)),
                                   (NSRect(x: 9, y: 9, width: 9, height: 9), 1.5),
                                   (NSRect(x: 22, y: 9, width: 9, height: 9), 1.5)] {
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                path.lineWidth = 1.5
                path.stroke()
            }
            NSBezierPath(roundedRect: NSRect(x: 9, y: 22, width: 22, height: 9), xRadius: 1.5, yRadius: 1.5).fill()
            NSGraphicsContext.restoreGraphicsState()
            if label != nil {
                let origin = NSPoint(x: (rect.width - text.size().width) / 2, y: (rect.height - text.size().height) / 2)
                // A two-point glyph stroke clears one point beyond its edge, through the mark's alpha.
                let knockout = NSMutableAttributedString(attributedString: text)
                knockout.addAttributes([.strokeWidth: -200 / font.pointSize, .strokeColor: NSColor.black],
                                       range: NSRange(location: 0, length: knockout.length))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                knockout.draw(at: origin)
                NSGraphicsContext.restoreGraphicsState()
                text.draw(at: origin)
            }
            return true
        }
        image.isTemplate = true
        return image
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
        item.button?.title = ""
        item.button?.image = StatusMark.image(label: label)
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
