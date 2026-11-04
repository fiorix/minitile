# minitile design

minitile is a tiling window manager for macOS. It runs with SIP enabled and aims for a small core that blends with macOS: a handful of keys that reuse the native desktop shortcuts, mouse gestures where macOS users already use the mouse, and every function scriptable from the `mntl` command line tool. HyprMac (github.com/zacharytgray/HyprMac) is a source of macOS behaviour to respect, not a feature list to copy.

Status: the core, IPC, `mntl` and the macOS shell are implemented and verified live on one display. Multiple displays and the items under "Open" are not yet verified. Page transitions, Cmd+\` window cycling and page miniatures in the position indicator are implemented and unit tested but not yet tried on screen; the transition mechanism was validated in a spike. Trackpad swipes are implemented and unit tested; the swipe mechanism was validated in a spike. The Cmd+Tab window switcher is implemented and unit tested but not yet tried on screen. Keyboard resizing and the mirrored and stacked three-window layouts are implemented and unit tested but not yet tried on screen. The drop picker is designed but not yet implemented.

## Model

Each display has its own grid:

```
Display
  workspaces[]        stacked vertically
    pages[]           laid out horizontally
      windows[<=4]    tiled
```

- One page per display is visible at a time.
- A page tiles at most 4 windows. At default ratios every tile is at least a quarter of the usable screen, which avoids most minimum-size conflicts. Floating windows do not count toward the limit.
- Empty pages disappear. Empty workspaces disappear, except a freshly opened one while it is being viewed.

The currently viewed empty page/workspace is retained until the view leaves it, including when its last window closes. This leaves a destination for the next window. Other empty pages/workspaces are removed. Focus outside the managed window set clears the default window command target while retaining the last display context.

### Position indicator

When a display's shown page or workspace changes, that display shows a read-only grid in the upper-right corner of its usable area for 1.5 s, then hides it. Another change within that time shows the new position and restarts the 1.5 s.

The first managed view after startup or display attachment also shows the indicator. Changes to focus, window counts or page indices alone do not restart it: the comparison uses workspace and page identities. Unmanaged-display warnings remain in the menu.

- The header names the display and the current workspace and page.
- Workspaces are rows labeled W1, W2, and so on; pages are columns labeled P1, P2, and so on.
- Each cell is a miniature of its page, about 64x40 pt in the proportions of the display's usable area, so portrait displays get tall cells. Its tiles are the core's layout of the page, shown or not (window count, variant and ratios, with gaps and padding scaled down), each holding its app's icon at 10-14 pt, smaller only when the tile is. Minimized and app-hidden windows have no tile, since their page re-tiles without them; their reserved slots show as dimmed app icons along the cell's bottom-left corner. Floating windows show as a count badge on the cell's top-right corner. An empty page is an empty outline.
- The shown page's cell is highlighted, including an empty page, and so is the focused window's tile when it is on that page.
- At most four rows and five columns are drawn, centered on the current position where possible. A cropped grid keeps its full indices and says it is cropped.
- The grid passes mouse input through, never takes focus, appears on whichever native desktop is current, and follows light and dark appearance.

It is an orientation aid, not an interactive overview; the window switcher below is the keyboard-driven view of the same grid.

Cells keep the area of 64x40 pt at any aspect ratio, clamped to 3:1 either way. Tile frames come from the same layout function as the scene, with the config's gaps and padding, and are scaled into the cell on half-point edges; each tile is inset by half a point so neighbours stay apart where scaled gaps fall below a point. The floating count includes minimized floating windows. App icons come from the running application and are cached per pid until no managed window has that pid. The panel is sized from the number of drawn cells, with a minimum width for the header.

### Window switcher

Cmd+Tab opens a window switcher in place of the native app switcher. It shows the active display's grid as page miniatures in the middle of its usable area and moves a selection over the windows.

- Pressing Cmd+Tab selects the window focused before the current one, or the most recently focused one when no window of the display has focus, and Cmd+Shift+Tab the least recently focused one. While Cmd is held, Tab and Shift+Tab step forward and back through the windows in most-recent focus order, wrapping around.
- The arrow keys move the selection to the nearest window in that direction, first on its page, then on neighbouring pages and workspaces. Empty pages are skipped. Arrows do not wrap.
- Releasing Cmd, or pressing Return, focuses the selected window and shows its page, with the usual slide. Esc closes the switcher without changing anything.
- A quick Cmd+Tab, released within about 150 ms, switches straight to the previous window without showing the switcher, as the native switcher does.
- The switcher covers the managed windows of the active display, the one a command without an address acts on: tiled and floating windows, without minimized and app-hidden ones. Running apps with no managed window are not in it; the Dock and Spotlight reach them. With no window to offer, Cmd+Tab does nothing.
- Cells are about twice the size of the position indicator's (128x80 pt in the usable area's proportions), with app icons in the tiles. Floating windows show as icons in a tray along the cell's top edge, so they can be selected. The selected window is highlighted, as is the page holding the current focus. The header names the selected window's app and title and its workspace and page. At most four rows and five columns are drawn, centered on the selection; a cropped grid keeps its full indices and says it is cropped.
- The switcher never takes focus. While it is open, the key event tap swallows Tab, the arrows, Return and Esc and routes them to it, whatever modifiers are held; Tab, Shift+Tab and the arrows repeat while held. Every other key and binding is swallowed while it is open, so Cmd+Q or Cmd+W never reaches the app behind it; switcher bindings still step it.
- It is opened by the `switcher next` and `switcher prev` commands, bound to Cmd+Tab and Cmd+Shift+Tab. Through a key binding it stays open while the binding's modifiers other than Shift are held. Opened without a held modifier (from `mntl`), it stays open until Return or Esc, or `switcher commit` or `switcher cancel`. While it is open, `switcher next` and `switcher prev` step it, from a binding or `mntl`.
- When minitile is not started or is suspended, or the active display has no window to offer, Cmd+Tab passes to macOS and shows the native app switcher. Binding `"cmd+tab"` to `""` restores the native app switcher. Suspension and quitting close an open switcher without changing anything.

The order is fixed when the switcher opens: the focused window first, then the others by focus recency, with grid order (workspaces, pages, tiles by slot, then floating windows) breaking ties such as windows never focused. While it is open, the switcher follows model changes: a window that closes, is minimized or hidden, or leaves the display drops out of the order, a new window joins at its end, and when the selected window drops out, the next one in the order takes its place. It closes without changing anything when no window is left or its display goes away or becomes unmanaged. An arrow picks the nearest window center in the direction's half-plane (more than 1 pt away along that axis) across the switcher's whole grid of cells, drawn or cropped, with grid order breaking ties; a floating window's position is its tray icon. Since tiles on the same page are nearest, an arrow can stay on the page where a neighbouring page or workspace lies in that direction too, as Up from a page's large tile reaches the tile beside it.

Cells use the indicator's miniatures at 128x80 pt of area, clamped to 3:1 either way, with 12 pt between cells. App icons in tiles are 16-32 pt, never larger than the tile. Reserved slots of minimized and app-hidden tiled windows show as dimmed icons as in the indicator and cannot be selected; the tray leaves out minimized and app-hidden floating windows. Tray icons are 16 pt, centered on the cell's top edge and right-aligned, and shrink when the row would not fit the cell. The selected tile or tray icon is filled and outlined in the accent colour, the cell of the shown page, which holds the focus, is outlined, and the selection's row and column labels are emphasized.

The panel is borderless, non-activating and click-through, cannot become key or main, joins all Spaces including fullscreen ones, follows light and dark appearance, and is centered on the display's usable area. Its level is the pop-up menu level, above the position indicator (`.floating`), the page-transition overlays (one below it) and other apps' floating windows. Committing orders the panel out, then runs `window focus ID` through the normal command path, so the panel never appears in a transition capture and the page slides in.

Keys: a bound `switcher next|prev` opens a session in the keyboard tap's router that remembers the binding's modifiers other than Shift, and a flags-changed event without one of them commits. Each swallowed press has its key-up swallowed too. Opened by a binding, the panel shows after 150 ms, so a release before then commits without it appearing. Before the panel shows, and every second while a binding's switcher is open, the shell rereads the modifier state (`CGEventSource.flagsState`), so a release the tap missed, as while macOS had it disabled, still commits. `mntl switcher next|prev` opens a session without modifiers. Router decisions reach the main thread asynchronously and carry their session, so keys for a switcher that has since closed are dropped. The router keeps the availability flag (started and not suspended) under its lock, and the main thread updates it at start, on every suspension change and on quit.

`switcher next|prev` fail when the display has no window to offer, and `switcher commit|cancel` when the switcher is not open; `switcher commit` replies with the reply of `window focus ID`. `mntl debug health` reports `switcher_open` and `switcher_selected` (see "Command line: mntl").

Untested in minitile: the panel on screen, key routing with physical keys, the quick Cmd+Tab, Shift+Tab, and detecting the Cmd release.

### Placement

- A new window goes to the workspace being viewed. It takes the first free slot, scanning from the current page to the right; if none is free, it goes onto a new page at the end of the workspace.
- If a new window from the frontmost app lands on a page that is not shown, that page is shown, since macOS focuses such windows. Windows from background apps are placed without changing the view.
- When a window closes, the remaining windows on its page re-tile, and the freed slot is reused by the next new window. Windows never flow back from later pages.
- When focus moves to a window on a hidden page by any means (the Dock, a notification, `mntl window focus`), that page is shown. For 1.2 s after a command changes the shown page, such reports are ignored: the app that was frontmost can still report the window minitile just hid as focused, and following it would undo the navigation. Activation still shows an app's page during that time.
- When an app with no window on a shown page is activated (Cmd-Tab, the Dock), the page holding its most recently focused window is shown. macOS does the focusing. Minimized windows do not count as being on a shown page; windows of a hidden app do, since activation unhides them. See "Rules minitile must follow" for the timing.

### Navigation and focus

- Showing a page focuses the window that last had focus on it, or its first window. An empty page focuses nothing.
- When the focused window closes or is minimized, or its app is hidden, minitile does not focus another window. macOS picks the next one, and minitile follows it.
- Ctrl+Up/Down (`workspace next|prev`) shows the page at the same position in the workspace above or below. If that workspace ends exactly one page short of the position, an empty page opens there, as Ctrl+Right from its last page would; if it is shorter still, its last page is shown. `workspace show` by index shows the page last viewed in that workspace.
- Ctrl+Left on the first page and Ctrl+Up on the first workspace do nothing.
- Ctrl+Right on the last page opens an empty page, and Ctrl+Down on the last workspace opens an empty workspace. Neither opens a second empty one next to an empty one.
- A window opened while an empty page or workspace is viewed lands in it. An empty page or workspace is removed when the view leaves it.
- Pages are otherwise created by spill and by nudging a window out of a shared page (see Keys).

### Page transitions

The mechanism and its measurements are under "Transition mechanism".

- When a key binding, menu item or `mntl` command changes a display's shown page or workspace, the old page slides out and the new one slides in, like the native desktop switch at about half its speed. Pages slide horizontally and workspaces vertically. Nudge and carry slide too when focus follows the window to another page.
- Where navigation does nothing, the page bounces instead: Ctrl+Left on the first page, Ctrl+Right on an empty last page, Ctrl+Up on the first workspace and Ctrl+Down on an empty last workspace. The page shifts 5% of its width or height the way the slide would start, then springs back, over 0.3 s whatever the slide duration.
- A slide takes 0.5 s by default, set by `transition_ms`; 0 turns slides and bounces off. Reduce Motion also turns them off.
- Other view changes stay instant: activation (Cmd-Tab, the Dock, clicks), new windows, unminimizing, startup and display changes. Activation must not wait, since it races macOS's own desktop switch.
- A command never waits for a running slide. A navigation during a slide cuts it short and starts the next slide from the current screen.
- Each display slides on its own. The position indicator stays above the slide.
- Transitions need Screen Recording permission. Without it they are off, the menu says why, and everything else works. `mntl debug health` says whether transitions run and, if not, why.

### Minimized and hidden windows

- A minimized window keeps its slot, and its page re-tiles without it. When it is unminimized, it returns to its slot and its page is shown.
- Windows of a hidden app (Cmd+H) keep their slots, and their pages re-tile without them until the app is unhidden.
- `mntl window hide` takes a window off its page, freeing the slot, and keeps it on the stash. `mntl window show` places it like a new window on the current workspace and focuses it.

### Layout

Each page holds an ordered list of windows, its slots. The layout is a fixed function of the window count and the page's variant. Ctrl+Shift+Space (`mntl page variant`) cycles a page through its count's layouts in this order:

| Windows | Layouts, in cycling order |
|---|---|
| 1 | full |
| 2 | `standard`: two halves across the long axis; `alternate`: two halves across the short axis |
| 3 | `standard`: one large plus two stacked, large first; `mirrored`: one large plus two stacked, large last; `alternate`: three slices across the long axis; `stacked`: three slices across the short axis |
| 4 | 2x2 |

- On a landscape display the long axis is the width: two windows sit side by side, the large window of three is on the left (on the right when mirrored), `alternate` three are columns and `stacked` three are rows. On a portrait display the axes swap.
- Slot 0 is the large tile. Slices are in order along their axis. A closed window's slot disappears and later windows move up.
- With one or four windows, cycling does nothing. A page keeps its variant when its window count changes; with a count the variant does not define (`mirrored` or `stacked` with two windows), the page uses its count's `standard` layout, and cycling continues from there.

Geometry:

- The layout area is the display's visible frame (menu bar and Dock excluded) inset by `padding`. Tiles are separated by `gaps`. Frames are rounded to whole points.
- Each page has two ratios, r1 and r2, each a position across the layout area:
  - 2 windows: r1 is the cut.
  - 3, large plus two: r1 cuts the large tile from the pair along the long axis; r2 cuts the pair along the short axis.
  - 3, large plus two, mirrored: r1 cuts the pair from the large tile along the long axis; r2 cuts the pair along the short axis.
  - 3, slices: r1 and r2 are the two cuts along the long axis.
  - 3, stacked slices: r1 and r2 are the two cuts along the short axis.
  - 4: r1 is the cut along the long axis, r2 the cut along the short axis.
- Defaults are 0.5, except both three-slice layouts at 1/3 and 2/3. Ratios are clamped to 0.2-0.8, and the cuts of three slices stay at least 0.2 apart.
- Ratios reset to the defaults when the page's window count or variant changes.

The count for cycling and ratio resets is the number of non-minimized, non-app-hidden tiled windows. The core describes each layout as a list of tiles by slot, each side of a tile lying on the layout area's border or on r1 or r2; frames, edge drags, share resizes and keyboard resizes all read their cuts from it. A square visible frame uses width as its long axis. Cuts are centered in gaps; frame edges are rounded individually and width/height are the differences of rounded edges. Insets and unusually large gaps never produce negative sizes. A single-cut edit preserves the other cut when enforcing three-slice spacing; setting both ratios clamps r1 first, then brings r2 above it, moving r1 back if necessary to fit within 0.8.

Drop picker (not yet implemented):

- While a tiled window is dragged as a move (the mouse button is down and the window has moved beyond the move tolerance without changing size), a layout picker appears at the bottom centre of its display's usable area, away from the tab strips and title bars at the tops of tiles. It shows each layout for the page's tiled window count as a miniature, in cycling order: two windows `standard` and `alternate`; three windows `standard`, `mirrored`, `alternate` and `stacked`; four windows the 2x2. With one tiled window there is nothing to pick and it does not appear. Edge drags (resizes) and floating windows never show it.
- Each miniature's slots are drop targets. While the cursor is over a slot, the slot is highlighted with the dragged window's app icon and a translucent preview on the page shows the frame the window would get. Releasing the mouse there sets the page's variant to that layout and moves the dragged window into that slot; the other windows keep their relative order in the remaining slots. Ratios reset as for any variant change.
- Releasing anywhere else keeps the behaviour below: a swap with the tiled window under the cursor, or a snap back.
- Browser tab drags keep working: the picker and the preview are click-through and never intercept the drag, and the preview shows only while the cursor is over a picker slot, so it never covers a tab strip. A window torn out of a browser by dragging a tab counts as dragged, so it can be dropped on a tile or a picker slot. If the dragged window disappears before the release, as when it is dropped into another window's tab strip, minitile does nothing for that drop.
- The picker reflects the page the dragged window is on, including after Ctrl+arrow during the drag. It is click-through and never takes focus; the shell hit-tests the cursor against it while polling the drag. It uses the same miniature drawing as the position indicator and the window switcher.
- The core command is `window place [ID] standard|alternate|mirrored|stacked SLOT`: it sets the variant of the window's page and moves the window to the 0-based slot. The variant must be defined for the page's tiled count and the slot must exist.

Keyboard:

- Ctrl+Option+arrows resize the focused window by moving its edges, the keyboard version of dragging an edge. If the window's edge on the arrow's side is a cut, that cut moves in the arrow's direction and the window grows. If that side lies on the layout area's border, the window's cut on the opposite side moves in the arrow's direction instead and the window shrinks. So a divider always moves the way the arrow points, whichever side of it has focus.
- Each press moves a cut by 0.05 of the layout area, clamped as above. Holding the keys repeats.
- A window with no cut in that axis (a lone window, or the large tile for Up and Down) does not change. The middle of three slices has cuts on both sides, so the arrows only grow it; its neighbours shrink it.
- A floating window grows or shrinks by 0.05 of the layout area per press: Right and Left change its width, Down and Up its height, keeping its top-left corner.

A press that changes no ratio, because the window has no cut in that axis or the cut is already at its clamp or at the three-slice spacing, emits no event, action or rewrite; otherwise only the frames whose targets changed are written. A floating window uses the layout area of the display holding its page. It grows until its right or bottom edge reaches the layout area's edge and shrinks to a fifth of the layout area in that dimension; a press that would cross a limit stops at it, and a press toward a limit the window is already past does nothing. The new frame goes through the explicit floating frame write and is the window's frame in the core until the shell observes another.

Mouse:

- Each inner edge of a tile lies on one cut. Dragging a tiled window's edge moves that cut: the new ratio is the edge's position across the layout area, clamped. A corner drag moves both cuts. Edges on the border of the layout area are not cuts, and dragging them snaps back.
- A drag that ends with the size unchanged (within a few points) is a move. If the cursor is over another tiled window on the same page, the two swap slots; otherwise the window snaps back.

The move tolerance is 3 points per dimension. Edge drags are converted from the tile edge to the gap center before computing a ratio. A drag can update the inner cut of a corner while its border edge snaps back. Three-slice middle-window resize by share holds its end cut (the right or bottom one) fixed and moves its start cut to obtain the requested share.

Untested in minitile: the mirrored and stacked layouts on screen, keyboard resizing with physical keys, and key repeat.

## Keys

minitile takes over the Ctrl+arrow shortcuts macOS uses for desktops and Mission Control, and the Cmd+\` shortcut for cycling windows, and gives them the same meaning on its grid. There is no Hypr key and no Caps Lock remap. Closing and quitting stay on Cmd+W and Cmd+Q.

Default bindings:

| Keys | Action | Replaces in macOS |
|---|---|---|
| Ctrl+Left/Right | Show the previous or next page. | Move left/right a space |
| Ctrl+Up/Down | Show the page above or below: same position in the workspace above or below, an empty page when that workspace ends one page short, or its last page when it is shorter still. | Mission Control, App Expose |
| Cmd+\` / Cmd+Shift+\` | Focus the next or previous window on the shown page: tiles in slot order, then floating windows, wrapping around. | Move focus to next window, which cycles the frontmost app's windows |
| Ctrl+Shift+Space | Cycle the shown page through its window count's layouts (see Layout). | Nothing by default; Ctrl+Space and Ctrl+Option+Space switch input sources |
| Ctrl+Option+arrows | Resize the focused window: the divider on that side moves the way the arrow points (see Layout). | Nothing by default; VoiceOver uses Ctrl+Option as its modifier |
| Cmd+Tab / Cmd+Shift+Tab | Open the window switcher and step through windows (see "Window switcher"). | App switcher |
| Ctrl+Shift+Left/Right | Nudge the focused window. If it shares its page, it moves onto a new page of its own on that side. If it is alone, it joins the neighbouring page; if that page is full, it joins the next page with room in the same direction, or a new page at that end of the workspace. Focus follows. | Select to line start or end in text fields, which Cmd+Shift+arrows also does |
| Ctrl+Shift+Up/Down | Carry the focused window to the workspace above or below, placed by the placement rules. Past the last workspace, it carries the window into a new one. Focus follows. | - |

Nudging B to the right three times:

```
[A B C D] [E]      start
[A C D] [B] [E]    B shared its page, so it gets its own
[A C D] [E B]      B was alone, so it joins the next page
[A C D] [E] [B]    B shared again, so it gets its own
```

Nudging E to the left, past a full page:

```
[A B C D] [E]      start
[E] [A B C D]      E was alone and no page to its left has room, so it gets a new first page
```

Nudging a window that is alone on the first or last page toward the edge does nothing, and a nudge that does nothing emits no event or focus action.

Sharing a page includes floating and reserved minimized/app-hidden windows. A nudge always moves the window in its direction: it never lands back on the page it left.

Mouse:

- Drag a tiled window's edge to resize, drag it onto another tile to swap, or drop it on a slot of the layout picker (see Layout). Edge drags have no live preview.
- Press Ctrl+arrow while dragging a window to do to it what Ctrl+Shift+arrow does. This is how macOS moves a window to another desktop. Frames of a window being dragged are not written until the mouse button is released.
- A move or resize that minitile did not cause, seen while the mouse button is down, is a user drag. minitile acts on release.

Trackpad (the mechanism is under "Trackpad swipe mechanism"):

- The swipe macOS uses to switch desktops and open Mission Control and App Expose (three or four fingers, as set in System Settings) navigates the grid instead. Fingers left show the next page, fingers right the previous page, fingers up the workspace below and fingers down the workspace above. These run the same commands as Ctrl+Right, Ctrl+Left, Ctrl+Down and Ctrl+Up, with the same slides and edge bounces.
- A swipe acts when it ends, if it travelled at least 30% of the way or was still moving fast (end velocity of at least 2). A shorter, slower swipe, or one macOS cancels, does nothing; it still never reaches macOS.
- It acts on the display under the pointer as the swipe begins, as the native swipe does, whichever display has focus.
- minitile leaves the whole swipe to macOS when, as it begins, the display under the pointer is unmanaged or not showing its visible desktop (for example a fullscreen app's Space), when minitile is not started or is suspended, or when `trackpad_swipes` is false. It also stays with macOS while minitile's swipe tap is unavailable or disabled.
- Mission Control and App Expose stay reachable through their keys and the Dock.

Everything else (floating, spatial focus, exact ratios) is a command: reachable from `mntl`, from the menu bar where it makes sense, and bindable to keys in the config.

Notes:

- Validated with physical keys: the session-level event tap receives Ctrl+Left/Right/Up/Down before the Dock, and swallowing them keeps desktops from switching and Mission Control and App Expose from opening. Ctrl+Up/Down are system shortcuts 32 and 33, and Ctrl+Left/Right are 79 and 81.
- Arrow keys carry the fn and keypad flags, so binding matches ignore them.
- A held binding fires once. Key repeats of a bound chord are swallowed without running the command again. The open window switcher and keyboard resizing are the exceptions. A press that runs a directional `window resize` runs it again on each key repeat while the key stays held and the chord still names a directional resize; a repeat after the modifiers change to another chord is swallowed, and a repeat whose press the tap did not see does not resize.
- Validated with physical keys (`dev/spikes/gesture`, `cmdtab` mode): swallowing Tab at the session-level event tap while Cmd is held keeps the native app switcher (system shortcuts 1 and 2) from appearing, and Cmd presses arrive as flags-changed events. A quick Cmd+Tab, Shift+Tab and the Cmd release were not part of that test.
- The \` key is whichever key macOS assigns to Move focus to next window (system shortcut 27), so Cmd+\` follows non-US layouts. Only the shortcut's keycode is used; binding modifiers come from the config. On this Mac it is keycode 50 with Cmd, and keycode 50 is the fallback when the shortcut cannot be read. It is reread whenever the key map is rebuilt. A key that already has another name, such as a letter, keeps it, and \` then names no key. In apps minitile does not manage, chords on the \` key keep their native meaning: the tap passes them through while the frontmost app is not allowed by the config, a flag the shell updates on every app activation and config reload. A press swallowed in a managed app stays swallowed until its key-up. Not yet validated with physical keys: swallowing it must stop the app's own window cycling, including in apps that handle Cmd+\` themselves.
- Mission Control stays reachable through its own key and the Dock, and through the trackpad when `trackpad_swipes` is false. It shows the stash desktop with every hidden page's windows, which makes it an escape hatch rather than a view of the grid.
- The event tap also swallows Desktop N shortcuts and native Move left/right a Space shortcuts that would lead into any managed display's stash. Directional blockers follow native adjacency, including fullscreen Spaces, and remain active when the corresponding minitile binding is unbound.

## Command line: mntl

Every minitile function is a command. Key bindings, the menu bar, mouse gestures and `mntl` all run commands through the same path. Anything the user can do, `mntl` can do, and anything minitile knows, `mntl` can read.

- The menu bar app listens on a Unix socket at `$TMPDIR/minitile.sock`, the per-user temp directory from `confstr(_CS_DARWIN_USER_TEMP_DIR)`. The socket file is mode 0600, and connections from other users are refused after a `getpeereid` check. `MINITILE_SOCKET` overrides the path for both sides.
- At start, if the socket path exists and something answers on it, minitile reports that another instance is running and quits. A stale socket file is removed.
- The protocol is newline-delimited JSON, one object per line. A request is `{"argv": [...]}`. A response is `{"ok": bool, "text": string, "data": any}`. Requests over 64 KiB or malformed requests get an error response and the connection is closed.
- `mntl watch` gets one `ok` response, then one JSON event per line until the client disconnects.
- `mntl` is a thin client. It sends its arguments, prints `text` (or `data` with `--json`) and exits 0 on success, 1 on a command error and 2 when minitile cannot be reached. New commands need no change to `mntl`.
- Config bindings and menu items use the same command strings, for example `"ctrl+left" = "page prev"`.
- `mntl switcher next|prev|commit|cancel` commands are answered by the app shell, since the switcher is shell UI; committing runs `window focus ID` through the core.
- `mntl debug <verb>` commands are answered by the app shell and expose internals: raw desktops per display, the last applied scene, timings. Debug verbs can be added freely. Every other command is answered by the core.

The shell provides `debug spaces`, `debug windows`, `debug scene`, `debug timings` and `debug health`. Spaces include the native display identifier, every native Space and its type, current Space, and core display metadata. The desktop list comes from the last catalog refresh; current Space is read for each request. Windows include allowed apps' raw layer-0 windows, AX observation status, current spaces, frames and tileability. Scene frame keys are decimal window-ID strings. Health includes process ID, startup/suspension state and reasons, secure input, tap availability, paths and warnings. The menu can open config, retry startup after a config error, or quit while normal command handling is still unavailable.

`grid_indicator_displays` counts physical displays whose indicator state is tracked, including hidden indicators; `grid_indicator_visible_displays` counts currently visible panels, and `grid_indicator_duration_ms` is 1500. `switcher_open` says whether the window switcher is open, and `switcher_selected` is its selected window ID, or null. `transitions_enabled` says whether page transitions run, and `transitions_disabled_reason` says why not (`transition_ms` is 0, Reduce Motion is on, Screen Recording is not granted, or screen capture content is not loaded) or is null. `trackpad_swipes` is the configured setting; `swipe_tap_running` says whether the swipe tap exists and is enabled; `swipe_tap_unavailable` says it could not be created or its thread exited unexpectedly. `last_swipe` is the latest swipe that began, or null: its `location` in global points, the `display` minitile took it for (null when it went to macOS) and the `command` it ran (null when none). Timing diagnostics include full-scan counts/duration, recheck requests/passes, and the latest 128 activation-triggered first move submissions. Activation latency runs from delivery of the workspace or AX notification callback through return of the bridged move submission; it does not measure time before notification delivery or completion in WindowServer.

Commands are noun then verb. Windows are addressed by window ID and default to the focused window. Pages and workspaces are addressed by index or `next`/`prev`, and default to the display with the focused window.

| Command | Effect |
|---|---|
| `mntl help` | The command grammar. |
| `mntl state` | Dump the whole model: displays, workspaces, pages, windows and focus. |
| `mntl watch` | Stream events as JSON lines: focus, page shown, window added, removed or moved, display change, config reload. |
| `mntl window list` | List windows with ID, app, title, display, workspace, page, slot and floating state. |
| `mntl window info [id]` | One window in full: where it is (display, workspace, page, slot), shown or hidden, floating, focused, app name, bundle ID and pid, title, frame. |
| `mntl window show [id]` | Show the page holding the window and focus it. A hidden window joins the current workspace. |
| `mntl window hide [id]` | Take the window off its page and keep it on the stash until shown. |
| `mntl window move [id] <target>` | Move the window to a direction, page, workspace or display. |
| `mntl window nudge [id] <dir>` | The Ctrl+Shift+Left/Right action. |
| `mntl window swap [id] <id>` | Swap two tiled windows. |
| `mntl window resize [id] <size>` | Tiled: set the page cuts so the window gets that share. Floating: set its size. |
| `mntl window float [id] [on, off]` | Toggle or set floating. |
| `mntl window focus [id, dir]` | Focus by ID, spatially on the page, or the next or previous window on the page. |
| `mntl window close [id]` | Press the window's close button. |
| `mntl page <verb>` | `list`, `info`, `show`, `next`, `prev`, `variant`, `ratio`. |
| `mntl workspace <verb>` | `list`, `info`, `show`, `next`, `prev`, `new`. |
| `mntl display <verb>` | `list`, `info`: UUID, frame, desktops, stash state, home and merged workspaces. |
| `mntl config reload`, `mntl quit` | Lifecycle. |

Every noun has `list` and `info`. `info` takes an address and defaults to the current one: the focused window, or the page, workspace or display holding it.

The exact grammar is published by `mntl help`:

```text
help
state
watch
window list
window info|show|hide|close [ID]
window focus [ID|left|right|up|down|next|prev]
window float [ID] [on|off]
window nudge [ID] left|right
window move [ID] left|right|up|down
window move [ID] page|workspace INDEX|next|prev
window move [ID] display UUID|next|prev
window swap [ID] OTHER_ID
window resize [ID] SHARE|WIDTHxHEIGHT|left|right|up|down
window place [ID] standard|alternate|mirrored|stacked SLOT
page list
page info|show|variant [INDEX|next|prev]
page next|prev [display UUID]
page ratio R1 [R2]
workspace list
workspace info|show [INDEX|next|prev]
workspace next|prev [display UUID]
workspace new
display list
display info [UUID|next|prev]
config list|info|reload|open
switcher next|prev|commit|cancel
quit
```

Page and workspace addresses are 1-based; tiled slots are 0-based. Floating and explicitly hidden windows have a null slot. Window IDs are decimal. With no focused window, commands use the most recently selected display, then the primary managed display. `page list` lists the current workspace; `workspace list` lists the current display. An explicit display UUID can inspect an unmanaged display. `info`, `show` and `variant` addresses resolve within the current context; `next`/`prev` in these addresses clamp at the ends. Only navigation commands and window moves create pages or workspaces. `workspace new` appends an empty workspace unless the current one is already empty. `page next|prev` and `workspace next|prev` navigate the display named by a trailing `display UUID` instead of the current context, with the same edge behaviour; the display must be known and managed, otherwise the command fails. Trackpad swipes use this to act on the display under the pointer.

Window moves and swaps follow the addressed source window. A move to its existing page does nothing. Left/right moves are nudges; up/down moves carry between workspaces. Explicit moves to a full page use placement spill. Spatial focus chooses the nearest window center in the requested half-plane on the same page, with grid order breaking ties; it does not wrap. Minimized and app-hidden windows are excluded from spatial focus. Next and previous focus walk the focused window's page in grid order, tiles by slot and then floating windows, and wrap; they skip minimized and app-hidden windows. With no managed window focused, both focus the first window of the shown page in the current display context. Like `window focus ID`, they emit a focus action. When no other window on the page can take focus, including on an empty page, they do nothing.

Directional resize moves the window's cuts by 0.05 as described under Layout, or grows or shrinks a floating window by 0.05 of the layout area. For tiled resize, a single share applies along the layout's split axis, the axis r1 cuts: the long axis, except for two windows `alternate` and three `stacked`. `WIDTHxHEIGHT` supplies physical-axis fractional shares; an axis the tile spans whole ignores its share. Cuts are clamped by the layout rules. Floating resize requires `WIDTHxHEIGHT` in positive points and emits an explicit frame-write action. `page ratio R1` leaves r2 unchanged. Config reload is completed by the shell before its socket reply; failures keep the previous config. `config open` opens the config file in the user's editor.

### JSON data contract

Every response has `ok`, `text` and `data`. Errors and successful mutations use null data; inspection commands use the shapes below. Missing addresses, bundle IDs, desktop IDs and focus values are null rather than omitted. Rectangles use `{x, y, width, height}` in global points. `info` text contains one field per line; list text uses aligned columns. Text is for people; scripts should use `--json`.

| Command | Data |
|---|---|
| `help` | Grammar string. |
| `window list`, `window info` | Array of window objects, or one window object. Fields: `id`, `pid`, `bundle_id`, `app`, `title`, `frame`, `display`, `workspace`, `page`, `slot`, `floating`, `hidden`, `focused`, `shown`, `minimized`, `app_hidden`, `tileable`. `frame` is the latest observed or explicitly resized frame. `hidden` means explicitly hidden by mntl; `shown` also excludes minimized/app-hidden windows and pages not being viewed. |
| `page list`, `page info` | Array of page objects, or one page object. Fields: `id` (persistent identity), `index`, `display`, `workspace`, `shown`, `variant` (`standard`, `alternate`, `mirrored` or `stacked`: the page's own variant, kept across count changes even where its count lays it out as `standard`), `r1`, `r2`, `windows` (all assigned IDs in order), `tiled` (including reserved minimized/app-hidden slots), `floating`, `last_focus`. |
| `workspace list`, `workspace info` | Array of workspace objects, or one workspace object. Fields: `id` (persistent identity), `index`, `display` (current host), `home`, `shown`, `page` (last-viewed page index), `pages` (page objects). |
| `display list`, `display info` | Array of display objects, or one display object. Fields: `id` (UUID), `frame`, `visible_frame`, `primary`, `unmanaged_reason`, `visible_space`, `stash_space`, `workspace` (current index), `workspaces` (workspace objects), `home_workspaces`, `merged_workspaces` (workspace index arrays). |
| `config list`, `config info` | Object with `gaps`, `padding`, `float_apps`, `only_apps`, `transition_ms`, `trackpad_swipes`, `bindings`. Binding keys are canonical chords and values are command strings. |
| `state` | Object with `version: 1`, `focus`, `active_display`, `displays` (display objects), `windows` (window objects ordered by ID). This inspection shape is separate from the saved-state file. |

Watch events have `{type, data}`. Types `focus`, `window_added`, `window_removed` and `window_moved` carry a window ID; `focus` can carry null. `page_shown` carries `{display, workspace, page}` with indices after empty-page cleanup. `display_changed` carries the supplied array of `DisplayInfo` objects using their Swift Codable field names. `config_reloaded` carries null. A watcher is disconnected if its pending output exceeds 4 MiB; ordinary command replies can be larger. The CLI prints the initial watch reply using its usual text/data choice, followed by JSON event lines.

Each connection carries one request. Ordinary replies close the connection after their bytes are written; accepted watch connections remain open. The 64 KiB request limit excludes the terminating newline. The client uses 5-second send/reply timeouts and disables the receive timeout after a successful watch reply. Socket startup preserves regular files and symlinks at the requested path, removes only stale owned sockets, and stop removes only the inode this server bound. `mntl --help` is local; no command arguments request server help and print local usage if transport fails. Invalid local options or an oversized request exit 1; transport or response-decoding failures exit 2.

## Displays

- A grid's home display is identified by its display UUID (`CGDisplayCreateUUIDFromDisplayID`), the key native Spaces use. `CGDirectDisplayID` can change across sleep and wake.
- Each display's desktops come from `SLSCopyManagedDisplaySpaces`. The visible desktop is its first user desktop and the stash is its last. Fullscreen Spaces are ignored.
- minitile requires "Displays have separate Spaces". Without it there is no desktop pair per display, and minitile refuses to manage and says why.
- Display changes are debounced: about 2 s, or 5 s after wake. False display-change notifications (calls, colour profile changes) are filtered by comparing a fingerprint of the display set.
- While active, the shell also probes native desktop topology every three seconds. Changes to display identifiers or desktop IDs, types and order schedule the same debounced refresh, so creating a second desktop does not require switching to it. The probe ignores the current Space and does not update the catalog before the debounce completes; failed or empty reads retain the last catalog.
- Native desktop switches bounce from the stash, refresh window membership and shortcut blockers, and schedule presence checks without suspending the shell. When the final sleep, session, lock or display interruption ends, the shell refreshes topology, rereads focus and reapplies the current scene.
- When a display goes away, its workspaces are appended below those of the primary display, the one with the menu bar after the change. Each workspace keeps its home display UUID.
- When the home display returns, every workspace tagged with it moves back, including windows opened into it in the meantime. If one of those workspaces is being viewed, the primary display switches to the workspace above it.
- Workspaces created while merged belong to the display they were created on.
- macOS moves a vanished display's windows on its own. minitile ignores where they land and places them from its own state.

If the focused display disappears, focus moves to the primary display's currently shown page after merging. When several returning workspaces precede the viewed one, the host selects the nearest preceding workspace that remains; if none remains above, it selects its first remaining workspace or creates an empty one. If no display can be managed, grids are retained with no scene placement until a managed display returns. A physically present unmanaged display retains its grid but receives no scene and adopts no new windows. Explicitly hidden windows retain their last workspace's home UUID so they use the merged host's stash and can return home later.

## Floating windows

- minitile tiles standard windows: role `AXWindow`, subrole `AXStandardWindow`, not modal, with a settable size.
- Everything else floats, along with windows set floating through `mntl window float` or the menu bar, and apps on the always-float list in the config.
- A floating window belongs to the page that was visible when it appeared, and is hidden and shown with that page. Sheets already travel with their parent window.
- minitile does not try to keep floating windows above tiled ones. Without SIP it cannot set another app's window level, and HyprMac's attempts turned into a running fight with the window server.

An explicit floating toggle overrides `float_apps` for tileable windows; windows that cannot be tiled cannot be forced into tiling. Floating windows attach directly to the current page without consuming a tiled slot. Turning floating off on a full page spills right, following the window if it had focus. Config reload applies app rules to existing windows; the shell must rediscover windows when `only_apps` expands because ignored windows are absent from core state. Unminimizing a tracked window shows its page and emits a focus action; unhiding an app restores its tiles without changing the viewed page.

## Hiding pages: stash desktop

minitile does not park windows in a screen corner, as HyprMac and AeroSpace do. Each display uses two native desktops (Mission Control Spaces):

- the visible desktop, where the user works;
- the stash desktop, which holds the windows of every page not being shown, and windows hidden with `mntl window hide`.

Showing a page moves its windows from the stash to the visible desktop and lays them out. Hiding a page moves its windows to the stash. Window frames survive the move, nothing is left visible on screen, and after a crash the windows are still reachable through Mission Control.

The stash is the last desktop on each display:

- minitile expects exactly two desktops per display.
- A display with fewer than two desktops is left unmanaged, and the menu bar says why.
- Windows on any extra desktops are left alone.

### Primitives

Validated with a throwaway probe on macOS 27.0.1 (26A434), Apple Silicon, SIP enabled, one display:

- Move another app's window to a Space: create `SLSBridgedMoveWindowsToManagedSpaceOperation` with `initWithWindows:spaceID:` and run it through `SLSPerformAsynchronousBridgedWindowManagementOperation`. That function is not exported, so it is found by walking SkyLight's in-memory `LC_SYMTAB`, as yabai does. It takes 3-6 ms, does not switch desktops, does not move the cursor and keeps the frame. Its return value is meaningless.
- Instant desktop switch: send the bridged show, hide and set-current operations together (12-27 ms). Set-current alone leaves the old desktop's windows on screen.
- The older calls are dead for other apps' windows: `SLSMoveWindowsToManagedSpace` is a silent no-op, and the compat-ID trick returns 1006.
- An app's `kAXWindows` omits windows on inactive desktops. They reappear when their desktop is shown.
- If a macOS update removes the SkyLight function, minitile refuses to run and says why. The alternatives are a synthetic title-bar drag, at about 650 ms per window, or corner parking, and both are worse than not running.

### Stash behaviour

Validated on the same machine with TextEdit and Chrome windows:

- Stashing or returning several windows takes one call and completes in under 10 ms. Returning a Chrome window, including an AX frame write, took 18 ms. There is no desktop switch and no cursor movement, and frames are kept. Sheets and child windows travel with their window.
- AX handles obtained before stashing keep working on stashed windows. Reads, frame writes and `AXPress` on the close button all succeed, and a frame written while stashed still holds after the return.
- Notifications fire for stashed windows: moved, title changed, and destroyed (about 107 ms after an AX close). The app-level window-created notification fires as usual, and new windows open on the visible desktop.
- A returned window goes back to its old stacking position. It is neither raised nor focused, so minitile focuses it explicitly. AX main/focused plus `activate` worked, and so did the SkyLight front-process call alone.
- A page flip of 4 windows out and 4 in, all from one app, took about 25 ms when the new page was shown before the old one was hidden, and about 56 ms the other way round. Show first.
- A minimized window can be stashed. If it is unminimized while stashed, it stays hidden on the stash, so minitile pulls it back on the deminiaturize notification.

Rules minitile must follow:

- Pre-empt activation. When an app is activated, check whether it has a window on the visible desktop. If it has none, show the page that holds its window, issuing the move call before any layout writes. This stopped macOS from switching to the stash in 24 of 24 runs. Cmd-Tab is the tightest race, with about 6-25 ms of margin.
- React to whichever activation signal comes first. `NSWorkspaceDidActivateApplicationNotification` came first in 22 of 25 runs, the AX `kAXApplicationActivatedNotification` in 1, and a front-process poll in 2. Listen to both notifications.
- If macOS switches to the stash anyway, bounce back only after the switch has finished, on `activeSpaceDidChange` or once the current space is the stash. The stash is visible for about 300 ms. A bounce issued while the Dock is still animating is overridden.
- Keep the Dock away from the stash. minitile owns Ctrl+arrows (see Keys) and swallows Desktop N shortcuts that lead into the stash. A slide into the stash shows it for the full 1 s.
- Run a real `NSApplication` event loop. Without one, `activeSpaceDidChange` is never delivered.
- Track windows in minitile's own state. `kAXWindows` does not list stashed windows.
- At start, windows already on a stash have no AX handle, because `kAXWindows` omits them. minitile moves them to the visible desktop in one call, takes their AX handles, and lets the first reconcile stash them again. They show for a moment at start. `kAXWindows` lists a window right after it moves to the visible desktop (measured with TextEdit).

The shell tries discovery immediately, then up to four more times at 250 ms intervals. It restores windows with unreadable AX handles to their original stash and reports them. Quitting during adoption restores the temporarily exposed windows. Startup discovery is ordered by window ID before the core applies its visible-before-stash adoption rules.

Known risks:

- After an instant switch, the Dock's idea of the current desktop occasionally drifts from the real one (1 of 27 bounces). A Dock-driven move toward the stash then does nothing, and one toward the visible desktop plays a phantom slide. There is no API to detect this. A Dock-driven desktop shortcut re-syncs it.
- Untested:
  - multiple displays (see Open);
  - Mission Control and App Expose through their dedicated keys or gestures, Dock and notification clicks;
  - Stage Manager and fullscreen Spaces;
  - Reduce Motion on;
  - "When switching to an application, switch to a Space with open windows" turned off;
  - Dock restarts and sleep/wake;
  - Electron apps;
  - startup adoption when a stashed window's AX handle stays unreadable, and quitting during adoption.

### Transition mechanism

Validated with `dev/spikes/slide` on macOS 27, one Retina display (scale 2, 120 Hz), moving the spike's own windows between its visible desktop and stash:

- A capture with `SCScreenshotManager` takes about 20-45 ms. The first capture in a process takes about 100 ms. Half resolution saves only about 2 ms. Fetching `SCShareableContent` takes about 90 ms.
- Order: capture the current page; show the image in an overlay over the usable area; start the slide at once with the incoming half dark; move the windows about one frame later; capture the new page about 20 ms after the moves are submitted and put it in the incoming half; remove the overlay when the slide ends.
- Results: motion starts 40-60 ms after the keypress, and a bounce 30-55 ms after. The new page's image arrives 60-80 ms into a 0.5 s slide, so the dark edge covers about the first 5% of the travel; the user did not notice it. In 7 of 7 slides the new page's capture matched the screen after the slide. The first capture after the move already shows the new windows.
- When the spike moved its own main window to the stash, macOS switched to the stash (3 of 7 slides). Making the spike's overlay the key and main window prevented it (0 of 7). minitile moves only other apps' windows, so its overlay never takes focus.

minitile's transitions:

- Which changes animate: only outputs of `.command` inputs (key bindings, the menu, `mntl`). For each display, the shell compares the shown workspace and page identities before and after the command. A changed page within a workspace slides horizontally, by the pages' order; a changed workspace slides vertically, by the workspaces' order. The order comes from the state that holds both identities, before the command first, since cleanup removes the page or workspace being left and navigation creates the one entered; failing both, the old index before is compared with the new index after. `page next|prev` and `workspace next|prev` that leave the display they navigate unchanged bounce on that display: the display named by their `display UUID` suffix, else the core's command display (the focused window's display, else the last active one, else the primary).
- Capture: `SCScreenshotManager` with a per-display content filter that excludes minitile's own application, so the overlays and the position indicator never appear in a capture; `sourceRect` is the usable area in display-local top-left coordinates, at full backing resolution, BGRA, without the cursor. Shareable content is fetched when transitions turn on, after display changes, and on a config reload or Reduce Motion change while it is not loaded, followed by a throwaway capture. Until it arrives, view changes are instant.
- Overlay: one per display, a borderless, non-activating, click-through panel over the usable area that cannot become key or main, joins all Spaces and is ordered front without activating minitile. Its level is one below `.floating`, the position indicator's level, so the indicator stays above it and both stay above normal windows. Slides use cubic Bezier (0.4, 0, 0.2, 1) over `transition_ms`; bounces have keyframes at 0, 35% and 100% of 0.3 s, easing out and then in and out. The overlay is removed when its animation ends.
- Held reconcile: a command that slides captures each sliding display first and holds its reconcile. Every output that arrives meanwhile, from any input, is merged into the held one: the latest scene, the union of rewrites, frame and close actions in order, and the last focus action, which is applied only if the model still focuses that window. Config reload, config open and quit run when their input is handled. When the captures arrive, each captured display's overlay starts sliding, and about one frame (16 ms) later the merged output is applied in the usual order, focus last. Slide directions are taken from the state before the first held command to the state at that moment, so a second navigation within the capture slides from the captured page to the final one. `mntl` replies once a held reconcile is applied, except `watch`, which replies at once.
- Fallbacks: if a capture of the page being left has not arrived 150 ms after the command, the held reconcile is applied, and displays without an image change without a slide. Activation applies a held reconcile at once, before the activation input is handled, since it races macOS's own desktop switch; so do suspension, a display change and transitions turning off. A slide request is skipped on a display whose visible desktop is not current.
- New page: about 20 ms after the reconcile, the shell captures each sliding display while its visible desktop is current, retrying every 20 ms otherwise, since the shell's stash bounce runs first. If that capture fails or has not arrived 150 ms after the reconcile, the overlay is removed at once, ending the slide early: a dark page sliding all the way in, then switching to the real one, is the more jarring of the two.
- Cutting short: a navigation during a slide captures the real screen, which the filter shows without the overlay, then restarts that display's overlay from that image; the running slide and its pending capture are discarded. A bounce cuts a running slide short the same way. A bounce requested while a reconcile is held is dropped, as is one whose display has a newer slide request.
- Enabling: transitions run when `transition_ms` is above 0, Reduce Motion is off (observed through `NSWorkspace`'s accessibility display options notification), Screen Recording is granted (`CGPreflightScreenCaptureAccess`, checked at start, on config reload and when Reduce Motion changes) and shareable content is loaded. When only the permission is missing, minitile calls `CGRequestScreenCaptureAccess()` once per run and the menu shows "Grant Screen Recording to Minitile.app for page transitions".
- Untested in minitile: the implementation as a whole, multiple displays, navigation during a slide, Reduce Motion, other apps' windows, and whether macOS 26 and 27 ask the user to re-approve Screen Recording periodically, as macOS 15 does.

### Trackpad swipe mechanism

Validated with `dev/spikes/gesture` on macOS 27 with the built-in trackpad and four-finger swipes:

- A session-level event tap receives no swipe events. An event tap at the HID level (`kCGHIDEventTap`) receives each swipe as private event type 30 with HID event type 23 (field 110), the Dock swipe.
- Fields: 132 is the phase (1 began, 2 changed, 4 ended; cancelled was not seen), 123 the axis (1 sideways, 2 vertical), 124 the signed progress, and 129 the velocity on the ended event. Sideways progress is positive for fingers left; vertical progress is negative for fingers up. Across 23 swipes, each sent 17-81 events over 80-370 ms and ended at progress 0.19-1.32 with end velocity 1.4-8.6.
- Raw touch frames arrive alongside as event type 29 with HID event type 0; they are not needed.
- An active HID tap that swallows every type 30 event stops desktop switching, Mission Control and App Expose: 621 events over 11 swipes were swallowed, the tap was never disabled, and the screen did not change.
- Untested: three-finger swipes, Magic Mouse swipes, external trackpads and multiple displays.

minitile's swipes:

- Tap: an active tap at `kCGHIDEventTap`, inserted at the head, whose mask is event type 30 only (`1 << 30`), so no other input passes through minitile's callback. It runs on its own thread (`minitile.swipes`) with its own run loop. The callback reads fields 110, 132, 123, 124 and 129 and `CGEventGetLocation`, runs the swipe decision under a lock against a policy snapshot, and never waits for the main thread.
- Decision at began: minitile owns a swipe when its began event has HID event type 23 and axis 1 or 2, minitile is started and not suspended, and the display under the event location is managed and showing its visible desktop (not the stash, a fullscreen Space or an extra desktop). It then swallows every HID type 23 event until ended or cancelled, or passes them all, whatever the policy says meanwhile; an event with another phase follows the same decision. Type 30 events with another HID event type pass without affecting the swipe. Events without a preceding began, as when the tap starts mid-swipe, pass, and so does a swipe whose began has an unknown axis.
- Ended: the swipe acts if the absolute progress is at least 0.3 or the absolute end velocity at least 2. The sign of the progress gives the direction, and the sign of the velocity when the progress is exactly 0: sideways positive (fingers left) runs `page next`, sideways negative `page prev`, vertical negative (fingers up) `workspace next`, vertical positive `workspace prev`. The direction uses the axis of the began event. Cancelled does nothing.
- Command: the tap thread sends the command to the main thread asynchronously with the swiped display's address, for example `page next display UUID`, and the main thread runs it through the same path as a key binding, so it slides, bounces, holds the reconcile and focuses like Ctrl+arrows. A command that fails, for example because the session went inactive, is logged and dropped.
- Policy: the main thread rebuilds the snapshot (started, suspended, and each display's frame and whether it is managed with its visible desktop current, by `csl_current_space`) when minitile starts, on every native desktop switch (`activeSpaceDidChange`), when suspension begins or ends (resume also refreshes displays), on config reload and with the three-second topology probe.
- Coordinates: `CGEventGetLocation` and `DisplayInfo.frame` are both CG global coordinates (origin at the top-left of the primary display, y down), so hit-testing needs no conversion. Display frames are half-open, so a point on a shared edge belongs to the display to its right or below; a point outside every display passes.
- Lifecycle: the tap exists while minitile is started and `trackpad_swipes` is true. It is stopped on quit and when a config reload turns the setting off, and created again when one turns it back on.
- Failures: if the tap cannot be created or its thread exits unexpectedly, minitile logs it, the menu shows a warning and swipes stay with macOS; everything else keeps working, and a config reload tries again. When macOS disables the tap (`tapDisabledByTimeout`, `tapDisabledByUserInput`), the callback re-enables it at once and the one-second health check re-enables it if it finds it disabled; macOS handles swipes in between, and a swipe already decided keeps its decision.
- Health: `mntl debug health` reports `trackpad_swipes`, `swipe_tap_running`, `swipe_tap_unavailable` and `last_swipe` (see "Command line: mntl").
- Untested in minitile: the implementation as a whole, whether type 30 events carry the pointer location (`last_swipe` shows it), and swipes while Mission Control or App Expose is open: minitile cannot tell that they are open, so a swipe it owns navigates the grid behind them instead of closing them.

### Required user setup

- Two desktops per display.
- "Displays have separate Spaces" turned on, the default, so each display has its own desktops.
- "Automatically rearrange Spaces based on most recent use" turned off.
- The drag-to-tile options under Desktop & Dock turned off, since they fight drag-to-swap.
- Accessibility permission for `Minitile.app`.
- Screen Recording permission for `Minitile.app`, for page transitions only. minitile asks for it once, when transitions are first on without it, and rechecks it when the config reloads; until it is granted, the menu shows a warning.

## Architecture

minitile has three parts:

- Core (`MinitileCore`): the model, placement, layout, command grammar, config parsing and saved state, in pure Swift with no AppKit, AX or SkyLight. It turns inputs into outputs, so it is tested without a display or permissions. Handling an input does no I/O and must be fast: activation pre-emption has a few milliseconds of margin. It shares the `Reply`, `Event` and `JSONValue` wire types from `MinitileIPC`, exposed through core type aliases.
- IPC (`MinitileIPC`): the Unix socket server, the client and the JSON framing, Foundation only. `mntl` is a thin executable on top of it.
- Shell (the `minitile` app and the `CSkyLight` C/Objective-C target): everything that touches macOS. It observes apps, windows, displays, keys and the mouse, turns them into core inputs, and applies the core's outputs.

The core contract, as a shape. The core owns the exact Swift.

```swift
// Coordinates are CG global: origin at the top-left of the primary display, y grows down.
typealias WindowID = UInt32        // CGWindowID
typealias DisplayID = String       // display UUID

