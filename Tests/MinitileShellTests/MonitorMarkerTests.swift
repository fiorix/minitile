import AppKit
import MinitileCore
import Testing
@testable import minitile

/// Renders the view offscreen at twice its point size and returns the colour of each point in `rect` that it draws.
@MainActor func drawn(_ view: NSView, in rect: CGRect) throws -> [NSColor] {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    var colors: [NSColor] = []
    for y in stride(from: rect.minY, to: rect.maxY, by: 0.5) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 0.5) {
            // Bitmap rows run from the top, as the flipped view's y does.
            if let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale)), color.alphaComponent > 0.75, color.brightnessComponent > 0.3 {
                colors.append(color)
            }
        }
    }
    return colors
}

@MainActor func draws(_ view: NSView, in rect: CGRect) throws -> Bool { try !drawn(view, in: rect).isEmpty }

/// A centre display with managed displays above and to the right, an unmanaged one on the left, and one that only
/// touches its lower right corner.
private let displays = [
    DisplayInfo(id: "centre", frame: Rect(x: 0, y: 0, width: 1512, height: 982), isPrimary: true),
    DisplayInfo(id: "right", frame: Rect(x: 1512, y: 0, width: 1920, height: 900)),
    DisplayInfo(id: "corner", frame: Rect(x: 1512, y: 982, width: 1000, height: 800)),
    DisplayInfo(id: "left", frame: Rect(x: -1512, y: 0, width: 1512, height: 982), unmanagedReason: "No desktop pair"),
    DisplayInfo(id: "above", frame: Rect(x: -408, y: -1080, width: 1920, height: 1080)),
]
private let names = ["centre": "Laptop", "right": "Studio Display", "corner": "Corner", "left": "Left", "above": "LG HDR 4K"]

@Test func monitorMarkersFaceEachManagedDisplayOnASide() {
    #expect(MonitorMarker.markers(for: "centre", displays: displays, names: names)
            == [MonitorMarker(side: .right, name: "Studio Display"), MonitorMarker(side: .up, name: "LG HDR 4K")])
    #expect(MonitorMarker.markers(for: "above", displays: displays, names: names) == [MonitorMarker(side: .down, name: "Laptop")])
    #expect(MonitorMarker.markers(for: "right", displays: displays, names: names) == [MonitorMarker(side: .left, name: "Laptop")])
    #expect(MonitorMarker.markers(for: "corner", displays: displays, names: names).isEmpty)
    #expect(MonitorMarker.markers(for: "left", displays: displays, names: names).isEmpty)
    #expect(MonitorMarker.markers(for: "elsewhere", displays: displays, names: names).isEmpty)
    #expect(MonitorMarker.markers(for: "centre", displays: displays, names: [:]).map(\.name) == ["Display", "Display"])
    // The user's laptop with a 4K screen above it.
    let laptop = DisplayInfo(id: "laptop", frame: Rect(x: 0, y: 0, width: 2056, height: 1329), isPrimary: true)
    let external = DisplayInfo(id: "external", frame: Rect(x: -908, y: -2160, width: 3840, height: 2160))
    let pair = ["laptop": "Built-in Retina Display", "external": "LG HDR 4K"]
    #expect(MonitorMarker.markers(for: "laptop", displays: [laptop, external], names: pair) == [MonitorMarker(side: .up, name: "LG HDR 4K")])
    #expect(MonitorMarker.markers(for: "external", displays: [laptop, external], names: pair)
            == [MonitorMarker(side: .down, name: "Built-in Retina Display")])
}

@Test func indicatorMakesRoomForItsMarkersOnTheirSides() {
    var state = SavedState()
    state.displays = displays.map { info in
        DisplayState(info: info, workspaces: [WorkspaceState(id: 1, home: info.id, pages: [PageState(id: 1)], currentPage: 1)], currentWorkspace: 1)
    }
    let content = GridIndicatorContent(display: state.displays[0], state: state, config: .default, names: names)
    #expect(content.displayName == "Laptop")
    #expect(content.markers.map(\.side) == [.right, .up])
    var bare = content
    bare.markers = []
    let geometry = GridIndicatorGeometry(content: content), plain = GridIndicatorGeometry(content: bare)
    #expect(geometry.markers == [.right, .up])
    #expect(geometry.inner == plain.size)
    #expect(geometry.size == CGSize(width: plain.size.width + 112, height: plain.size.height + 48))
    #expect(geometry.inset == CGPoint(x: 0, y: 48))
    // The inner layout is unchanged; the views draw it at the inset.
    #expect(geometry.cellRect(row: 0, column: 0) == plain.cellRect(row: 0, column: 0))
    #expect(geometry.footerRect == plain.footerRect)
    // An unmanaged display's warning has no neighbours to mark.
    let unmanaged = GridIndicatorContent(display: state.displays[3], state: state, config: .default, names: names)
    #expect(unmanaged.markers.isEmpty && unmanaged.warning != nil)
}

