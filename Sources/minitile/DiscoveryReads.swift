import AppKit
@preconcurrency import ApplicationServices
import CSkyLight
import MinitileCore

/// Carries an AX element to a background read and back. AX client calls work from any thread.
struct AXRef: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

enum WindowAttribute: CaseIterable, Sendable {
    case title, minimized, frame, tileable, document, popup, fullscreen, spaces

    static let all = Set(allCases)

    static func reads(for notification: String) -> Set<Self> {
        switch notification {
        case kAXMovedNotification: [.frame, .spaces]
        case kAXResizedNotification: [.frame, .fullscreen, .spaces]
        // A document read only happens in a smoke run, where Save As changes the document with the title.
        case kAXTitleChangedNotification: [.title, .document, .spaces]
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification: [.minimized, .spaces]
        default: all
        }
    }
}

/// Nil means not read or failed, so the prior value stays; Spaces are read on every attribute pass, with nil for no Space.
struct WindowAttributes: Equatable, Sendable {
    var title: String?
    var minimized: Bool?
    var frame: Rect?
    var tileable: Bool?
    /// Read only for a smoke run.
    var document: String?
    /// True for a popup, which minitile never manages; nil when unknown.
    var popup: Bool?
    /// The app's word that the window is full screen (`AXFullScreen`).
    var fullscreen: Bool?
    /// The native Spaces the window stands on.
    var spaces: [UInt64]?

    /// A popup, such as a browser's address bar suggestions, has no meaningful subrole and no close button. Nil
    /// when the subrole could not be read, or the close button could not be for an `AXUnknown` window.
    static func popup(subrole: String?, closeButton: Bool?) -> Bool? {
        guard let subrole else { return nil }
        guard subrole == kAXUnknownSubrole else { return false }
        return closeButton.map { !$0 }
    }
}

/// Whether a window is full screen, from two signs that change at different moments: its app's word and its
/// standing on a native fullscreen Space. Either makes it full screen, so minitile lets go of the window as soon as it
/// starts to leave the desktop and takes it back only once it has returned. A sign that could not be read stays as
/// it was.
struct FullscreenSigns: Equatable, Sendable {
    private(set) var attribute = false
    private(set) var space = false

    var fullscreen: Bool { attribute || space }

    mutating func observe(attribute: Bool?, space: Bool?) {
        self.attribute = attribute ?? self.attribute
        self.space = space ?? self.space
    }
}

/// A window entering or leaving full screen stands on no Space while macOS animates it, about half a second, and no
/// notification is sure to follow when it lands. Such a window is reread every tenth of a second until its Spaces
/// can be read again, for a bounded number of times; the three-second scan takes over after that.
struct TransitRereads {
    static let interval: TimeInterval = 0.1
    static let limit = 20

    private var left: [WindowID: Int] = [:]
    private var pending: Set<WindowID> = []

    /// Records what the latest read found. True when a reread should be scheduled now.
    mutating func reread(_ id: WindowID, inTransit: Bool) -> Bool {
        guard inTransit else { left.removeValue(forKey: id); return false }
        let remaining = left[id] ?? Self.limit
        guard remaining > 0, !pending.contains(id) else { return false }
        left[id] = remaining - 1
        pending.insert(id)
        return true
    }

    /// The scheduled reread is due. False when the window was forgotten meanwhile.
    mutating func fired(_ id: WindowID) -> Bool { pending.remove(id) != nil }

    mutating func forget(_ id: WindowID) { left.removeValue(forKey: id); pending.remove(id) }
}