struct WindowInfo {                // filled in by the shell
    var id: WindowID
    var pid: Int32
    var bundleID: String?
    var appName: String
    var title: String
    var frame: Rect
    var tileable: Bool             // standard window by the rules in "Floating windows"
    var minimized: Bool
    var appHidden: Bool
    var fromFrontmostApp: Bool     // at the moment it appeared
    var display: DisplayID?        // where it stands now, for adoption
    var onStash: Bool              // for adoption
}

struct DisplayInfo {
    var id: DisplayID
    var frame: Rect
    var visibleFrame: Rect         // menu bar and Dock excluded
    var isPrimary: Bool
    var unmanagedReason: String?   // nil when the display has its desktop pair
}

enum Input {
    case started(saved: SavedState?, windows: [WindowInfo], displays: [DisplayInfo], focus: WindowID?)
    case configLoaded(Config)
    case displaysChanged([DisplayInfo])        // debounced and fingerprinted by the shell
    case windowAppeared(WindowInfo)
    case windowUpdated(WindowInfo)             // title, frame, minimized or app-hidden changed
    case windowGone(WindowID)
    case focusChanged(WindowID?)               // the shell drops echoes of its own focus actions
    case appActivated(pid: Int32)              // the pre-emption fast path
    case dragEnded(WindowID, frame: Rect, cursor: Point)
    case command([String])                     // keys, menu, mouse gestures and mntl
}

