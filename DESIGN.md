# minitile design

minitile is a tiling window manager for macOS. It runs with SIP enabled and aims for a small core that blends with macOS: a handful of keys that reuse the native desktop shortcuts, mouse gestures where macOS users already use the mouse, and every function scriptable from the `mntl` command line tool. HyprMac (github.com/zacharytgray/HyprMac) is a source of macOS behaviour to respect, not a feature list to copy.

Status: core, IPC and mntl are implemented and verified with 84 core tests and 17 IPC tests. The macOS shell builds with 21 helper/fixture tests and has passed the single-display TextEdit command smoke test, including native placement, config-error retention and restart persistence. Signing and Accessibility work when launched from Terminal. Physical Ctrl and Ctrl+Shift arrows, Mission Control/App Expose suppression, tiled resize, swap, Ctrl+Right during a drag, Cmd+Tab pre-emption and trackpad stash bounce are verified on one display. A persistent position grid is implemented and rendered offscreen; its live placement and multiple-display behavior still need validation.

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

Each display has a persistent, read-only grid in the upper-right corner of its usable area. The header names the display and states the current workspace and page. Workspaces are rows labeled W1, W2, and so on; pages are columns labeled P1, P2, and so on. The blue cell marks the shown page, including an empty page, and each cell contains its window count. "Active" identifies the remembered display used for navigation when focus is outside the managed windows.

The indicator shows at most six rows and eight columns, centered around the current position where possible. Cropped grids retain their full indices and say they are cropped. An unmanaged display shows its reason instead of a grid. The panel follows its physical display through topology changes, passes mouse input through, cannot become the key or main window, and stays present across native desktop switches. Light and dark appearances are supported. This is an orientation aid, not an interactive overview.

### Placement

