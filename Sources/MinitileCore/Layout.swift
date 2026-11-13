import Foundation

/// Deterministic tile geometry in global coordinates. Cuts are positions across the padded area.
public enum Layout {
    public static func area(frame: Rect, padding: Double) -> Rect {
        let x = min(max(0, padding), max(0, frame.width) / 2)
        let y = min(max(0, padding), max(0, frame.height) / 2)
        return Rect(x: frame.x + x, y: frame.y + y, width: max(0, frame.width - 2 * x), height: max(0, frame.height - 2 * y))
    }

    /// A tile's extent along one axis. Each end lies on the layout area's border (nil) or on a cut: 0 for r1, 1 for r2.
    struct Span: Equatable {
        var start: Int?
        var end: Int?
    }

    /// A tile in layout axes, which a portrait display swaps: `long` runs along the display's long axis.
    struct Tile: Equatable {
        var long: Span
        var short: Span
        func span(long: Bool) -> Span { long ? self.long : short }
    }

    /// The single description of every layout, by slot. Frames, edge drags and resizes all read their cuts from it.
    /// Variants a count does not define use its first layout.
    static func tiles(count: Int, variant: Variant) -> [Tile] {
        func tile(_ long: (Int?, Int?), _ short: (Int?, Int?)) -> Tile {
            Tile(long: Span(start: long.0, end: long.1), short: Span(start: short.0, end: short.1))
        }
        let all: (Int?, Int?) = (nil, nil)
        switch (count, variant) {
        case (1, _): return [tile(all, all)]
        case (2, .alternate): return [tile(all, (nil, 0)), tile(all, (0, nil))]
        case (2, _): return [tile((nil, 0), all), tile((0, nil), all)]
        case (3, .alternate): return [tile((nil, 0), all), tile((0, 1), all), tile((1, nil), all)]
        case (3, .twoByOneTall): return [tile((0, nil), all), tile((nil, 0), (nil, 1)), tile((nil, 0), (1, nil))]
        case (3, .oneByTwoWide): return [tile(all, (nil, 0)), tile((nil, 1), (0, nil)), tile((1, nil), (0, nil))]
        case (3, .twoByOneWide): return [tile(all, (0, nil)), tile((nil, 1), (nil, 0)), tile((1, nil), (nil, 0))]
        case (3, .stacked): return [tile(all, (nil, 0)), tile(all, (0, 1)), tile(all, (1, nil))]
        case (3, _): return [tile((nil, 0), all), tile((0, nil), (nil, 1)), tile((0, nil), (1, nil))]
        case (4, _): return [tile((nil, 0), (nil, 1)), tile((0, nil), (nil, 1)), tile((nil, 0), (1, nil)), tile((0, nil), (1, nil))]
        default: return []
        }
    }

    /// The layouts a count defines, in cycling order.
    public static func variants(count: Int) -> [Variant] {
        switch count {
        case 1, 4: [.standard]
        case 2: [.standard, .alternate]
        case 3: [.oneByTwoTall, .twoByOneTall, .oneByTwoWide, .twoByOneWide, .alternate, .stacked]
        default: []
        }
    }

    /// The layout a count uses for `variant`: its own where the count defines it, otherwise the count's first.
    public static func effective(_ variant: Variant, count: Int) -> Variant {
        let order = variants(count: count)
        return order.contains(variant) ? variant : order.first ?? .standard
    }

    /// The variant after `variant` in its count's cycling order, or nil when the count has one layout.
    static func next(_ variant: Variant, count: Int) -> Variant? {
        let order = variants(count: count)
        guard order.count > 1, let index = order.firstIndex(of: effective(variant, count: count)) else { return nil }
        return order[(index + 1) % order.count]
    }

    /// Three slices: both cuts lie on one axis and keep 0.2 apart.
    static func sliced(count: Int, variant: Variant) -> Bool {
        count == 3 && (variant == .alternate || variant == .stacked)
    }

    public static func defaults(count: Int, variant: Variant) -> (Double, Double) {
        sliced(count: count, variant: variant) ? (1.0 / 3, 2.0 / 3) : (0.5, 0.5)
    }

    public static func ratios(_ first: Double, _ second: Double, count: Int, variant: Variant) -> (Double, Double) {
        var a = min(0.8, max(0.2, first))
        var b = min(0.8, max(0.2, second))
        if sliced(count: count, variant: variant) && b - a < 0.2 {
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
        let cuts = [a, b]
        return tiles(count: count, variant: variant).map { tile in
            rect(tile.long.start.map { cuts[$0] } ?? 0, tile.long.end.map { cuts[$0] } ?? 1,
                 tile.short.start.map { cuts[$0] } ?? 0, tile.short.end.map { cuts[$0] } ?? 1)
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
                    if page(at).windows.contains(where: isFullscreen)
                        || page(at).nativeLayout?.targets(windows: tiled(page(at), activeOnly: true),
                                                     area: state.displays[d].info.visibleFrame, gaps: config.gaps, padding: config.padding) == nil {
                        state.displays[d].workspaces[w].pages[p].nativeLayout = nil
                    }
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
        if let targets = page.nativeLayout?.targets(windows: ids, area: state.displays[at.display].info.visibleFrame,
                                                   gaps: config.gaps, padding: config.padding) { return targets }
        let frames = Layout.frames(frame: state.displays[at.display].info.visibleFrame, count: ids.count,
                                   variant: page.variant, r1: page.r1, r2: page.r2, gaps: config.gaps, padding: config.padding)
        return Dictionary(uniqueKeysWithValues: zip(ids, frames))
    }

    mutating func variant(_ at: Location) {
        state.displays[at.display].workspaces[at.workspace].pages[at.page].nativeLayout = nil
        let count = tiled(page(at), activeOnly: true).count
        guard let value = Layout.next(page(at).variant, count: count) else { return }
        let (a, b) = Layout.defaults(count: count, variant: value)
        state.displays[at.display].workspaces[at.workspace].pages[at.page].variant = value
        setRatios(at, a, b)
    }

    mutating func setRatios(_ at: Location, _ a: Double, _ b: Double, preserveFirst: Bool = false, preserveSecond: Bool = false) {
        state.displays[at.display].workspaces[at.workspace].pages[at.page].nativeLayout = nil
        let count = tiled(page(at), activeOnly: true).count
        var a = a, b = b
        if Layout.sliced(count: count, variant: page(at).variant) {
            if preserveSecond { a = min(a, b - 0.2) }
            if preserveFirst { b = max(b, a + 0.2) }
        }
        let (first, second) = Layout.ratios(a, b, count: count, variant: page(at).variant)
        state.displays[at.display].workspaces[at.workspace].pages[at.page].r1 = first
        state.displays[at.display].workspaces[at.workspace].pages[at.page].r2 = second
    }
}