struct Output {
    var scene: Scene               // the desired placement of every managed window
    var actions: [Action]          // focus(WindowID), close(WindowID), reloadConfig, quit
    var rewrite: Set<WindowID>     // rewrite these frames although their targets are unchanged (snap back)
    var reply: Reply?              // for .command: ok, text, data
    var events: [Event]            // for mntl watch
    var stateChanged: Bool         // persist the saved state
}

struct Scene {
    var displays: [DisplayID: DisplayScene]
}

struct DisplayScene {
    var visible: [WindowID]        // windows that belong on the visible desktop
    var frames: [WindowID: Rect]   // targets for tiled windows; floating windows are absent
    var stashed: [WindowID]        // windows that belong on this display's stash
    var label: String              // for the menu bar, for example "2:3"
}

// Engine: init(config:), handle(_ input: Input) -> Output, savedState() -> SavedState
```

The shell applies an output in this order:

1. Moves first. Windows coming to a visible desktop are moved before windows going to a stash.
2. Frame writes, only where the target differs from the last write or the window is in `rewrite`, and never to a window the user is dragging.
3. Actions, with focus last.

The shell also:

- drops move, resize, focus and activation notifications caused by its own writes;
- bounces back from the stash (see "Rules minitile must follow"), which needs no core input;
- answers `debug` and `switcher` commands itself and passes every other command to the core as `.command(argv)`.

Scene visible/stashed lists express desktop ownership, including minimized and app-hidden windows. Frame targets cover active tiled windows on both shown and stashed pages; minimized, app-hidden, floating and explicitly hidden windows have no tiled frame target. `Action.setFrame` is a one-shot floating resize using the normal AX frame-write safeguards. `Action.openConfig` opens the config file. Both run before focus actions. IPC handlers supplied on `.main` use `MainActor.assumeIsolated` to access the shell's main-actor state.

## State and lifecycle

- The grid is saved to `~/.local/state/minitile/state.json` on every change (`MINITILE_STATE` overrides the path). It records each window's ID and pid, its slot or hidden state, the page variants and ratios, and each workspace's home display UUID.
- Window IDs stay valid while their app runs, so a restarted minitile resumes the same grid. Windows whose ID no longer exists, or whose pid changed, are dropped from the saved state.
- Windows found at start that are not in the state are adopted:
  - windows on the visible desktop fill pages of the first workspace;
  - windows on the stash follow on further pages.
- On quit, stashed windows stay on the stash, where Mission Control can reach them.
- Startup checks, in order: Accessibility permission (prompt, explain in the menu bar, and wait until granted); the SkyLight functions (refuse to run if missing); "Displays have separate Spaces"; a desktop pair per display (unmanaged displays are listed in the menu bar). If the current desktop of a display is its stash, minitile switches to the visible one.

Adoption preserves discovery order within the visible and stash groups. Stash adoption begins after the first workspace's last populated page, even if a visible page has free slots. Unknown windows join the first workspace without changing a valid saved view; the shell's startup focus observation can show a different page. Known windows keep their saved placement regardless of macOS's observed display position. Repeated observations of the same ID are ignored after the first. Unsupported or structurally invalid saved snapshots fall back to adoption. A changed pid in a later appearance/update is treated as a new window identity. Only `SavedState` supplies defaults for absent top-level fields. `PageState`, `WorkspaceState`, `DisplayState` and `WindowState` use synthesized decoding, so a missing required key fails decoding of the entire saved-state file. The script-facing `state` shape is documented separately above.

## Config

- The config lives in `~/.config/minitile/minitile.toml` (`MINITILE_CONFIG` overrides the path) and is reloaded when the file changes. Editors often replace the file, so the watch covers its directory.
- It is parsed with TOMLDecoder (github.com/dduan/TOMLDecoder, from 0.4.5: pure Swift, decodes into `Codable` types, MIT). A hand-written parser can replace it later if the dependency becomes a burden.
- A config error keeps the previous config and shows the error in the menu bar and in the reply to `mntl config reload`.
- There is no settings GUI. The menu bar icon shows the current workspace and page (the scene label), any warnings, and offers floating, layout variant, reload, open config and quit, each a command. Page and workspace changes also show the position indicator described under "Model".

An initial config error leaves the app inactive with a menu warning; Reload Config retries startup after correction. The watcher observes both the directory for atomic replacements and the file for in-place writes, debounced by 150 ms. A missing directory is watched through its nearest existing ancestor. Config reloads are deferred while the session or display topology is suspended and retried after display recovery.

Schema, with the defaults:

```toml
gaps = 8              # points between tiles
padding = 8           # points between tiles and the layout area's edge
float_apps = []       # bundle IDs that always float
only_apps = []        # bundle IDs; when non-empty, minitile manages only these apps
transition_ms = 500   # page slide duration, 0 to 2000; 0 turns slides and bounces off
trackpad_swipes = true  # swipes navigate pages and workspaces; false leaves them to macOS