- A new window goes to the workspace being viewed. It takes the first free slot, scanning from the current page to the right; if none is free, it goes onto a new page at the end of the workspace.
- If a new window from the frontmost app lands on a page that is not shown, that page is shown, since macOS focuses such windows. Windows from background apps are placed without changing the view.
- When a window closes, the remaining windows on its page re-tile, and the freed slot is reused by the next new window. Windows never flow back from later pages.
- When focus moves to a window on a hidden page by any means (Cmd+`, the Dock, a notification, `mntl window focus`), that page is shown.
- When an app with no window on a shown page is activated (Cmd-Tab, the Dock), the page holding its most recently focused window is shown. macOS does the focusing. Minimized windows do not count as being on a shown page; windows of a hidden app do, since activation unhides them. See "Rules minitile must follow" for the timing.

### Navigation and focus

- Showing a page focuses the window that last had focus on it, or its first window. An empty page focuses nothing.
- When the focused window closes or is minimized, or its app is hidden, minitile does not focus another window. macOS picks the next one, and minitile follows it.
- Showing a workspace shows the page last viewed in it.
- Ctrl+Left on the first page and Ctrl+Up on the first workspace do nothing.
- Ctrl+Right on the last page opens an empty page, and Ctrl+Down on the last workspace opens an empty workspace. Neither opens a second empty one next to an empty one.
- A window opened while an empty page or workspace is viewed lands in it. An empty page or workspace is removed when the view leaves it.
- Pages are otherwise created by spill and by nudging a window out of a shared page (see Keys).

### Minimized and hidden windows

- A minimized window keeps its slot, and its page re-tiles without it. When it is unminimized, it returns to its slot and its page is shown.
- Windows of a hidden app (Cmd+H) keep their slots, and their pages re-tile without them until the app is unhidden.
- `mntl window hide` takes a window off its page, freeing the slot, and keeps it on the stash. `mntl window show` places it like a new window on the current workspace and focuses it.

### Layout

Each page holds an ordered list of windows, its slots. The layout is a fixed function of the window count and the page's variant:

| Windows | Default variant | Alternate variant |
|---|---|---|
| 1 | full | - |
| 2 | two halves across the long axis | two halves across the short axis |
| 3 | one large plus two stacked | three slices across the long axis |
| 4 | 2x2 | - |

- On a landscape display the long axis is the width: two windows sit side by side, and the large window of three is on the left. On a portrait display the axes swap.
- Slot 0 is the large tile. A closed window's slot disappears and later windows move up.
- `mntl page variant` toggles the variant.

Geometry:

- The layout area is the display's visible frame (menu bar and Dock excluded) inset by `padding`. Tiles are separated by `gaps`. Frames are rounded to whole points.
- Each page has two ratios, r1 and r2, each a position across the layout area:
  - 2 windows: r1 is the cut.
  - 3, large plus two: r1 cuts the large tile from the pair along the long axis; r2 cuts the pair along the short axis.
  - 3, slices: r1 and r2 are the two cuts along the long axis.
  - 4: r1 is the cut along the long axis, r2 the cut along the short axis.
- Defaults are 0.5, except three slices at 1/3 and 2/3. Ratios are clamped to 0.2-0.8, and the cuts of three slices stay at least 0.2 apart.
- Ratios reset to the defaults when the page's window count or variant changes.

The count for ratio resets is the number of non-minimized, non-app-hidden tiled windows. A square visible frame uses width as its long axis. Cuts are centered in gaps; frame edges are rounded individually and width/height are the differences of rounded edges. Insets and unusually large gaps never produce negative sizes. A single-cut edit preserves the other cut when enforcing three-slice spacing; setting both ratios clamps r1 first, then brings r2 above it, moving r1 back if necessary to fit within 0.8.

Mouse:

- Each inner edge of a tile lies on one cut. Dragging a tiled window's edge moves that cut: the new ratio is the edge's position across the layout area, clamped. A corner drag moves both cuts. Edges on the border of the layout area are not cuts, and dragging them snaps back.
- A drag that ends with the size unchanged (within a few points) is a move. If the cursor is over another tiled window on the same page, the two swap slots; otherwise the window snaps back.

The move tolerance is 3 points per dimension. Edge drags are converted from the tile edge to the gap center before computing a ratio. A drag can update the inner cut of a corner while its border edge snaps back. Three-slice middle-window resize holds the right cut fixed and moves the left cut to obtain the requested share.

## Keys

minitile takes over the Ctrl+arrow shortcuts macOS uses for desktops and Mission Control, and gives them the same meaning on its grid. There is no Hypr key and no Caps Lock remap. Closing and quitting stay on Cmd+W and Cmd+Q.

Default bindings:

| Keys | Action | Replaces in macOS |
|---|---|---|
| Ctrl+Left/Right | Show the previous or next page. | Move left/right a space |
| Ctrl+Up/Down | Show the workspace above or below. | Mission Control, App Expose |
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

- Drag a tiled window's edge to resize, or drag it onto another tile to swap (see Layout). There is no live preview.
- Press Ctrl+arrow while dragging a window to do to it what Ctrl+Shift+arrow does. This is how macOS moves a window to another desktop. Frames of a window being dragged are not written until the mouse button is released.
- A move or resize that minitile did not cause, seen while the mouse button is down, is a user drag. minitile acts on release.

Everything else (floating, layout variant, spatial focus, exact ratios) is a command: reachable from `mntl`, from the menu bar where it makes sense, and bindable to keys in the config.

Notes:

- Validated with physical keys in the app: Ctrl+Right/Left changed pages and Ctrl+Down/Up changed workspaces. The user confirmed the expected window counts without Mission Control or App Expose opening; the watch log recorded the corresponding page/workspace transitions. The earlier session-tap probe also swallowed a HID-synthesized Ctrl+Left before the Dock switched desktops. Ctrl+Up/Down are system shortcuts 32 and 33 with the same Ctrl+fn modifiers as Ctrl+Left/Right (79 and 81).
- Arrow keys carry the fn and keypad flags, so binding matches ignore them.
- Mission Control stays reachable through its own key and trackpad gesture. It shows the stash desktop with every hidden page's windows, which makes it an escape hatch rather than a view of the grid.
- The event tap also swallows Desktop N shortcuts that would lead into the stash.

## Command line: mntl

Every minitile function is a command. Key bindings, the menu bar, mouse gestures and `mntl` all run commands through the same path. Anything the user can do, `mntl` can do, and anything minitile knows, `mntl` can read.

- The menu bar app listens on a Unix socket at `$TMPDIR/minitile.sock`, the per-user temp directory from `confstr(_CS_DARWIN_USER_TEMP_DIR)`. The socket file is mode 0600, and connections from other users are refused after a `getpeereid` check. `MINITILE_SOCKET` overrides the path for both sides.
- At start, if the socket path exists and something answers on it, minitile reports that another instance is running and quits. A stale socket file is removed.
- The protocol is newline-delimited JSON, one object per line. A request is `{"argv": [...]}`. A response is `{"ok": bool, "text": string, "data": any}`. Requests over 64 KiB or malformed requests get an error response and the connection is closed.
- `mntl watch` gets one `ok` response, then one JSON event per line until the client disconnects.
- `mntl` is a thin client. It sends its arguments, prints `text` (or `data` with `--json`) and exits 0 on success, 1 on a command error and 2 when minitile cannot be reached. New commands need no change to `mntl`.
- Config bindings and menu items use the same command strings, for example `"ctrl+left" = "page prev"`.
- `mntl debug <verb>` commands are answered by the app shell and expose internals: raw desktops per display, the last applied scene, timings. Debug verbs can be added freely. Every other command is answered by the core.

The shell provides `debug spaces`, `debug windows`, `debug scene`, `debug timings` and `debug health`. Spaces include the native display identifier, every native Space and its type, current Space, and core display metadata. The desktop list comes from the last catalog refresh; current Space is read for each request. Windows include allowed apps' raw layer-0 windows, AX observation status, current spaces, frames and tileability. Scene frame keys are decimal window-ID strings. Health includes process ID, startup/suspension state and reasons, secure input, tap availability, paths and warnings. The menu can open config, retry startup after a config error, or quit while normal command handling is still unavailable.

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
| `mntl window focus [id, dir]` | Focus by ID, or spatially on the page. |
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
window focus [ID|left|right|up|down]
window float [ID] [on|off]
window nudge [ID] left|right
window move [ID] left|right|up|down
window move [ID] page|workspace INDEX|next|prev
window move [ID] display UUID|next|prev
window swap [ID] OTHER_ID
window resize [ID] SHARE|WIDTHxHEIGHT
page list
page info|show|variant [INDEX|next|prev]
page next|prev
page ratio R1 [R2]
workspace list
workspace info|show [INDEX|next|prev]
workspace next|prev|new
display list
display info [UUID|next|prev]
config list|info|reload|open
quit
```

Page and workspace addresses are 1-based; tiled slots are 0-based. Floating and explicitly hidden windows have a null slot. Window IDs are decimal. With no focused window, commands use the most recently selected display, then the primary managed display. `page list` lists the current workspace; `workspace list` lists the current display. An explicit display UUID can inspect an unmanaged display. `info`, `show` and `variant` addresses resolve within the current context; `next`/`prev` in these addresses clamp at the ends. Only navigation commands and window moves create pages or workspaces. `workspace new` appends an empty workspace unless the current one is already empty.

Window moves and swaps follow the addressed source window. A move to its existing page does nothing. Left/right moves are nudges; up/down moves carry between workspaces. Explicit moves to a full page use placement spill. Spatial focus chooses the nearest window center in the requested half-plane on the same page, with grid order breaking ties; it does not wrap. Minimized and app-hidden windows are excluded from spatial focus.

For tiled resize, a single share applies along the layout's split axis; `WIDTHxHEIGHT` supplies physical-axis fractional shares. Cuts are clamped by the layout rules. Floating resize requires `WIDTHxHEIGHT` in positive points and emits an explicit frame-write action. `page ratio R1` leaves r2 unchanged. Config reload is completed by the shell before its socket reply; failures keep the previous config. `config open` opens the config file in the user's editor.

### JSON data contract

Every response has `ok`, `text` and `data`. Errors and successful mutations use null data; inspection commands use the shapes below. Missing addresses, bundle IDs, desktop IDs and focus values are null rather than omitted. Rectangles use `{x, y, width, height}` in global points. `info` text contains one field per line; list text uses aligned columns. Text is for people; scripts should use `--json`.

| Command | Data |
|---|---|
| `help` | Grammar string. |
| `window list`, `window info` | Array of window objects, or one window object. Fields: `id`, `pid`, `bundle_id`, `app`, `title`, `frame`, `display`, `workspace`, `page`, `slot`, `floating`, `hidden`, `focused`, `shown`, `minimized`, `app_hidden`, `tileable`. `frame` is the latest observed or explicitly resized frame. `hidden` means explicitly hidden by mntl; `shown` also excludes minimized/app-hidden windows and pages not being viewed. |
| `page list`, `page info` | Array of page objects, or one page object. Fields: `id` (persistent identity), `index`, `display`, `workspace`, `shown`, `variant` (`standard` or `alternate`), `r1`, `r2`, `windows` (all assigned IDs in order), `tiled` (including reserved minimized/app-hidden slots), `floating`, `last_focus`. |
| `workspace list`, `workspace info` | Array of workspace objects, or one workspace object. Fields: `id` (persistent identity), `index`, `display` (current host), `home`, `shown`, `page` (last-viewed page index), `pages` (page objects). |
| `display list`, `display info` | Array of display objects, or one display object. Fields: `id` (UUID), `frame`, `visible_frame`, `primary`, `unmanaged_reason`, `visible_space`, `stash_space`, `workspace` (current index), `workspaces` (workspace objects), `home_workspaces`, `merged_workspaces` (workspace index arrays). |
| `config list`, `config info` | Object with `gaps`, `padding`, `float_apps`, `only_apps`, `bindings`. Binding keys are canonical chords and values are command strings. |
| `state` | Object with `version: 1`, `focus`, `active_display`, `displays` (display objects), `windows` (window objects ordered by ID). This inspection shape is separate from the saved-state file. |

Watch events have `{type, data}`. Types `focus`, `window_added`, `window_removed` and `window_moved` carry a window ID; `focus` can carry null. `page_shown` carries `{display, workspace, page}` with indices after empty-page cleanup. `display_changed` carries the supplied array of `DisplayInfo` objects using their Swift Codable field names. `config_reloaded` carries null. A watcher is disconnected if its pending output exceeds 4 MiB; ordinary command replies can be larger. The CLI prints the initial watch reply using its usual text/data choice, followed by JSON event lines.

Each connection carries one request. Ordinary replies close the connection after their bytes are written; accepted watch connections remain open. The 64 KiB request limit excludes the terminating newline. The client uses 5-second send/reply timeouts and disables the receive timeout after a successful watch reply. Socket startup preserves regular files and symlinks at the requested path, removes only stale owned sockets, and stop removes only the inode this server bound. `mntl --help` is local; no command arguments request server help and print local usage if transport fails. Invalid local options or an oversized request exit 1; transport or response-decoding failures exit 2.

## Displays

- A grid's home display is identified by its display UUID (`CGDisplayCreateUUIDFromDisplayID`), the key native Spaces use. `CGDirectDisplayID` can change across sleep and wake.
- Each display's desktops come from `SLSCopyManagedDisplaySpaces`. The visible desktop is its first user desktop and the stash is its last. Fullscreen Spaces are ignored.
- minitile requires "Displays have separate Spaces". Without it there is no desktop pair per display, and minitile refuses to manage and says why.
- Display changes are debounced: about 2 s, or 5 s after wake. False display-change notifications (calls, colour profile changes) are filtered by comparing a fingerprint of the display set.
- While active, the shell also probes native desktop topology every three seconds. Changes to display identifiers or desktop IDs, types and order schedule the same debounced refresh, so creating a second desktop does not require switching to it. The probe ignores the current Space and does not update the catalog before the debounce completes; failed or empty reads retain the last catalog.
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
- At start, windows already on a stash have no AX handle, because `kAXWindows` omits them. minitile moves them to the visible desktop in one call, takes their AX handles, and lets the first reconcile stash them again. They show for a moment at start. Verified with TextEdit: both of two stashed windows returned AX handles on the first discovery pass after the move, without retries.

The shell tries discovery immediately, then up to four more times at 250 ms intervals. It restores windows with unreadable AX handles to their original stash and reports them. Quitting during adoption restores the temporarily exposed windows. The successful first-pass path is verified with TextEdit; retry exhaustion and abort recovery remain unverified live. Startup discovery is ordered by window ID before the core applies its visible-before-stash adoption rules.

Known risks:

- After an instant switch, the Dock's idea of the current desktop occasionally drifts from the real one (1 of 27 bounces). A Dock-driven move toward the stash then does nothing, and one toward the visible desktop plays a phantom slide. There is no API to detect this. A Dock-driven desktop shortcut re-syncs it.
- Untested:
  - multiple displays (see Open);
  - Mission Control and App Expose through their dedicated keys or gestures, Dock and notification clicks;
  - Stage Manager and fullscreen Spaces;
  - Reduce Motion on;
  - "When switching to an application, switch to a Space with open windows" turned off;
  - Dock restarts and sleep/wake;
  - Electron apps.

### Required user setup

- Two desktops per display.
- "Displays have separate Spaces" turned on, the default, so each display has its own desktops.
- "Automatically rearrange Spaces based on most recent use" turned off.
- The drag-to-tile options under Desktop & Dock turned off, since they fight drag-to-swap.
- Accessibility permission for `Minitile.app`.

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
- answers `debug` commands itself and passes every other command to the core as `.command(argv)`.

Scene visible/stashed lists express desktop ownership, including minimized and app-hidden windows. Frame targets cover active tiled windows on both shown and stashed pages; minimized, app-hidden, floating and explicitly hidden windows have no tiled frame target. `Action.setFrame` is a one-shot floating resize using the normal AX frame-write safeguards. `Action.openConfig` opens the config file. Both run before focus actions. IPC handlers supplied on `.main` use `MainActor.assumeIsolated` to access the shell's main-actor state.

## State and lifecycle

- The grid is saved to `~/.local/state/minitile/state.json` on every change (`MINITILE_STATE` overrides the path). It records each window's ID and pid, its slot or hidden state, the page variants and ratios, and each workspace's home display UUID.
- Window IDs stay valid while their app runs, so a restarted minitile resumes the same grid. Windows whose ID no longer exists, or whose pid changed, are dropped from the saved state.
- Windows found at start that are not in the state are adopted:
  - windows on the visible desktop fill pages of the first workspace;
  - windows on the stash follow on further pages.

Adoption preserves discovery order within the visible and stash groups. Stash adoption begins after the first workspace's last populated page, even if a visible page has free slots. Unknown windows join the first workspace without changing a valid saved view; the shell's startup focus observation can show a different page. Known windows keep their saved placement regardless of macOS's observed display position. Repeated observations of the same ID are ignored after the first. Unsupported or structurally invalid saved snapshots fall back to adoption. A changed pid in a later appearance/update is treated as a new window identity. Only `SavedState` supplies defaults for absent top-level fields. `PageState`, `WorkspaceState`, `DisplayState` and `WindowState` use synthesized decoding, so a missing required key fails decoding of the entire saved-state file. The script-facing `state` shape is documented separately above.
- On quit, stashed windows stay on the stash, where Mission Control can reach them.
- Startup checks, in order: Accessibility permission (prompt, explain in the menu bar, and wait until granted); the SkyLight functions (refuse to run if missing); "Displays have separate Spaces"; a desktop pair per display (unmanaged displays are listed in the menu bar). If the current desktop of a display is its stash, minitile switches to the visible one.

## Config

- The config lives in `~/.config/minitile/minitile.toml` (`MINITILE_CONFIG` overrides the path) and is reloaded when the file changes. Editors often replace the file, so the watch covers its directory.
- It is parsed with TOMLDecoder (github.com/dduan/TOMLDecoder, from 0.4.5: pure Swift, decodes into `Codable` types, MIT). A hand-written parser can replace it later if the dependency becomes a burden.
- A config error keeps the previous config and shows the error in the menu bar and in the reply to `mntl config reload`.

An initial config error leaves the app inactive with a menu warning; Reload Config retries startup after correction. The watcher observes both the directory for atomic replacements and the file for in-place writes, debounced by 150 ms. A missing directory is watched through its nearest existing ancestor. Config reloads are deferred while the session or display topology is suspended and retried after display recovery.
- There is no settings GUI. The menu bar icon shows the current workspace and page (the scene label), any warnings, and offers floating, layout variant, reload, open config and quit, each a command. Each display also has the read-only position indicator described above.

Schema, with the defaults:

```toml
gaps = 8              # points between tiles
padding = 8           # points between tiles and the layout area's edge
float_apps = []       # bundle IDs that always float
only_apps = []        # bundle IDs; when non-empty, minitile manages only these apps

[bindings]            # merged over the defaults; a chord bound to "" is unbound
"ctrl+left" = "page prev"
"ctrl+right" = "page next"
"ctrl+up" = "workspace prev"
"ctrl+down" = "workspace next"
"ctrl+shift+left" = "window nudge left"
"ctrl+shift+right" = "window nudge right"
"ctrl+shift+up" = "window move workspace prev"
"ctrl+shift+down" = "window move workspace next"
```

The command strings above use the final grammar. A chord is modifiers (`ctrl`, `shift`, `alt`, `cmd`) and one key (a letter, a digit, `left`, `right`, `up`, `down`, `return`, `space`, `tab`, `escape`, `f1` to `f20`), joined with `+`.

`Config.parse` accepts file contents, with nil for an absent file; file I/O stays in the shell. Gaps and padding must be finite, nonnegative numbers. App lists contain nonempty bundle ID strings without surrounding whitespace. Unknown config keys, invalid field types, unsupported keys, repeated modifiers and duplicate normalized chords are rejected. Chords accept case and modifier-order variations and are displayed as ctrl, shift, alt, cmd, then key. Binding commands are split on whitespace; they are not shell commands and do not perform shell expansion. Command validation happens when executed, allowing shell-owned debug verbs.

## macOS behaviour to respect

Learned from HyprMac and the spikes.

Frame writes:

- Turn `AXEnhancedUserInterface` off on the app around frame writes and restore it afterwards, once per app per pass.
- Write size, then position, then size again. macOS clamps size to the screen the window currently stands on.
- Round frames to whole points. Skip writes when the cached frame already matches.
- If a size write fails with AX error -25205 (Dia), nudge it by 1 pt and retry.
- Read back once after the window settles, with loose tolerance (about 20 pt, since Terminal snaps to its cell grid). If a window refuses its slot, adjust once; never fight the app.
- Ignore move and resize notifications caused by minitile's own writes for about 1-1.5 s, since AX reads lag on macOS 26 and 27. Otherwise they look like user drags.

Discovery:

- One `AXObserver` per app. App-level notifications: window created, focused window changed, main window changed, application activated. Window-level notifications: element destroyed, moved, resized, title changed, miniaturized, deminiaturized.
- Also handle NSWorkspace notifications: launch, terminate, hide, unhide, activate, active space changed.
- Window IDs come from `_AXUIElementGetWindow` only, never matched by position.
- Treat a window as real only if the CG window list shows it at layer 0 with alpha above 0.01.
- A failed AX read means "unknown", not "closed". A destroyed element may not report its pid, so use the observer's pid.
- Apps can keep listing a destroyed window briefly. Confirm disappearance with a few rechecks; busy Electron apps flicker otherwise.

The shell confirms disappearance after three WindowServer snapshots no longer contain the same window ID and pid. Event-triggered rechecks run at 150, 400 and 900 ms; a three-second scan catches missed notifications. An empty or failed WindowServer snapshot is unknown. Background agents with prohibited activation policy are excluded from AX observation. Sleep, session inactivity, lock and pending display reconfiguration suspend lifecycle changes.
- Some apps (Teams, Mail) reuse window IDs on close and reopen.
- While the session is locked or the displays sleep, the on-screen window list empties. Freeze lifecycle changes until the interruption ends.

Responsiveness:

- Set `AXUIElementSetMessagingTimeout` to about 1 s system-wide; the default of about 6 s freezes the manager on a hung app.
- The keyboard event tap runs on its own thread. Re-enable it on `tapDisabledByTimeout` and `tapDisabledByUserInput`, reset modifier state, and check periodically that it is still alive. Secure input silently stops it; show that in the menu bar (`IsSecureEventInputEnabled`).
- Swallow the key-up of every swallowed key-down.

Focus and closing:

- Set AX main and focused (plus raise), then call `activate`, then use SkyLight `_SLPSSetFrontProcessWithOptions` with the two key-window event records. On macOS 27, `activate` from an accessory app is dropped.
- Keep our own record of the focused window; `kAXFocusedWindow` lags in some apps.
- Close a window by pressing its `kAXCloseButton`.

## Implementation

- Swift 6.4 toolchain, built with SwiftPM, with no Xcode project. Minimum macOS 26; only 27 has been tested.
- Targets:
  - `MinitileCore`, library, depends on TOMLDecoder and MinitileIPC;
  - `MinitileIPC`, library, Foundation only;
  - `CSkyLight`, C/Objective-C: the SkyLight declarations, the `LC_SYMTAB` lookup, the bridged operations, the window-ID and focus calls;
  - `minitile`, executable, the menu bar app (AppKit), depends on the three above;
  - `mntl`, executable, depends on `MinitileIPC` only;
  - `MinitileCoreTests` and `MinitileIPCTests`, using swift-testing.
- `scripts/build-app.sh` wraps `minitile` in `build/Minitile.app` (bundle ID `com.github.fiorix.minitile`, `LSUIElement` set) and places `mntl` next to it. It signs with `MINITILE_SIGN_IDENTITY`, default "Apple Development", so the Accessibility grant survives rebuilds; an ad-hoc signature changes every build.

The shell remains in Swift 6 mode. AX observer callbacks run on the main run loop; the keyboard tap owns a separate run loop and locks its small command-matching state. Letter and digit bindings use the current keyboard layout, with function and navigation keys matched by native keycode. Stash Desktop N blockers use user-desktop order from the native display-space enumeration; their multiple-display numbering remains unverified. State writes are atomic and serialized off the main thread, and quit flushes pending writes.
- Logging uses unified logging with subsystem `minitile`.
- Threads:
  - the main thread runs the `NSApplication` loop, AX work, the core and the reconciler;
  - the keyboard event tap runs on its own thread and hands commands to the main thread;
  - the socket server reads on a background queue and does the same.

  If hung apps stall the main thread in practice, AX calls move to per-app threads, as AeroSpace does.

## Development and testing

- Core and IPC have unit tests run with `swift test`. They need no permissions and never touch windows.
- The shell is tested live. Automated runs use a temporary config with `only_apps = ["com.apple.TextEdit"]` and TextEdit windows the test opens itself, so the user's windows are never moved or closed. A smoke script drives minitile through `mntl` and checks `mntl --json state`.

`scripts/smoke.sh` compares the requested scene with raw WindowServer spaces and AX frames, checks invalid-config retention and restart persistence, and writes reports under `build/smoke-*`. Its temporary `MINITILE_SMOKE_DIRECTORY` restricts new window discovery to document URLs directly inside that directory. Unsaved Cmd+N documents have no matching document URL and are deliberately ignored, so they remain unmanaged during smoke runs. Without this test restriction, an unsaved document is eligible for normal discovery and placement. On restart, `MINITILE_SMOKE_WINDOWS` permits startup stash acquisition only for test-observed ID/pid pairs. These are test-harness restrictions in addition to `only_apps`. Cleanup closes only the test's documents, stops the test manager, preserves files if cleanup fails, and quits TextEdit only if the test started it and it has no remaining layer-0 windows. State-assertion failures capture health and cached desktop topology before cleanup.

The automatic smoke run passed with five TextEdit documents on one 2056x1329-point display, whose visible frame was 2056x1290 at y=39. It exercised page navigation, nudge, workspace carry and empty-workspace creation, hide/show, floating toggle, swap, close and invalid-config retention. Native desktop membership and tiled frames were checked after state assertions, with a 20-point tolerance. The final four-window snapshot matched all 16 frame components exactly. Restart preserved five window assignments across two workspaces and three pages, including the alternate layout and ratios 0.4/0.7; the normalized grid snapshots were identical. Both stashed windows yielded AX handles on the first discovery pass. Cleanup removed the temporary directory, and the current desktop remained 1 with the same visible/stash pair, 1/1176. The timing report was an idle reconciliation and does not measure page-flip latency.

`scripts/smoke.sh --interactive` prepares five test documents and pauses for real input, recording the user's observation, watch events and before/after state before cleanup. Physical Ctrl+arrow navigation and Mission Control/App Expose suppression are verified. The traced run recorded 25 key-down commands and 25 releases, including 12 Ctrl+Shift commands across all four directions and a Ctrl+Right drag command with an explicit window ID; all 25 commands succeeded. The user also confirmed tiled resize with neighboring tiles adjusting, drag-to-swap, Cmd+Tab restoring a hidden page and a trackpad swipe bouncing back to the visible desktop. Final native placement passed, with zero error across all 20 frame components for five windows. Cleanup removed the temporary directory and left desktop 1 current; the visible/stash pair was 1/1244.

Interactive runs enable `MINITILE_TRACE_KEYS=1`. The app writes `minitile: key` JSON records to stderr for Ctrl+arrow events and their releases, including raw modifier flags, routing decisions, commands, engine focus, suspension reasons and command results. Other typing is excluded, and logging runs on the main queue rather than the event-tap thread. `debug health` exposes `key_trace_enabled`; an interactive run rejects an older bundle without tracing. The report saves the effective bindings in `config.json`. A run with only one native desktop exited before opening documents; the runner now prints each display's unmanaged reason instead of failing silently. The traced retry passed without a shortcut behavior change; an earlier reported failure was not reproduced.

`scripts/smoke.sh --displays` starts with the external monitor unplugged and five isolated TextEdit documents on the laptop. It requires the position indicator and rejects older bundles that lack it; `debug health` reports its display count as `grid_indicator_displays`. It prompts for connection and two desktops on the new display, then places two documents on the laptop and three across two external pages. It checks that flipping either display preserves the other's scene, asks for Cmd+Tab activation with both displays' TextEdit pages hidden, and captures native placement throughout unplug and reconnect. The original grids, including page views, must compare equal after reconnect. The model fixture passes; the native multi-display run is pending.

Unified logs show a menu action followed by normal application termination before the keyboard run's final response, matching Quit Minitile; the resulting missing socket prevented final capture and cleanup. The prompt now makes clear that minitile must remain running until cleanup finishes. `--cleanup TEST_DIRECTORY` reopens a preserved test session to close its documents, retaining files if known windows remain or the manager is unavailable. It accepts only saved smoke directories directly inside TMPDIR and restricts stash recovery to saved window ID/pid pairs. A live recovery run succeeded after the test windows were already closed: both managed and raw window lists were empty, the temporary directory was removed, and desktop 1 remained current. Recovery with still-open stashed windows remains unverified live. `--no-build` reuses an already signed bundle when no application code has changed.
- Running minitile over every app rearranges the user's desktops, so the first such run needs the user's go-ahead.
- `dev/spikes/` holds the throwaway programs that validated the primitives, with their logs. They are reference code for SkyLight, focus, activation pre-emption and the event tap, not a base to build on. Upstream sources: yabai `src/misc/macho_dlsym.h` and `src/space_manager.c`.

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
- activation pre-emption.

Maybe: trackpad swipes that switch pages the way they switch desktops. This needs a test that the event tap can catch the gesture events.

Not planned:

- focus-follows-mouse;
- focus borders and dimming;
- an interactive overview;
- live drag previews;
- saved layouts;
- a URL scheme (status bars can use `mntl watch`);
- a settings GUI;
- animations.

## Open

- Multiple displays, to be tested with the user's second monitor:
  - each display's stash works on its own: moves and page flips on one display leave the other alone;
  - activation pre-emption when the app's window sits on the other display's stash;
  - what macOS does with a disconnected display's desktops and the windows on its stash, and whether they come back on reconnect.