@Test(arguments: [GridMetrics.indicator, .switcher])
func markersSitInTheMiddleOfTheirEdgesWithTheChevronOutside(metrics: GridMetrics) {
    let area = Rect(x: 0, y: 0, width: 3840, height: 2160)
    let geometry = GridIndicatorGeometry(area: area, rows: 2, columns: 3, cropped: false, markers: Set(SwitcherDirection.allCases),
                                         metrics: metrics)
    let s = geometry.metrics.scale, size = geometry.size, inset = geometry.inset
    #expect(s == 2)
    #expect(size == CGSize(width: geometry.inner.width + 224, height: geometry.inner.height + 96))
    #expect(inset == CGPoint(x: 112, y: 48))
    let panel = CGRect(origin: .zero, size: size), inner = CGRect(origin: inset, size: geometry.inner)
    for side in SwitcherDirection.allCases {
        let marker = geometry.marker(side)
        #expect(marker.screen.size == CGSize(width: 32, height: 24), "\(side)")
        #expect(panel.contains(marker.screen) && panel.contains(marker.chevron) && panel.contains(marker.name), "\(side)")
        #expect(!marker.screen.intersects(inner) && !marker.chevron.intersects(inner) && !marker.name.intersects(inner), "\(side)")
        switch side {
        case .up, .down:
            #expect(abs(marker.screen.midX - size.width / 2) <= 1 && abs(marker.chevron.midX - marker.screen.midX) <= 1)
            #expect(side == .up ? marker.chevron.maxY <= marker.screen.minY : marker.chevron.minY >= marker.screen.maxY)
            #expect(marker.name.minX > marker.screen.maxX && abs(marker.name.midY - (marker.screen.minY + 4.5 * s)) <= 1)
        case .left, .right:
            #expect(abs(marker.screen.midY - size.height / 2) <= 1)
            #expect(side == .left ? marker.chevron.maxX <= marker.screen.minX : marker.chevron.minX >= marker.screen.maxX)
            #expect(marker.name.minY > marker.screen.maxY && abs(marker.name.midX - (side == .left ? 56 : size.width - 56)) <= 1)
        }
    }
    // A scaled-down panel scales its markers with it and still fits.
    let laptop = Rect(x: 0, y: 33, width: 1512, height: 945)
    let fitted = GridIndicatorGeometry(area: laptop, rows: 4, columns: 5, cropped: true, markers: Set(SwitcherDirection.allCases),
                                       metrics: metrics)
    #expect(fitted.size.width <= laptop.width - 2 * PanelStyle.inset && fitted.size.height <= laptop.height - 2 * PanelStyle.inset)
    #expect(fitted.marker(.up).screen.width == (16 * fitted.metrics.scale).rounded())
}

@Test @MainActor func markersAreDrawnInUnlitWireWithTheDisplaysName() throws {
    let pages = [[GridMiniature(), GridMiniature()]]
    let content = GridIndicatorContent(displayName: "Laptop", active: true, workspace: 1, page: 1, area: Rect(x: 0, y: 33, width: 1512, height: 945),
                                       pages: pages, warning: nil, markers: [MonitorMarker(side: .up, name: "LG HDR 4K"),
                                                                             MonitorMarker(side: .left, name: "Studio")])
    let view = GridIndicatorView(content: content)
    let geometry = GridIndicatorGeometry(content: content)
    #expect(view.bounds.size == geometry.size)
    for side in [SwitcherDirection.up, .left] {
        let marker = geometry.marker(side)
        #expect(try draws(view, in: marker.screen.insetBy(dx: -1, dy: -1)), "\(side)")
        #expect(try draws(view, in: marker.chevron.insetBy(dx: -1, dy: -1)), "\(side)")
        #expect(try draws(view, in: marker.name), "\(side)")
    }
    // Nothing in the bands is neon: the halo of a lit line would tint them cyan.
    let bands = [CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.inset.y),
                 CGRect(x: 0, y: 0, width: geometry.inset.x, height: geometry.size.height)]
    for band in bands {
        let colors = try drawn(view, in: band).compactMap { $0.usingColorSpace(.sRGB) }
        #expect(!colors.isEmpty)
        #expect(colors.allSatisfy { $0.greenComponent - $0.redComponent < 0.3 })
    }
    // The header moves down past the top band.
    let header = CGRect(x: geometry.inset.x + geometry.margin, y: geometry.inset.y + 12 * 2, width: 60, height: 20)
    #expect(try draws(view, in: header))
}

@Test func switcherCarriesTheMarkersOfTheSelectionsDisplay() throws {
    var state = SavedState()
    state.displays = displays.enumerated().map { d, info in
        var page = PageState(id: UInt64(d + 1))
        page.windows = [WindowID(d + 1)]
        return DisplayState(info: info, workspaces: [WorkspaceState(id: UInt64(d + 1), home: info.id, pages: [page], currentPage: page.id)],
                            currentWorkspace: UInt64(d + 1))
    }
    for (d, info) in displays.enumerated() {
        let id = WindowID(d + 1)
        state.windows[id] = WindowState(info: WindowInfo(id: id, pid: Int32(id), display: info.id), display: info.id, floating: false)
    }
    // The ring: above (5), centre (1), right (2), corner (3).
    var selection = try #require(SwitcherSelection(state: state, config: .default, forward: true))
    #expect(selection.order == [5, 1, 2, 3])
    var content = SwitcherContent(selection: selection, state: state, names: names)
    #expect(selection.display == "above" && content.markers == [MonitorMarker(side: .down, name: "Laptop")])
    #expect(content.geometry.markers == [.down])
    selection.step(forward: true)
    content = SwitcherContent(selection: selection, state: state, names: names)
    #expect(content.markers.map(\.side) == [.right, .up] && content.geometry.markers == [.right, .up])
    #expect(content.displayName == "Laptop")
    selection.step(forward: true)
    selection.step(forward: true)
    content = SwitcherContent(selection: selection, state: state, names: names)
    #expect(selection.display == "corner" && content.markers.isEmpty)
}