[bindings]            # merged over the defaults; a chord bound to "" is unbound
"ctrl+left" = "page prev"
"ctrl+right" = "page next"
"ctrl+up" = "workspace prev"
"ctrl+down" = "workspace next"
"ctrl+shift+left" = "window nudge left"
"ctrl+shift+right" = "window nudge right"
"ctrl+shift+up" = "window move workspace prev"
"ctrl+shift+down" = "window move workspace next"
"cmd+`" = "window focus next"
"cmd+shift+`" = "window focus prev"
"ctrl+shift+space" = "page variant"
"cmd+tab" = "switcher next"
"cmd+shift+tab" = "switcher prev"
"ctrl+alt+left" = "window resize left"
"ctrl+alt+right" = "window resize right"
"ctrl+alt+up" = "window resize up"
"ctrl+alt+down" = "window resize down"
```

The command strings above use the final grammar. A chord is modifiers (`ctrl`, `shift`, `alt`, `cmd`) and one key (a letter, a digit, `left`, `right`, `up`, `down`, `return`, `space`, `tab`, `escape`, `f1` to `f20`, and `` ` `` for the key of macOS's Move focus to next window shortcut), joined with `+`.

`Config.parse` accepts file contents, with nil for an absent file; file I/O stays in the shell. Gaps and padding must be finite, nonnegative numbers. `trackpad_swipes` is a boolean. App lists contain nonempty bundle ID strings without surrounding whitespace. Unknown config keys, invalid field types, unsupported keys, repeated modifiers and duplicate normalized chords are rejected. Chords accept case and modifier-order variations and are displayed as ctrl, shift, alt, cmd, then key. Binding commands are split on whitespace; they are not shell commands and do not perform shell expansion. Command validation happens when executed, allowing shell-owned debug and switcher verbs.

