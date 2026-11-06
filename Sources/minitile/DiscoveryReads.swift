import AppKit
@preconcurrency import ApplicationServices
import CSkyLight
import MinitileCore

/// Carries an AX element to a background read and back. AX client calls work from any thread.
struct AXRef: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

/// The window attributes discovery reads. Nil means the read failed, and the window keeps its prior value.
struct WindowAttributes: Equatable, Sendable {
    var title: String?
    var minimized: Bool?
    var frame: Rect?
    var tileable: Bool?
    /// Read only for a smoke run.
    var document: String?
    /// True for a popup, which minitile never manages; nil when unknown.
    var popup: Bool?

    /// A popup, such as a browser's address bar suggestions, has no meaningful subrole and no close button. Nil
    /// when the subrole could not be read, or the close button could not be for an `AXUnknown` window.
    static func popup(subrole: String?, closeButton: Bool?) -> Bool? {
        guard let subrole else { return nil }
        guard subrole == kAXUnknownSubrole else { return false }
        return closeButton.map { !$0 }
    }
}

extension WindowInfo {
    /// `geometry` is false while minitile's own frame write is settling, so the stale frame is not taken.
    mutating func apply(_ attributes: WindowAttributes, appHidden: Bool, geometry: Bool) {
        title = attributes.title ?? title
        minimized = attributes.minimized ?? minimized
        self.appHidden = appHidden
        if geometry { frame = attributes.frame ?? frame }
        if let tileable = attributes.tileable { self.tileable = tileable }
    }
}

struct AppCandidate: Equatable, Sendable {
    var pid: Int32
    var regular: Bool
}

enum DiscoveryPlan {
    /// Regular apps, and accessory apps only while they own a real window: helpers such as a browser's web content
    /// processes own none and can stop answering. An app whose previous read is still running is skipped.
    static func reads(_ apps: [AppCandidate], snapshot: [WindowID: CGWindowRecord], reading: Set<Int32>) -> [Int32] {
        let owners = Set(snapshot.values.filter(\.real).map(\.pid))
        return apps.filter { !reading.contains($0.pid) && ($0.regular || owners.contains($0.pid)) }.map(\.pid)
    }
}

/// Decides which background results still apply when they reach the main thread. Each stamp orders discovery events:
/// a result is stale for a window touched (updated by a notification, written by minitile, discovered or removed)
/// after its work began, and every result is dropped once lifecycle changes were suspended after it began.
struct DiscoveryLedger {
    struct Ticket: Equatable, Sendable {
        var stamp: Int
        var suspensions: Int
    }

    private(set) var stamp = 0
    private(set) var suspensions = 0
    private(set) var reading: Set<Int32> = []
    private var touched: [WindowID: Int] = [:]
    private var snapshots = 0
    private var answered: [Int32: Bool] = [:]

    var ticket: Ticket { Ticket(stamp: stamp, suspensions: suspensions) }

    @discardableResult mutating func touch(_ id: WindowID) -> Int {
        stamp += 1
        touched[id] = stamp
        return stamp
    }

    mutating func suspend() { suspensions += 1 }

    func accepts(_ ticket: Ticket, frozen: Bool) -> Bool { !frozen && ticket.suspensions == suspensions }

    func stale(_ id: WindowID, since ticket: Ticket) -> Bool { touched[id].map { $0 > ticket.stamp } ?? false }

    /// Reads that follow a snapshot share its ticket, so they must begin before the snapshot ends.
    mutating func beginSnapshot() -> Ticket {
        snapshots += 1
        return ticket
    }

    mutating func endSnapshot() {
        snapshots -= 1
        prune()
    }

    /// False when the app's previous read is still running.
    mutating func beginRead(_ pid: Int32) -> Bool { reading.insert(pid).inserted }

    /// `answered` is nil when the read asked the app nothing.
    mutating func endRead(_ pid: Int32, answered: Bool?) {
        reading.remove(pid)
        record(pid, answered: answered)
        prune()
    }

    mutating func record(_ pid: Int32, answered: Bool?) {
        if let answered { self.answered[pid] = answered }
    }

    /// Whether the app's latest read was answered, which observer registrations wait for.
    func answers(_ pid: Int32) -> Bool { answered[pid] == true }

    mutating func forget(_ pid: Int32) { answered.removeValue(forKey: pid) }

    /// Touches matter only to work still running.
    private mutating func prune() {
        if reading.isEmpty && snapshots == 0 { touched.removeAll() }
    }
}

/// Full-scan count and wall time, from the snapshot request to the last app's applied result.
struct ScanPasses {
    private var running: [Int: (start: TimeInterval, reads: Int)] = [:]
    private var serial = 0
    private(set) var count = 0
    private(set) var milliseconds = 0.0

    mutating func begin(at time: TimeInterval) -> Int {
        serial += 1
        running[serial] = (time, 0)
        return serial
    }

    /// The pass started `reads` app reads; with none it is done.
    mutating func reading(_ pass: Int, reads: Int, at time: TimeInterval) {
        running[pass]?.reads = reads
        if reads == 0 { finish(pass, at: time) }
    }

    mutating func readFinished(_ pass: Int, at time: TimeInterval) {
        guard var entry = running[pass] else { return }
        entry.reads -= 1
        running[pass] = entry
        if entry.reads <= 0 { finish(pass, at: time) }
    }

    /// A pass with no usable snapshot is not counted.
    mutating func cancel(_ pass: Int) { running.removeValue(forKey: pass) }

