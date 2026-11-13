import Foundation

/// Native tiling can leave empty slots. Retain its observed frames to identify the chosen slots, then lay them
/// out with minitile's spacing until the page's active tiles, display area or an explicit layout operation change.
public struct NativeLayout: Codable, Sendable, Equatable {
    public var area: Rect
    public var windows: [WindowID]
    public var frames: [Rect]

    public func targets(windows active: [WindowID], area: Rect, gaps: Double, padding: Double) -> [WindowID: Rect]? {
        guard self.area == area, windows == active, frames.count == active.count,
              Set(active).count == active.count, (1...4).contains(active.count),
              frames.allSatisfy({ frame in
                  [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
                      && frame.width > 0 && frame.height > 0
                      && frame.x >= area.x - 2 && frame.y >= area.y - 2
                      && frame.maxX <= area.maxX + 2 && frame.maxY <= area.maxY + 2
              }) else { return nil }
        guard let tile = NativeTile(frame: frames[0], area: area, windows: active.count, companions: Array(frames.dropFirst())) else { return nil }
        let slots = frames.compactMap { tile.slot(matching: $0) }
        guard slots.count == active.count else { return nil }
        let spaced = Layout.frames(frame: area, count: tile.count, variant: tile.variant, gaps: gaps, padding: padding)
        return Dictionary(uniqueKeysWithValues: zip(active, slots.map { spaced[$0] }))
    }
}

/// Recognizes fill, halves and quarters from settled desktop geometry, including native tiling margins.
public struct NativeTile: Equatable, Sendable {
    public var count: Int
    public var variant: Variant
    public var slot: Int
    public var frames: [Rect]

    public func slot(matching frame: Rect) -> Int? {
        frames.firstIndex { abs($0.x - frame.x) <= 3 && abs($0.y - frame.y) <= 3
            && abs($0.width - frame.width) <= 3 && abs($0.height - frame.height) <= 3 }
    }

    public init?(frame: Rect, area: Rect, windows: Int, companions: [Rect] = []) {
        guard (1...4).contains(windows), area.width > 0, area.height > 0,
              [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return nil }
        // Keep as many neighbours as the chosen shape permits. Sparse pages use an empty native slot.
        let counts = Array(windows...4) + Array((1..<windows).reversed())
        for count in counts {
            for variant in Layout.variants(count: count) where !Layout.sliced(count: count, variant: variant) {
                let ideal = Layout.frames(frame: area, count: count, variant: variant, gaps: 0, padding: 0)
                for (slot, tile) in ideal.enumerated() {
                    let edges = [(frame.x - tile.x, tile.x == area.x),
                                 (tile.maxX - frame.maxX, tile.maxX == area.maxX),
                                 (frame.y - tile.y, tile.y == area.y),
                                 (tile.maxY - frame.maxY, tile.maxY == area.maxY)]
                    guard edges.allSatisfy({ (-2...24).contains($0.0) }) else { continue }
                    let outer = edges.filter(\.1).map(\.0), inner = edges.filter { !$0.1 }.map(\.0)
                    guard (outer.max()! - outer.min()!) <= 3,
                          inner.isEmpty || inner.max()! - inner.min()! <= 3 else { continue }
                    let padding = max(0, outer.reduce(0, +) / Double(outer.count))
                    // Layout's split is measured inside its padding; at a half its center is unchanged.
                    let gaps = inner.isEmpty ? 0 : max(0, 2 * inner.reduce(0, +) / Double(inner.count))
                    var frames = Layout.frames(frame: area, count: count, variant: variant, gaps: gaps, padding: padding)
                    frames[slot] = frame
                    var candidate = NativeTile(count: count, variant: variant, slot: slot, frames: frames)
                    var occupied: Set<Int> = [slot]
                    var matches = true
                    for companion in companions {
                        guard let index = candidate.slot(matching: companion), occupied.insert(index).inserted else { matches = false; break }
                        candidate.frames[index] = companion
                    }
                    guard matches else { continue }
                    self = candidate
                    return
                }
            }
        }
        return nil
    }

    private init(count: Int, variant: Variant, slot: Int, frames: [Rect]) {
        self.count = count; self.variant = variant; self.slot = slot; self.frames = frames
    }
}

extension Engine {
    mutating func nativeTiled(_ id: WindowID, frame: Rect, companions: [WindowID: Rect], output: inout Output) {
        guard let window = state.windows[id], !window.floating, !window.hidden, !window.info.fullscreen,
              let at = location(id), isShown(at) else { return }
        let active = tiled(page(at), activeOnly: true)
        let area = state.displays[at.display].info.visibleFrame
        let companions = companions.filter { $0.key != id && active.contains($0.key) }
        guard active.contains(id), let tile = NativeTile(frame: frame, area: area, windows: active.count,
                                                        companions: companions.keys.sorted().compactMap { companions[$0] }) else { return }
        let others = active.filter { $0 != id }
        let prioritized = others.filter { companions[$0] != nil } + others.filter { companions[$0] == nil }
        let kept = Array(prioritized.prefix(tile.count - 1))
        // Overflow gets its own workspace without taking the view or focus away from the native selection.
        for (offset, other) in others.filter({ !kept.contains($0) }).enumerated() {
            removeFromPage(other)
            var workspace = newWorkspace(home: state.displays[at.display].info.id)
            workspace.pages[0].windows = [other]
            state.displays[at.display].workspaces.insert(workspace, at: at.workspace + 1 + offset)
            output.events.append(Event(type: "window_moved", data: .number(Double(other))))
        }
        var assigned = [tile.slot: id]
        for other in kept {
            if let frame = companions[other], let slot = tile.slot(matching: frame) { assigned[slot] = other }
        }
        for (slot, other) in zip(tile.frames.indices.filter { assigned[$0] == nil }, kept.filter { companions[$0] == nil }) { assigned[slot] = other }
        let slots = assigned.keys.sorted()
        let ordered = slots.map { assigned[$0]! }
        let old = page(at).windows
        var remaining = ordered.makeIterator()
        state.displays[at.display].workspaces[at.workspace].pages[at.page].windows = old.map {
            active.contains($0) ? remaining.next()! : $0
        }
        state.displays[at.display].workspaces[at.workspace].pages[at.page].variant = tile.variant
        state.displays[at.display].workspaces[at.workspace].pages[at.page].r1 = 0.5
        state.displays[at.display].workspaces[at.workspace].pages[at.page].r2 = 0.5
        state.displays[at.display].workspaces[at.workspace].pages[at.page].nativeLayout = NativeLayout(
            area: area, windows: ordered, frames: slots.map { tile.frames[$0] })
        state.windows[id]?.info.frame = frame
        for (id, frame) in companions { state.windows[id]?.info.frame = frame }
        if state.focus.flatMap(location).map(isShown) != true { focus(id, action: false, output: &output) }
        for (before, after) in zip(old, page(at).windows) where before != after {
            output.events.append(Event(type: "window_moved", data: .number(Double(after))))
        }
    }
}