## macOS behaviour to respect

Learned from HyprMac and the spikes.

Frame writes:

- Turn `AXEnhancedUserInterface` off on the app around frame writes and restore it afterwards, once per app per pass.
- Write size, then position, then size again. macOS clamps size to the screen the window currently stands on.
- Round frames to whole points. Skip writes when the cached frame already matches.
- If a size write fails with AX error -25205 (Dia), nudge it by 1 pt and retry.
- Read back once after the window settles, with loose tolerance (about 20 pt, since Terminal snaps to its cell grid). If a window refuses its slot, adjust once; never fight the app.
- Ignore move and resize notifications caused by minitile's own writes for about 1-1.5 s, since AX reads lag on macOS 26 and 27. Otherwise they look like user drags.

While the left mouse button is down, an AX frame differing from the last write by more than 20 points identifies a user drag even during suppression. Delayed frame verification skips held mouse buttons and dragged windows. The 30 ms release poll runs only while a drag is active.

Discovery:

- One `AXObserver` per app. App-level notifications: window created, focused window changed, main window changed, application activated. Window-level notifications: element destroyed, moved, resized, title changed, miniaturized, deminiaturized.
- Also handle NSWorkspace notifications: launch, terminate, hide, unhide, activate, active space changed.
- Window IDs come from `_AXUIElementGetWindow` only, never matched by position.
- Treat a window as real only if the CG window list shows it at layer 0 with alpha above 0.01.
- A failed AX read means "unknown", not "closed". A destroyed element may not report its pid, so use the observer's pid.
- Apps can keep listing a destroyed window briefly. Confirm disappearance with a few rechecks; busy Electron apps flicker otherwise.
- Some apps (Teams, Mail) reuse window IDs on close and reopen.
- While the session is locked or the displays sleep, the on-screen window list empties. Freeze lifecycle changes until the interruption ends.

