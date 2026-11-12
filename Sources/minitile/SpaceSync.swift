import AppKit
import CSkyLight
import MinitileCore

/// A page lives on a native Space: a full screen window's page on that window's fullscreen Space, any other page on
/// its display's visible desktop. macOS does not follow minitile's focus from one to the other, so after a command
/// the shell puts each display the command acted on onto its page's Space itself, with the instant switch.
enum SpaceSync {
    /// macOS answers a Space switch by activating an app with a window on the new Space, within about 60 ms.
    static let activationInterval: TimeInterval = 0.5

    /// The displays a command acted on: those whose shown page changed and those holding a window it focused.
    static func displays(before: SavedState, after: SavedState, actions: [Action]) -> Set<DisplayID> {
        var result = Set<DisplayID>()
        for display in after.displays {
            guard let to = ShownView(display) else { continue }
            let from = before.displays.first { $0.info.id == display.info.id }.flatMap(ShownView.init)
            if from != to { result.insert(display.info.id) }
        }
        for case .focus(let id) in actions {
            if let display = after.windows[id]?.display { result.insert(display) }
        }
        return result
    }

    /// The Space to switch a display to, or nil to leave it. `page` is the Space of the page it shows. A display goes
    /// to a full screen window's Space from anywhere, and to its visible desktop only from a fullscreen Space: the
    /// stash bounces back by itself, and other desktops are the user's.
    static func target(current: UInt64, visible: UInt64, page: UInt64, currentIsFullscreen: Bool) -> UInt64? {
        guard page != current else { return nil }
        return page != visible || currentIsFullscreen ? page : nil
    }
}

extension SavedState {
    /// The full screen window whose page the display shows, if its shown page is one.
    func shownFullscreenWindow(_ display: DisplayState) -> WindowID? {
        guard let workspace = display.workspaces.first(where: { $0.id == display.currentWorkspace }),
              let page = workspace.pages.first(where: { $0.id == workspace.currentPage }) else { return nil }
        return page.windows.first { windows[$0]?.info.fullscreen == true }
    }
}

struct SpaceSwitch: Equatable {
    var identifier: String
    var target: UInt64
    var current: UInt64
    /// Toward a fullscreen Space, which is shown before the page being left is stashed.
    var fullscreen: Bool
}

extension AppDelegate {
    /// The native Space of the page a managed display shows in `state`: its full screen window's Space once the
    /// window stands on one, else the visible desktop.
    func pageSpace(_ id: DisplayID, state: SavedState) -> UInt64? {
        guard let display = displays.displays.first(where: { $0.info.id == id }), display.info.unmanagedReason == nil,
              let model = state.displays.first(where: { $0.info.id == id }) else { return nil }
        if let window = state.shownFullscreenWindow(model),
           let space = displays.fullscreenSpace(of: id, among: DisplayCatalog.windowSpaces(window)) { return space }
        return display.info.visibleSpace
    }

    /// Whether the display is on the native Space of the page it shows in `state`. Transitions capture and slide a
    /// display only then; true when minitile cannot tell.
    func showsItsPage(_ id: DisplayID, state: SavedState) -> Bool {
        guard let display = displays.displays.first(where: { $0.info.id == id }), let space = pageSpace(id, state: state) else { return true }
        return csl_current_space(display.identifier as CFString) == space
    }

    func spaceSwitch(_ id: DisplayID) -> SpaceSwitch? {
        guard let page = pageSpace(id, state: engine.savedState()),
              let display = displays.displays.first(where: { $0.info.id == id }), let visible = display.info.visibleSpace else { return nil }
        let current = csl_current_space(display.identifier as CFString)
        guard let target = SpaceSync.target(current: current, visible: visible, page: page,
                                            currentIsFullscreen: displays.onFullscreenSpace([current])) else { return nil }
        return SpaceSwitch(identifier: display.identifier, target: target, current: current, fullscreen: target != visible)
    }

    /// Applies a reconcile and puts each display a command acted on onto its page's native Space. Show first: a
    /// fullscreen Space is shown before the page being left is stashed, the desktop once its page has arrived.
    func reconcile(_ output: Output, held: Bool = false) {
        let switches = spaceSync.sorted().compactMap(spaceSwitch)
        spaceSync = []
        for item in switches where item.fullscreen { perform(item) }
        reconciler?.apply(output, held: held)
        for item in switches where !item.fullscreen { perform(item) }
    }

    private func perform(_ item: SpaceSwitch) {
        guard csl_switch_space(item.identifier as CFString, item.target, item.current) else {
            logger.error("Could not switch display \(item.identifier, privacy: .public) to Space \(item.target)")
            return
        }
        spaceSwitchedUntil = ProcessInfo.processInfo.systemUptime + SpaceSync.activationInterval
    }
}
