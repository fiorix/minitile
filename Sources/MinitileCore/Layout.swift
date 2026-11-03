import Foundation

/// Deterministic tile geometry in global coordinates. Cuts are positions across the padded area.
public enum Layout {
    public static func area(frame: Rect, padding: Double) -> Rect {
        let x = min(max(0, padding), max(0, frame.width) / 2)
        let y = min(max(0, padding), max(0, frame.height) / 2)
        return Rect(x: frame.x + x, y: frame.y + y, width: max(0, frame.width - 2 * x), height: max(0, frame.height - 2 * y))
    }

    public static func defaults(count: Int, variant: Variant) -> (Double, Double) {
        count == 3 && variant == .alternate ? (1.0 / 3, 2.0 / 3) : (0.5, 0.5)
    }

    public static func ratios(_ first: Double, _ second: Double, count: Int, variant: Variant) -> (Double, Double) {
        var a = min(0.8, max(0.2, first))
        var b = min(0.8, max(0.2, second))
        if count == 3 && variant == .alternate && b - a < 0.2 {
            b = min(0.8, a + 0.2)
            a = min(a, b - 0.2)
        }
        return (a, b)
    }

    public static func frames(frame: Rect, count: Int, variant: Variant = .standard,
                              r1: Double? = nil, r2: Double? = nil, gaps: Double = 8, padding: Double = 8) -> [Rect] {
        guard (1...4).contains(count) else { return [] }
        let area = area(frame: frame, padding: padding)
        let landscape = frame.width >= frame.height
        let long = landscape ? area.width : area.height
        let short = landscape ? area.height : area.width
        let defaults = defaults(count: count, variant: variant)
        let (a, b) = ratios(r1 ?? defaults.0, r2 ?? defaults.1, count: count, variant: variant)
        let gap = max(0, gaps)
        func rect(_ u0: Double, _ u1: Double, _ v0: Double, _ v1: Double) -> Rect {
            let left = u0 * long + (u0 > 0 ? gap / 2 : 0)
            let right = u1 * long - (u1 < 1 ? gap / 2 : 0)
            let top = v0 * short + (v0 > 0 ? gap / 2 : 0)
            let bottom = v1 * short - (v1 < 1 ? gap / 2 : 0)
            let x0 = (area.x + (landscape ? left : top)).rounded()
            let x1 = (area.x + (landscape ? right : bottom)).rounded()
            let y0 = (area.y + (landscape ? top : left)).rounded()
            let y1 = (area.y + (landscape ? bottom : right)).rounded()
            return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
        }
        switch count {
        case 1: return [rect(0, 1, 0, 1)]
        case 2 where variant == .alternate: return [rect(0, 1, 0, a), rect(0, 1, a, 1)]
        case 2: return [rect(0, a, 0, 1), rect(a, 1, 0, 1)]
        case 3 where variant == .alternate: return [rect(0, a, 0, 1), rect(a, b, 0, 1), rect(b, 1, 0, 1)]
        case 3: return [rect(0, a, 0, 1), rect(a, 1, 0, b), rect(a, 1, b, 1)]
        default: return [rect(0, a, 0, b), rect(a, 1, 0, b), rect(0, a, b, 1), rect(a, 1, b, 1)]
        }
    }
}

extension Engine {
    mutating func resetLayouts() {
        for d in state.displays.indices {
            for w in state.displays[d].workspaces.indices {
                for p in state.displays[d].workspaces[w].pages.indices {
                    let at = Location(display: d, workspace: w, page: p)
                    let count = tiled(page(at), activeOnly: true).count
                    if page(at).layoutCount != count {
                        let (a, b) = Layout.defaults(count: count, variant: page(at).variant)
                        state.displays[d].workspaces[w].pages[p].r1 = a
                        state.displays[d].workspaces[w].pages[p].r2 = b
                        state.displays[d].workspaces[w].pages[p].layoutCount = count
                    }
                    let current = page(at)
                    let (a, b) = Layout.ratios(current.r1, current.r2, count: count, variant: current.variant)
                    state.displays[d].workspaces[w].pages[p].r1 = a
                    state.displays[d].workspaces[w].pages[p].r2 = b
                }
            }
        }
    }

    func frames(_ at: Location) -> [WindowID: Rect] {
        let page = page(at)
        let ids = tiled(page, activeOnly: true)
        let frames = Layout.frames(frame: state.displays[at.display].info.visibleFrame, count: ids.count,
                                   variant: page.variant, r1: page.r1, r2: page.r2, gaps: config.gaps, padding: config.padding)
        return Dictionary(uniqueKeysWithValues: zip(ids, frames))
    }

    mutating func variant(_ at: Location) {
        let value: Variant = page(at).variant == .standard ? .alternate : .standard
        let (a, b) = Layout.defaults(count: tiled(page(at), activeOnly: true).count, variant: value)
        state.displays[at.display].workspaces[at.workspace].pages[at.page].variant = value
        setRatios(at, a, b)
    }

    mutating func setRatios(_ at: Location, _ a: Double, _ b: Double, preserveFirst: Bool = false, preserveSecond: Bool = false) {
        let count = tiled(page(at), activeOnly: true).count
        var a = a, b = b
        if count == 3 && page(at).variant == .alternate {
            if preserveSecond { a = min(a, b - 0.2) }
            if preserveFirst { b = max(b, a + 0.2) }
        }
        let (first, second) = Layout.ratios(a, b, count: count, variant: page(at).variant)
        state.displays[at.display].workspaces[at.workspace].pages[at.page].r1 = first
        state.displays[at.display].workspaces[at.workspace].pages[at.page].r2 = second
    }
}