The shell confirms disappearance after three WindowServer snapshots no longer contain the same window ID and pid. Event-triggered rechecks share one pending sequence at 150, 400 and 900 ms, scoped to affected pids; later notifications extend the affected pid's confirmations without duplicating timers. Focus and destroy rechecks read WindowServer presence only, while creation rechecks inspect the supplied new-window elements. A three-second full AX scan catches missed notifications and retries incomplete observer registrations. An app is recorded as observed only after each app-level registration succeeds or reports the notification unsupported; unsupported notifications are not retried, and other failed app or window registrations are retried. An empty or failed WindowServer snapshot is unknown. Background agents with prohibited activation policy are excluded from AX observation. Sleep, session inactivity, lock and pending display reconfiguration suspend lifecycle changes.

Responsiveness:

- Set `AXUIElementSetMessagingTimeout` to about 1 s system-wide; the default of about 6 s freezes the manager on a hung app.
- The keyboard event tap runs on its own thread. Re-enable it on `tapDisabledByTimeout` and `tapDisabledByUserInput`, reset modifier state, and check periodically that it is still alive. Secure input silently stops it; show that in the menu bar (`IsSecureEventInputEnabled`).
- Swallow the key-up of every swallowed key-down.

Focus and closing:

- Set AX main and focused (plus raise), then call `activate`, then use SkyLight `_SLPSSetFrontProcessWithOptions` with the two key-window event records. On macOS 27, `activate` from an accessory app is dropped.
- Keep our own record of the focused window; `kAXFocusedWindow` lags in some apps.
- Forward focus/main-window notifications only from the frontmost app. For 1.2 s after a minitile focus action, suppress all focus notifications and activations from that pid, and reread once after the interval. Each app's echo is kept separately, so when focus moves quickly between apps (Cmd+` pressed repeatedly), late echoes of earlier focus actions are still recognised; an activation that is not an echo ends them all. A failed AX focus read is unknown and preserves the current focus.
- Focus actions are coalesced: the core's focus changes at once, but the Accessibility and SkyLight focus calls run once per main-loop turn for the latest target. `debug timings` reports the last run's duration as `focus_ms`.
- Activating an app does not necessarily send a focus notification. When another app is activated, clear a recorded focus owned by a different app at once, without AX reads, then read the activated app's focus about 150 ms later, after macOS has settled its key window. An earlier read can return a stale key window on a hidden page.
- Close a window by pressing its `kAXCloseButton`.