extension WindowInfo {
    /// `geometry` is false while minitile's own frame write is settling, so the stale frame is not taken. Whether a
    /// window tiles is judged on the desktop, so a full screen window keeps what was known.
    mutating func apply(_ attributes: WindowAttributes, appHidden: Bool, geometry: Bool, fullscreen: Bool) {
        title = attributes.title ?? title
        minimized = attributes.minimized ?? minimized
        self.appHidden = appHidden
        self.fullscreen = fullscreen
        if geometry { frame = attributes.frame ?? frame }
        if let tileable = attributes.tileable, !fullscreen { self.tileable = tileable }
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

/// Finds windows off screen on a shown desktop, or on no Space as inactive native tabs are. It runs right after the
/// snapshot on the same thread, so a page change rarely falls between the two.
struct OffScreenProbe: Sendable {
    var windows: [WindowID]
    /// Each managed display's identifier and visible desktop.
    var desktops: [(display: String, space: UInt64)]

    static func orderedOut(onScreen: Bool, spaces: [UInt64]?, shown: Set<UInt64>) -> Bool {
        guard !onScreen, let spaces else { return false }
        return spaces.isEmpty || spaces.contains(where: shown.contains)
    }

    func run(_ snapshot: [WindowID: CGWindowRecord]) -> Set<WindowID> {
        let shown = Set(desktops.compactMap { csl_current_space($0.display as CFString) == $0.space ? $0.space : nil })
        guard !shown.isEmpty else { return [] }
        return Set(windows.filter { id in
            guard let record = snapshot[id], !record.onScreen else { return false }
            return Self.orderedOut(onScreen: record.onScreen, spaces: DisplayCatalog.readWindowSpaces(id), shown: shown)
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
    /// Native fullscreen Spaces. A window standing on one that is not on screen is missing from the app's list.
    var fullscreenSpaces: Set<UInt64> = []
    /// Windows already searched for by element number, which are not searched for again.
    var searched: Set<WindowID> = []
}

struct WindowRead: Sendable {
    var id: WindowID
    var element: AXRef
    /// Not yet known when the read began: listed by the app or a creation candidate.
    var listed: Bool
    var attributes: WindowAttributes
    var tabGroup: AXRef? = nil
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
    /// Windows searched for by element number in this read, found or not.
    var searched: [WindowID] = []
    var milliseconds = 0.0
}

/// An app's `AXWindows` omits windows on Spaces that are not on screen, which is where a full screen window stands
/// while the user works elsewhere. Their elements are still reachable by number: an app numbers its elements as it
/// hands them out, so the search walks the numbers until it has the windows it wants. An old process can be far
/// along, so the walk has a time budget.
enum ElementSearch {
    static let budget: TimeInterval = 1.5

    /// The window among `wanted` that each numbered element is, by `window(number)`: nil ends the search (an app that
    /// stopped answering, or no way to reach elements by number), and 0 is an element that is no window. Stops once
    /// every wanted window is found or `expired` says the budget is spent, which is asked every 256 numbers.
    static func find(_ wanted: Set<WindowID>, window: (UInt64) -> WindowID?, expired: () -> Bool) -> [WindowID: UInt64] {
        var found: [WindowID: UInt64] = [:]
        var number: UInt64 = 0
        while found.count < wanted.count {
            if number % 256 == 255, expired() { break }
            guard let id = window(number) else { break }
            if wanted.contains(id), found[id] == nil { found[id] = number }
            number += 1
        }
        return found
    }

    static func elements(_ wanted: Set<WindowID>, pid: Int32) -> [WindowID: AXUIElement] {
        var elements: [UInt64: AXUIElement] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        let found = find(wanted, window: { number in
            guard let element = csl_copy_element(pid, number) else { return nil }
            let (role, error) = AX.copy(element, kAXRoleAttribute)
            if error == .cannotComplete { return nil }
            guard role as? String == kAXWindowRole, let id = AX.id(element), wanted.contains(id) else { return 0 }
            elements[number] = element
            return id
        }, expired: { ProcessInfo.processInfo.systemUptime > deadline })
        return found.compactMapValues { elements[$0] }
    }
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
        var listed = Set<WindowID>()
        var tabGroups: [WindowID: AXRef] = [:]
        for element in value as? [AXUIElement] ?? [] {
            guard let id = AX.id(element) else { continue }
            listed.insert(id)
            tabGroups[id] = NativeTabs.group(element)
            guard let record = request.records[id], record.real,
                  !request.known.contains(where: { $0.id == id && CFEqual($0.element.element, element) }),
                  AX.value(element, kAXRoleAttribute) as? String == kAXWindowRole else { continue }
            result.windows.append(WindowRead(id: id, element: AXRef(element), listed: true,
                                             attributes: attributes(element, id: id, documents: request.documents), tabGroup: tabGroups[id]))
        }
        result.searched = unlisted(request, listed: listed)
        for (id, element) in ElementSearch.elements(Set(result.searched), pid: request.pid) {
            result.windows.append(WindowRead(id: id, element: AXRef(element), listed: true,
                                             attributes: attributes(element, id: id, documents: request.documents)))
        }
        for known in request.known {
            result.windows.append(WindowRead(id: known.id, element: known.element, listed: false,
                                             attributes: attributes(known.element.element, id: known.id, documents: request.documents),
                                             tabGroup: tabGroups[known.id]))
        }
        return result
    }

    /// The app's unknown real windows that stand on a fullscreen Space and were not listed. Without a fullscreen Space
    /// there is nothing to ask.
    private static func unlisted(_ request: AppReadRequest, listed: Set<WindowID>) -> [WindowID] {
        guard !request.fullscreenSpaces.isEmpty else { return [] }
        return request.records.values.filter { record in
            record.real && !listed.contains(record.id) && !request.searched.contains(record.id)
                && !request.known.contains { $0.id == record.id }
                && DisplayCatalog.windowSpaces(record.id).contains(where: request.fullscreenSpaces.contains)
        }.map(\.id).sorted()
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
                                             attributes: attributes(candidate.element, id: id, documents: request.documents),
                                             tabGroup: NativeTabs.group(candidate.element)))
        }
        return result
    }

    static func attributes(_ element: AXUIElement, id: WindowID, documents: Bool,
                           reading: Set<WindowAttribute> = WindowAttribute.all) -> WindowAttributes {
        attributes(reading: reading, documents: documents, copy: { AX.copy(element, $0) },
                   frame: { AX.frame(element) }, settable: { AX.settable(element, kAXSizeAttribute) },
                   spaces: { DisplayCatalog.windowSpaces(id) })
    }

    static func attributes(reading: Set<WindowAttribute>, documents: Bool,
                           copy: (String) -> (value: CFTypeRef?, error: AXError), frame: () -> Rect?,
                           settable: () -> Bool?, spaces: () -> [UInt64]) -> WindowAttributes {
        var result = WindowAttributes()
        if reading.contains(.spaces) {
            let windowSpaces = spaces()
            if !windowSpaces.isEmpty { result.spaces = windowSpaces }
        }
        if reading.contains(.fullscreen) {
            // A window whose app has no such attribute is never full screen by its word.
            let (fullscreen, error) = copy("AXFullScreen")
            result.fullscreen = fullscreen as? Bool ?? (error == .attributeUnsupported || error == .noValue ? false : nil)
        }
        if documents && reading.contains(.document) { result.document = copy(kAXDocumentAttribute).value as? String }
        if reading.contains(.title) { result.title = copy(kAXTitleAttribute).value as? String }
        if reading.contains(.minimized) { result.minimized = copy(kAXMinimizedAttribute).value as? Bool }
        if reading.contains(.frame) { result.frame = frame() }
        if reading.contains(.popup) || reading.contains(.tileable) {
            let subrole = copy(kAXSubroleAttribute).value as? String
            if reading.contains(.popup) {
                var closeButton: Bool?
                if subrole == kAXUnknownSubrole {
                    let (button, error) = copy(kAXCloseButtonAttribute)
                    if error == .success { closeButton = button != nil }
                    else if error == .noValue || error == .attributeUnsupported { closeButton = false }
                }
                result.popup = WindowAttributes.popup(subrole: subrole, closeButton: closeButton)
            }
            if reading.contains(.tileable), let settable = settable(), let subrole,
               let modal = copy(kAXModalAttribute).value as? Bool {
                result.tileable = subrole == kAXStandardWindowSubrole && !modal && settable
            }
        }
        return result
    }
}