    /// A scan run on the main thread.
    mutating func add(milliseconds: Double) {
        count += 1
        self.milliseconds += milliseconds
    }

    private mutating func finish(_ pass: Int, at time: TimeInterval) {
        guard let entry = running.removeValue(forKey: pass) else { return }
        add(milliseconds: (time - entry.start) * 1000)
    }
}

/// Finds the windows a snapshot shows off screen on a desktop their display is showing, as an app's `orderOut:` leaves
/// them. It runs right after the snapshot on the same thread, so a page change rarely falls between the two.
struct OffScreenProbe: Sendable {
    var windows: [WindowID]
    /// Each managed display's identifier and visible desktop.
    var desktops: [(display: String, space: UInt64)]

    func run(_ snapshot: [WindowID: CGWindowRecord]) -> Set<WindowID> {
        let shown = Set(desktops.compactMap { csl_current_space($0.display as CFString) == $0.space ? $0.space : nil })
        guard !shown.isEmpty else { return [] }
        return Set(windows.filter { id in
            guard let record = snapshot[id], !record.onScreen else { return false }
            return DisplayCatalog.windowSpaces(id).contains(where: shown.contains)
        })
    }
}

struct KnownElement: Sendable {
    var id: WindowID
    var element: AXRef
}

/// What one app's read needs, captured on the main thread.
struct AppReadRequest: Sendable {
    var pid: Int32
    var app: AXRef
    /// Known windows the snapshot still shows for the app; `AXWindows` omits stashed ones.
    var known: [KnownElement]
    /// New-window elements from creation notifications, read instead of `AXWindows`.
    var candidates: [AXRef]?
    /// The app's windows in the snapshot.
    var records: [WindowID: CGWindowRecord]
    var documents: Bool
}

struct WindowRead: Sendable {
    var id: WindowID
    var element: AXRef
    /// Not yet known when the read began: listed by the app or a creation candidate.
    var listed: Bool
    var attributes: WindowAttributes
}

struct CandidateRead: Sendable {
    var element: AXRef
    var id: WindowID?
}

struct AppRead: Sendable {
    var pid: Int32
    /// Nil when nothing was asked. False when the app's first read failed with -25204, as a hung app's does once the
    /// messaging timeout expires; the rest of its reads are then skipped.
    var answered: Bool?
    var windows: [WindowRead] = []
    var candidates: [CandidateRead] = []
    var milliseconds = 0.0
}

/// Background AX reads for discovery. Each app's reads run in order on one thread.
enum DiscoveryReader {
    static func read(_ request: AppReadRequest) -> AppRead {
        let start = ProcessInfo.processInfo.systemUptime
        var result = request.candidates.map { readCandidates($0, request) } ?? readApp(request)
        result.milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return result
    }

    private static func readApp(_ request: AppReadRequest) -> AppRead {
        let (value, error) = AX.copy(request.app.element, kAXWindowsAttribute)
        var result = AppRead(pid: request.pid, answered: error != .cannotComplete)
        guard result.answered == true else { return result }
        for element in value as? [AXUIElement] ?? [] {
            guard let id = AX.id(element), let record = request.records[id], record.real,
                  !request.known.contains(where: { $0.id == id && CFEqual($0.element.element, element) }),
                  AX.value(element, kAXRoleAttribute) as? String == kAXWindowRole else { continue }
            result.windows.append(WindowRead(id: id, element: AXRef(element), listed: true,
                                             attributes: attributes(element, documents: request.documents)))
        }
        for known in request.known {
            result.windows.append(WindowRead(id: known.id, element: known.element, listed: false,
                                             attributes: attributes(known.element.element, documents: request.documents)))
        }
        return result
    }

    private static func readCandidates(_ candidates: [AXRef], _ request: AppReadRequest) -> AppRead {
        var result = AppRead(pid: request.pid)
        for candidate in candidates {
            let id = result.answered == false ? nil : AX.id(candidate.element)
            result.candidates.append(CandidateRead(element: candidate, id: id))
            guard let id, let record = request.records[id], record.real else { continue }
            let (role, error) = AX.copy(candidate.element, kAXRoleAttribute)
            if result.answered == nil { result.answered = error != .cannotComplete }
            guard result.answered == true, role as? String == kAXWindowRole else { continue }
            result.windows.append(WindowRead(id: id, element: candidate, listed: true,
                                             attributes: attributes(candidate.element, documents: request.documents)))
        }
        return result
    }

    static func attributes(_ element: AXUIElement, documents: Bool) -> WindowAttributes {
        var result = WindowAttributes()
        if documents { result.document = AX.value(element, kAXDocumentAttribute) as? String }
        result.title = AX.value(element, kAXTitleAttribute) as? String
        result.minimized = AX.value(element, kAXMinimizedAttribute) as? Bool
        result.frame = AX.frame(element)
        let subrole = AX.value(element, kAXSubroleAttribute) as? String
        var closeButton: Bool?
        if subrole == kAXUnknownSubrole {
            let (button, error) = AX.copy(element, kAXCloseButtonAttribute)
            if error == .success { closeButton = button != nil }
            else if error == .noValue || error == .attributeUnsupported { closeButton = false }
        }
        result.popup = WindowAttributes.popup(subrole: subrole, closeButton: closeButton)
        if let settable = AX.settable(element, kAXSizeAttribute), let subrole,
           let modal = AX.value(element, kAXModalAttribute) as? Bool {
            result.tileable = subrole == kAXStandardWindowSubrole && !modal && settable
        }
        return result
    }
}