## Implementation

- Swift 6.4 toolchain, built with SwiftPM, with no Xcode project. Minimum macOS 26; only 27 has been tested.
- Targets:
  - `MinitileCore`, library, depends on TOMLDecoder and MinitileIPC;
  - `MinitileIPC`, library, Foundation only;
  - `CSkyLight`, C/Objective-C: the SkyLight declarations, the `LC_SYMTAB` lookup, the bridged operations, the window-ID and focus calls;
  - `minitile`, executable, the menu bar app (AppKit), depends on the three above;
  - `mntl`, executable, depends on `MinitileIPC` only;
  - `MinitileCoreTests`, `MinitileIPCTests` and `MinitileShellTests`, using swift-testing.
- `scripts/build-app.sh` wraps `minitile` in `build/Minitile.app` (bundle ID `com.github.fiorix.minitile`, `LSUIElement` set) and places `mntl` next to it. It signs with `MINITILE_SIGN_IDENTITY`, default "Apple Development", so the Accessibility grant survives rebuilds; an ad-hoc signature changes every build.
- Logging uses unified logging with subsystem `minitile`.
- Threads:
  - the main thread runs the `NSApplication` loop, AX work, the core and the reconciler;
  - the keyboard event tap runs on its own thread and hands commands and window switcher keys to the main thread;
  - the trackpad swipe tap runs on its own thread and does the same;
  - the socket server reads on a background queue and does the same.

  If hung apps stall the main thread in practice, AX calls move to per-app threads, as AeroSpace does.

