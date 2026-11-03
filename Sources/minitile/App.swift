import AppKit
@preconcurrency import ApplicationServices
import CSkyLight
import MinitileCore
import MinitileIPC
import OSLog

let logger = Logger(subsystem: "minitile", category: "shell")

@main
enum MinitileMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths = ShellPaths()
    let status = StatusMenu()
    var permissionTimer: Timer?
    var engine = Engine()
    var started = false
    var warnings: [String: String] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.command = { [weak self] in self?.command($0) ?? Reply(ok: false, text: "Starting") }
        if !AXIsProcessTrusted() {
            warnings["accessibility"] = "Grant Accessibility to Minitile.app in System Settings > Privacy & Security"
            updateMenu()
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    self?.permissionTimer?.invalidate()
                    self?.permissionTimer = nil
                    self?.warnings.removeValue(forKey: "accessibility")
                    self?.start()
                }
            }
        } else { start() }
    }

    func start() {
        var error = [CChar](repeating: 0, count: 1024)
        guard csl_init(&error, error.count) else {
            fail(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }); return
        }
        guard NSScreen.screensHaveSeparateSpaces else {
            fail("Displays have separate Spaces must be enabled"); return
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        do { engine = Engine(config: try Config.parse(paths.configContents())) }
        catch { fail("Config: \(error)"); return }
        started = true
        updateMenu()
    }

    func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        warnings["startup"] = message
        updateMenu()
    }

    func updateMenu() {
        status.update(label: started ? "1:1" : "minitile", warnings: warnings.values.sorted(), state: "Starting")
    }

    @discardableResult func command(_ argv: [String]) -> Reply {
        if argv == ["quit"] { NSApp.terminate(nil); return Reply() }
        if argv == ["config", "open"] {
            do { try paths.openConfig(); return Reply() }
            catch { return Reply(ok: false, text: String(describing: error)) }
        }
        return Reply(ok: false, text: "minitile is starting")
    }
}