The shell uses the Swift 6 language mode. AX observer callbacks run on the main run loop; the keyboard tap owns a separate run loop and locks its small command-matching state, and the swipe tap does the same for its swipe decision and policy snapshot. Letter and digit bindings use the current keyboard layout, with function and navigation keys matched by native keycode. Stash Desktop N blockers use user-desktop order from the native display-space enumeration; their numbering with multiple displays is unverified. State writes are atomic and serialized off the main thread, and quit flushes pending writes.

## Development and testing

- Core, IPC and the shell's pure helpers have unit tests run with `swift test`. They need no permissions and never touch windows.
- The shell is tested live with `scripts/smoke.sh`. Runs use a temporary config with `only_apps = ["com.apple.TextEdit"]`, temporary state and socket paths, and TextEdit documents the test opens itself, so the user's windows are never moved or closed.
- Running minitile over every app rearranges the user's desktops, so the first such run needs the user's go-ahead.
- `dev/spikes/` holds the throwaway programs that validated the primitives, with their logs. They are reference code for SkyLight, focus, activation pre-emption and the event tap, not a base to build on. Upstream sources: yabai `src/misc/macho_dlsym.h` and `src/space_manager.c`.

`scripts/smoke.sh` modes:

- default: drives minitile through `mntl`, compares the requested scene with raw WindowServer spaces and AX frames (20 pt tolerance), and checks invalid-config retention and restart persistence;
- `--interactive`: pauses for physical keys, mouse and trackpad input, with key tracing (`MINITILE_TRACE_KEYS=1` writes `minitile: key` JSON records to stderr for Ctrl+arrow events only);
- `--displays`: starts with the external monitor unplugged, then checks display independence, cross-display activation, and unplug and reconnect restoring the original grids;
- `--activation`: measures ten isolated TextEdit activation cycles after focus-notification bursts, including native desktop assertions;
- `--cleanup TEST_DIRECTORY`: reopens a preserved test session and closes its documents;
- `--no-build`: reuses the signed bundle.

Reports go to `build/smoke-*`. `MINITILE_SMOKE_DIRECTORY` restricts discovery to documents directly inside the test directory, so unsaved documents stay unmanaged, and `MINITILE_SMOKE_WINDOWS` restricts startup stash acquisition to the test's window ID/pid pairs. Cleanup closes only the test's documents, preserves files if cleanup fails, and quits TextEdit only if the test started it and no windows remain. `--cleanup` accepts only smoke directories directly inside TMPDIR.

Smoke runs start on each display's first native desktop. The automatic mode also opens and closes a sixth document with another app frontmost, verifying that the shown page is preserved; if TextEdit becomes frontmost, that attempt is not a valid background test. `MINITILE_TRACE_FOCUS=1` optionally logs focus decisions and new-window foreground status using only pids and window IDs.

## Scope

First version:

- the grid model and stash hiding;
- the placement, close, creation and focus rules;
- Ctrl+arrow navigation, nudge and carry;
- mouse resize, drag-to-swap, and Ctrl+arrow while dragging;
- display merge and unmerge;
- floating (rules and toggle) and layout variants;
- the command set, the socket and `mntl`;
- the config file with reload, the menu bar icon and the state file;
- activation pre-emption;
- page transitions: slides and edge bounces;
- trackpad swipes for pages and workspaces;
- the Cmd+Tab window switcher;
- keyboard resizing and the mirrored and stacked three-window layouts;
- the drop picker for dragged windows.

Not planned:

- focus-follows-mouse;
- focus borders and dimming;
- a mouse-driven overview;
- live previews of edge drags;
- saved layouts;
- a URL scheme (status bars can use `mntl watch`);
- a settings GUI;
- animations other than page transitions.

## Open

- Multiple displays, to be tested with the user's second monitor:
  - each display's stash works on its own: moves and page flips on one display leave the other alone;
  - activation pre-emption when the app's window sits on the other display's stash;
  - what macOS does with a disconnected display's desktops and the windows on its stash, and whether they come back on reconnect. Seen once: after an unplug, the laptop had user desktops 1, 1244 and 1264, where 1264 had been the external display's stash.
