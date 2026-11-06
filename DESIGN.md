# minitile design

minitile is a tiling window manager for macOS. It runs with SIP enabled and aims for a small core that blends with macOS: a handful of keys that reuse the native desktop shortcuts, mouse gestures where macOS users already use the mouse, and every function scriptable from the `mntl` command line tool. HyprMac (github.com/zacharytgray/HyprMac) is a source of macOS behaviour to respect, not a feature list to copy.

Status: the core, IPC, `mntl` and the macOS shell are implemented and verified live on one display. Multiple displays and the items under "Open" are not yet verified. Page transitions, Cmd+\` window cycling and page miniatures in the position indicator are implemented and unit tested but not yet tried on screen; the transition mechanism was validated in a spike. Trackpad swipes are implemented and unit tested; the swipe mechanism was validated in a spike. The Cmd+Tab window switcher is implemented and unit tested but not yet tried on screen. Keyboard resizing and the mirrored and stacked three-window layouts are implemented and unit tested. The drop picker is implemented and unit tested. The grab highlight is implemented and unit tested but not yet tried on screen. The help screen and Cmd+H takeover are implemented and unit tested but not yet tried on screen; its keycaps and sticky behaviour, the framed mark, the text-only menu bar item and the trimmed menu are built and unit tested but not yet tried on screen. The dark wireframe visual style with lit neon lines is implemented; its look on screen is not yet confirmed. Crossing to another display past the edge of the grid is implemented and unit tested but not yet tried on screen. The window switcher across displays and the monitor markers are implemented and unit tested but not yet tried on screen. The app icon and the styled disk image are built but not yet seen on screen. The second-desktop notice and the menu's setup advice are implemented and unit tested but not yet tried on screen. Background discovery and the input wait diagnostics are implemented and unit tested; their effect on screen is not yet confirmed.

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

### Visual style

minitile's own panels (the position indicator, the window switcher, the help screen, the drop picker and its preview, the grab outline and the second-desktop notice) share the wireframe style of the website and `BRAND.md`: dark, translucent, minimal and drawn with fine lines. Light comes from lines: structure (panel borders, pages, tiles, plates, monitor markers) is unlit wire, and only state (the shown page, the highlighted tile, the drop preview, the grab outline and the desktop the second-desktop notice asks for) is a lit neon line.

- Palette, in sRGB: void `#05070c` for the panel tint and plates, wire `#7d9cc9` for every unlit line, always at an opacity, ink `#e8f0fc` for primary text, dim `#8e9cb4` for secondary text, neon `#53e9ff` for state only, and neon core `#dcfbff` for the stroke of a lit line.
- Panels are always dark, whatever the system appearance: a blurred, translucent background tinted void at 60% opacity, a 0.5 pt wire border at 28% and corners rounded to 12 pt.
- Pages are wireframe outlines: 0.75 pt wire at 45% opacity, and at 20% for empty pages. The shown page is a 1 pt lit line.
- Tiles are hairline wireframes: 0.5 pt wire strokes at 50% opacity over a wire fill at 5%. The highlighted tile (the focused window in the indicator, the selection in the switcher, the hovered slot in the drop picker) is a 1 pt lit line over a neon fill at 12%.
- A lit line is drawn like a neon tube: a neon core stroke with a neon halo at 85% behind it, in two passes, one blurred 6 pt for the soft light around the line and one blurred 2 pt for its coloured edge, since a single blur of a thin line is either too faint or too tight. The halo fades out about 6 pt past the line.
- App icons stay in the tiles, since they are how windows are recognised, at 70% opacity except on the highlighted tile. The dimmed icons of reserved slots are at 40%.
- Text uses ink for headers and dim for secondary text; the indicator's "Active" is neon. Labels (W and P indices, counts, positions, the cropped note, display names in monitor markers and the switcher's header, and chords on the help screen) use the system monospace font.
- The drop picker's preview and the grab outline are lit lines: the preview 1.5 pt over a faint neon fill, the grab outline 2 pt around the window's tile.
- Sizes: the position indicator's cells are 128x80 pt and the switcher's and the drop picker's 256x160 pt, all at scale 2, with icons, text and spacing scaled to match; strokes and halos stay in points. A panel larger than its display's usable area, less 16 pt on each side, is scaled down to fit.

The style is one definition in the shell (`PanelStyle`): the palette, stroke widths, the glow of lit lines, opacities, corner radii and fonts. Each panel's view sits on an `NSVisualEffectView` with the HUD material, behind-window blending, the dark Aqua appearance and an always active state, since the panels never become key; it is masked to the panel's rounded corners, the view lays the tint and the border over it, and the panel window's appearance is dark too. Strokes are drawn just inside their tile, cell or panel. A lit line is stroked once per pass with an `NSShadow` of zero offset as its halo, wide pass first; the core is opaque, so each pass's halo stays under it. Core Graphics blurs a shadow only within the clip, so a lit outline with room for a middle is drawn in four bands along its edges, the two horizontal ones holding the corners, and a window-sized outline does not blur its middle; the result is the same as drawing it whole. A panel that draws a lit line at its edge extends past the line by the halo's 6 pt. Pages have no fill. Floating count badges, floating trays and the row of reserved icons sit on plates of void at 92% with a 0.5 pt wire stroke at 50%; a selected tray icon gets the highlighted tile's line and fill. Headers (the display name, the selected app, the help screen's title and group headings) are ink semibold. The emphasized row and column labels are ink semibold and the others dim; the indicator's "Active" is neon text, unlit; floating counts, positions and the cropped note are dim. Text other than labels uses the system font with tabular digits: window titles and the help screen's descriptions in dim. Chords are ink with 1.5 pt of extra room after each modifier symbol and arrow, which are wider than the monospaced advance; the help screen's gesture rows are phrases rather than chords and use the system font. The preview is a neon fill at 8% under a 1.5 pt lit line, with corners rounded to 10 pt and a 1 pt void keyline at 50% just outside the line, drawn over the halo so the outline keeps a dark edge over light windows; its panel extends 6 pt past the frame it previews. The grab outline is a 2 pt lit line, wider than the preview's since it has no fill to carry it (see "Grab highlight").

Sizes come from per-panel metrics. The drop picker is at scale 2 with the switcher's cell size: cells of 256x160 pt of area, 24 pt apart, with tile icons of 32-64 pt. The indicator and the switcher are at scale 2: the indicator's cells have 128x80 pt of area, 12 pt apart, with tile icons of 20-28 pt and reserved icons of 20 pt; the switcher's have 256x160 pt, 24 pt apart, with tile icons of 32-64 pt, reserved icons of 28 pt and tray icons of 32 pt. Margins, label sizes, text, badges, trays and the corners of pages (4 pt at scale 1) and tiles (2 pt) follow the scale, so the indicator's and the switcher's headers are 24 pt and their row and column labels 20 pt. A panel whose size exceeds its display's usable area less 16 pt on each side is scaled down uniformly, all but its strokes and halos, to the largest scale that fits, found by bisection since cells round to whole points; scaled icons stay on whole points. On a 1512x945 pt usable area the indicator's 4 by 5 grid fits at full size and the switcher's is drawn at about 1.94. The switcher's arrows measure its cells at full size, so scaling does not change where they go. The help screen keeps its size and fits by columns as described under "Help screen".

Untested in minitile: the panels on screen, including the blurred backdrop, the hairlines, halos and colours over real desktops, the preview and the grab outline over light and dark windows, and scaled-down panels on small displays.

### Position indicator

When a display's shown page or workspace changes, that display shows a read-only grid in the upper-right corner of its usable area for 1.5 s, then hides it. Another change within that time shows the new position and restarts the 1.5 s.

The first managed view after startup or display attachment also shows the indicator. Changes to focus, window counts or page indices alone do not restart it: the comparison uses workspace and page identities. A command that crosses into another display (see "Crossing displays") shows it on that display for 1.5 s even when its position stays the same. Unmanaged-display warnings remain in the menu.

- The header names the display and the current workspace and page.
- Workspaces are rows labeled W1, W2, and so on; pages are columns labeled P1, P2, and so on.
- Each cell is a miniature of its page, about 128x80 pt in the proportions of the display's usable area, so portrait displays get tall cells. Its tiles are the core's layout of the page, shown or not (window count, variant and ratios, with gaps and padding scaled down), each holding its app's icon at 20-28 pt, smaller only when the tile is. Minimized and app-hidden windows have no tile, since their page re-tiles without them; their reserved slots show as dimmed app icons along the cell's bottom-left corner. Floating windows show as a count badge on the cell's top-right corner. An empty page is an empty outline.
- The shown page's cell is highlighted, including an empty page, and so is the focused window's tile when it is on that page.
- At most four rows and five columns are drawn, centered on the current position where possible. A cropped grid keeps its full indices and says it is cropped.
- Toward each managed display on a side, found as for crossing (see "Crossing displays"), a monitor marker sits in the middle of the panel's edge on that side: a small wire outline of a screen with a chevron pointing out of the panel, and the display's name in dim monospace beside it. It is unlit wire, since it shows where Ctrl+arrows cross, not state, and the panel makes room for it.
- The grid passes mouse input through, never takes focus, appears on whichever native desktop is current, and uses minitile's dark visual style.

It is an orientation aid, not an interactive overview; the window switcher below is the keyboard-driven view of the same grid.

Cells keep the area of 128x80 pt at any aspect ratio, clamped to 3:1 either way. Tile frames come from the same layout function as the scene, with the config's gaps and padding, and are scaled into the cell on half-point edges; each tile is inset by half a point so neighbours stay apart where scaled gaps fall below a point. The floating count includes minimized floating windows. App icons come from the running application and are cached per pid until no managed window has that pid. The panel is sized from the number of drawn cells, with a minimum width for the header, and is scaled down when it would not fit its display (see "Visual style").

Monitor markers come from the core's neighbour rule for crossing, run over the model's displays, and are named with `NSScreen.localizedName`. At scale 1 a marker is a 16x9 pt screen outline with corners of 1.5 pt on a stand 3 pt tall, and a chevron 8x4 pt (4x8 pt on the sides) pointing out of the panel between the outline and the edge, all in unlit wire at 60% and 1 pt, with the display's name in dim monospace at 9 pt; its lengths follow the panel's scale like the rest of its layout, and its strokes stay in points. The panel adds a band on each side with a marker: 24 pt on the top and bottom edges, where the outline is centered on the edge and the name follows it on the right, and 56 pt on the left and right edges, where the chevron and outline are centered in the band at mid-height with the name centered on one line under them, truncated when longer. The header, labels and cells keep their layout inside the bands. The switcher draws the same markers for the display on view.

### Window switcher

Cmd+Tab opens a window switcher in place of the native app switcher. It moves a selection over the windows of every managed display and shows one display's grid at a time, as page miniatures in the middle of that display's usable area: the grid of whichever display holds the selection. It opens in the middle of the active display's usable area; when the first selection is on another display, as after the last window of the active display, it slides on to that display at once.

- The windows form a ring: displays in arrangement order (by the top edges of their frames, then their left edges), and on each display its grid order: workspaces top to bottom, pages left to right, and on each page its tiles in reading order (top to bottom, then left to right) followed by its floating windows. Pressing Cmd+Tab selects the window after the focused one in the ring, and Cmd+Shift+Tab the one before it; with no managed window focused they start at the first or last window. While Cmd is held, Tab and Shift+Tab step forward and back around the ring.
- The arrow keys move the selection to the nearest window in that direction on its display's grid, first on its page, then on neighbouring pages and workspaces. Empty pages are skipped. Where no window lies in that direction and another managed display lies on that side, found as for Ctrl+arrows (see "Crossing displays"), the selection crosses to it: to the window on that display's shown page nearest the edge it entered from, or with none there, to the window nearest that edge on the display's whole grid. A display with no window to offer is not crossed to. Arrows do not wrap.
- Releasing Cmd, or pressing Return, focuses the selected window and shows its page, with the usual slide; a window on another display also makes that display active. Esc closes the switcher without changing anything.
- When the selection moves to a window on another display, by Tab or by an arrow, the panel slides from the middle of the old display's usable area to the middle of the new one's in 0.25 s, taking the new display's size, and its content changes to that display's grid. A key pressed during a slide sends it on from where the panel is. With Reduce Motion, or `transition_ms` at 0, it moves without sliding.
- The panel carries the same monitor markers as the position indicator, on its edges facing the other managed displays, so a crossing arrow is visible before it is pressed.
- A quick Cmd+Tab, released within about 150 ms, switches straight to the next window in the ring without showing the switcher.
- The switcher covers the managed windows of every managed display: tiled and floating windows, without minimized and app-hidden ones. Running apps with no managed window are not in it; the Dock and Spotlight reach them. With no window to offer, Cmd+Tab does nothing.
- Cells are about twice the size of the position indicator's (256x160 pt in the usable area's proportions), with app icons in the tiles. Floating windows show as icons in a tray along the cell's top edge, so they can be selected. The selected window is highlighted, as is the shown page of the display on view, which on the active display holds the current focus. The header names the selected window's app and title and its workspace and page, and its display's name when more than one display is managed. At most four rows and five columns are drawn, centered on the selection; a cropped grid keeps its full indices and says it is cropped.
- The switcher never takes focus. While it is open, the key event tap swallows Tab, the arrows, Return and Esc and routes them to it, whatever modifiers are held; Tab, Shift+Tab and the arrows repeat while held. Every other key and binding is swallowed while it is open, so Cmd+Q or Cmd+W never reaches the app behind it; switcher bindings still step it, and a `help show` binding replaces it with the help screen.
- It is opened by the `switcher next` and `switcher prev` commands, bound to Cmd+Tab and Cmd+Shift+Tab. Through a key binding it stays open while the binding's modifiers other than Shift are held. Opened without a held modifier (from `mntl`), it stays open until Return or Esc, or `switcher commit` or `switcher cancel`. While it is open, `switcher next` and `switcher prev` step it, from a binding or `mntl`.
- When minitile is not started or is suspended, or no managed display has a window to offer, Cmd+Tab passes to macOS and shows the native app switcher. Binding `"cmd+tab"` to `""` restores the native app switcher. Suspension and quitting close an open switcher without changing anything.

The ring is fixed when the switcher opens. Tiles in the same row of a page are ordered left to right by their frames' left edges; rows by their top edges. While it is open, the switcher follows model changes: a window that closes, is minimized or hidden, or leaves the managed displays drops out of the order, a new window joins at its end, and when the selected window drops out, the next one in the order takes its place. A display that becomes unmanaged drops its windows out of the order; one that goes away hands its workspaces to the primary display (see "Displays"), so its windows stay in the order there. Either way the panel moves to the display holding the selection. It closes without changing anything when no window is left. An arrow picks the nearest window center in the direction's half-plane (more than 1 pt away along that axis) across the switcher's whole grid of cells, drawn or cropped, with grid order breaking ties; a floating window's position is its tray icon. Since tiles on the same page are nearest, an arrow can stay on the page where a neighbouring page or workspace lies in that direction too, as Up from a page's large tile reaches the tile beside it. A crossing arrow measures the display crossed into in the same cell geometry: entering from below it picks the window whose centre is lowest, from above the highest, from the left the leftmost and from the right the rightmost, with grid order breaking ties.

Cells use the indicator's miniatures at 256x160 pt of area, clamped to 3:1 either way, with 24 pt between cells. App icons in tiles are 32-64 pt, never larger than the tile. Reserved slots of minimized and app-hidden tiled windows show as dimmed icons as in the indicator and cannot be selected; the tray leaves out minimized and app-hidden floating windows. Tray icons are 32 pt, centered on the cell's top edge and right-aligned, and shrink when the row would not fit the cell. The selected tile or tray icon is highlighted with a lit neon line, the cell of the display's shown page is outlined with one, since a crossing arrow lands there, and the selection's row and column labels are emphasized (see "Visual style"). The header's display name is dim monospace, right-aligned on the title's row under the position.

The panel is borderless, non-activating and click-through, cannot become key or main, joins all Spaces including fullscreen ones, uses minitile's dark visual style, and is centered on the usable area of the display holding the selection, sized and scaled down for that display as when it opens there. It slides by moving its window's origin on a 120 Hz timer, eased in and out, so the slide needs no Screen Recording permission and does not redraw the panel; the panel changes size and content before it starts moving. Its level is the pop-up menu level, above the position indicator (`.floating`), the page-transition overlays (one below it) and other apps' floating windows. Committing orders the panel out, then runs `window focus ID` through the normal command path, so the panel never appears in a transition capture and the page slides in.

Keys: a bound `switcher next|prev` opens a session in the keyboard tap's router that remembers the binding's modifiers other than Shift, and a flags-changed event without one of them commits. Each swallowed press has its key-up swallowed too. Opened by a binding, the panel shows after 150 ms, so a release before then commits without it appearing. Before the panel shows, and every second while a binding's switcher is open, the shell rereads the modifier state (`CGEventSource.flagsState`), so a release the tap missed, as while macOS had it disabled, still commits. `mntl switcher next|prev` opens a session without modifiers. Router decisions reach the main thread asynchronously and carry their session, so keys for a switcher that has since closed are dropped. The router keeps the availability flag (started and not suspended, with a window to offer on some managed display) under its lock, and the main thread updates it at start, on every model change, on every suspension change and on quit.

`switcher next|prev` fail when no managed display has a window to offer, and `switcher commit|cancel` when the switcher is not open; `switcher commit` replies with the reply of `window focus ID`. `mntl debug health` reports `switcher_open` and `switcher_selected` (see "Command line: mntl").

Untested in minitile: the panel on screen, key routing with physical keys, the quick Cmd+Tab, Shift+Tab, detecting the Cmd release, and the switcher and the monitor markers across displays, including how the slide looks at the boundary between displays, since with "Displays have separate Spaces" macOS shows a window on one display at a time, and whether the panel stays on all Spaces after moving to another display.

### Grab highlight

When a key binding moves or resizes the focused window (Ctrl+Shift+arrows to nudge or carry it, Cmd+Option+\` to swap it with a neighbouring slot, Ctrl+Option+arrows to resize it), minitile outlines that window so it reads as held.

- The outline is a rounded lit neon line (see "Visual style"), drawn by a click-through panel around the window's tile, or around its frame when it floats. It never takes focus, shows on whichever desktop is current, uses minitile's dark visual style, and sits above normal windows but below the page-transition overlays, the position indicator, the window switcher, the help screen and the drop picker.
- It stays while every modifier of the binding that started it is held, and goes when one is released, so holding Ctrl+Shift is holding the window. Further moves and resizes while it is held keep it on the same window.
- It follows the window to its new tile after each move. When a move shows another page with a slide, it hides during the slide and returns on the window's new tile when the slide ends.
- A move or resize from `mntl` or the menu, with no modifier held, shows it for about 1 s.
- It ends early when the window closes, is minimized, hidden or ordered out, or loses focus to another window, on suspension and on quit. Mouse drags never show it, including Ctrl+arrow while dragging, since the pointer already holds the window.

Commands: `window nudge [ID] left|right`, `window move [ID] left|right|up|down`, `window move [ID] workspace prev|next` and `window resize [ID] left|right|up|down` grab; other moves (`window move ... page|display`, `swap`, `place`) and resizes by share or size do not. A grabbing command acts on its window ID, or on the window focused before it ran. One that fails leaves the grab as it is. One that succeeds without changing the model (a nudge toward the edge from the first or last page or a carry above the first workspace with no display on that side, a resize with no cut to move or already at its limit) starts no grab and leaves a grab of another window alone; on the grabbed window it counts like any other grabbing command. Commands that do not grab leave the grab alone, so after Ctrl+Option+Space the outline follows the held window to its new tile. A grabbing command on the window being dragged never grabs, and a drag that begins ends the grab.

Lifetime: the keyboard tap's router opens a grab session when a grabbing binding with modifiers fires and remembers all of its modifiers, Shift included; a flags-changed event without one of them ends the session. Further grabbing presses with the same modifiers, and the key repeats of a directional resize, continue the session. A binding's command carries its session to the main thread, and a release ends the grab only if the grab still belongs to that session. Every second the shell rereads the modifier state (`CGEventSource.flagsState`) and ends a held grab whose session the router no longer holds, so a release the tap missed still ends it. A grabbing binding without modifiers, `mntl` and the menu start a timed grab, which ends 1 s after its last grabbing command; such a command on a window a binding holds leaves it held. A grab also ends when its window leaves the model, is minimized, app-hidden, explicitly hidden or ordered out, or when the model's focus moves from what it was at the last grabbing command to a window other than the grabbed one, or to none. A grab of a window that did not have focus, as `mntl window resize ID left` makes, lasts while focus stays put or moves to the grabbed window. The window switcher does not end a grab, though committing it usually moves focus, which does.

Placement: the outline goes on the window's tile in the scene the reconciler last applied, so during a held reconcile it stays where the window still is; a floating window uses its frame in the model, the latest observed or explicitly resized one. It shows only while the window is on its display's visible desktop with a tile or floating frame there. The line is 2 pt wide and lies just outside the tile, from the tile's edge into the gap between tiles (half of the default 8 pt gap), with corners rounded to 12 pt at the tile's edge so the line stays concentric with the tile's corner; the panel extends the halo's 6 pt past the line, so the halo is not clipped. It hides while transitions cover its display: from a command whose slide captures that display until the display's overlay goes away, and while a bounce runs there. Transitions report each overlay that goes away, and the outline then returns on the window's current tile. The panel is borderless, non-activating and click-through, cannot become key or main, and joins all Spaces. Its level is two below `.floating`, under the page-transition overlays (one below) and the drop picker's preview, so an overlay covers it even before it hides; transition captures leave it out with the rest of minitile.

`mntl debug health` reports `grab_window`, `grab_held` and `grab_visible` (see "Command line: mntl").

Untested in minitile: the outline on screen, its placement and look during and after slides and bounces, and detecting modifier releases with physical keys.

### Help screen

Cmd+H shows a help screen in place of hiding the frontmost app. Hiding an app keeps its windows' slots reserved, so its pages stay but look empty; taking over the shortcut avoids that in the common case. Hiding through the app menu or the Dock still works and still reserves the slots. Cmd+Option+H (Hide Others) is swallowed and does nothing.

- The screen follows the website's shortcut table (see "Content"): one row per action, with the site's description, an optional detail line, and the keys as keycaps named as on the site. It lists the current key bindings, read from the merged config so it matches any rebinding. A short section lists the mouse and trackpad gestures: swipes, edge and corner drags, swaps, the drop picker and Ctrl+arrow while dragging.
- Keys are keycaps with names, not symbols: the modifiers Control, Option, Shift and Cmd, in that order, then the key. A pair of directions bound with the same modifiers shares one keycap, Left / Right or Up / Down, and all four arrows read Arrow keys; single arrows are Left, Right, Up and Down. Other keys: Space, Tab, Return, Esc, Backtick, letters as capitals and function keys as F1 and so on. Keycaps are drawn like the site's: a rounded wire outline over a glass fill with a faint inner bottom edge, and ink monospace text.
- It opens in the middle of the active display's usable area, in the same style as the window switcher, never takes focus, shows on whichever desktop is current and uses minitile's dark visual style.
- Once open it stays until Esc, a click anywhere outside it, or its binding again (Cmd+H toggles it). Clicks on the panel do nothing; a click elsewhere closes it and still reaches what it was on. Other keys and bindings pass through while it is open, so shortcuts can be tried with it on screen. The menu bar's Help item and `mntl help show` open it the same way.
- Cmd+H is swallowed in every app while minitile runs, managed or not, so it always means help. When minitile is not started or is suspended, Cmd+H passes to macOS. Binding `"cmd+h"` to `""` restores hiding.
- The help screen and the window switcher are never open together: opening one closes the other.

Content: the rows follow the website's shortcut table, in its order and with its words. Pages run sideways and workspaces up and down, but that is how minitile stores the grid, not something the user needs: the arrows simply move around it, so one row covers both. The rows: Move around (`page prev`, `page next`, `workspace prev` and `workspace next`, as left, right, up and down), Move a window (`window nudge left|right` or `window move left|right`, and `window move workspace prev|next` or `window move up|down`, as left, right, up and down), Resize a window (`window resize left|right|up|down`), Cycle layouts (`page variant`), Find a window anywhere (`switcher next`, detail "Hold Cmd, choose with Tab or arrows, then release to jump."), Cycle windows on this page (`window focus next`), Swap a window with its neighbour (`window swap next`) and Show every shortcut (`help show`, detail "Press Esc or click anywhere else to close."). A row shows the chords bound to its commands. The four directions of a row bound with the same modifiers share one row and one keycap, Arrow keys; otherwise each opposite pair that shares modifiers gets a row with a Left / Right or Up / Down keycap, and a lone direction a row of its own, with the directions in the description, as in "Move around (left)". A Shift variant that runs the reverse command (`switcher prev`, `window focus prev`, `window swap prev`) adds the detail "Add Shift to go back." instead of a row of its own. Pairs rebound to other keys name those keys in the shared keycap; a partial resize can still combine an opposite pair. A row with nothing bound is left out. `ignore` bindings are not listed. Other bindings follow under an "Other" heading, one row per chord: known commands with a plain description (Focus window to the left, Toggle floating, and so on) and others with their command text. The gesture section comes last, under "Mouse and trackpad", and lists the swipes only while `trackpad_swipes` is true; edge and corner drags, swaps, the drop picker and Ctrl+arrow while dragging are always on. The content is read from the config each time the screen opens.

Panel: a "minitile" title, then the rows of description and keycaps, then the "Other" and "Mouse and trackpad" headings with their rows, in the window switcher's panel style. It is sized to its content: one column when that fits the usable area less 16 pt on each side, otherwise as few columns as fit, with their heights balanced. A section moves to the next column whole when it fits there, a taller one splits between rows, and a heading always keeps a row below it. Content that does not fit even in columns, such as a long list of custom bindings on a small display, is clipped to the usable area. The active display is the one a command without an address acts on, as for the switcher; without a managed display, the panel goes on the main screen. The panel is borderless and non-activating, takes clicks on itself without becoming key or main, and joins all Spaces including fullscreen ones. Its level is the window switcher's, the pop-up menu level. While it is open, a global mouse-down monitor closes it on clicks in other apps; a local monitor does the same for clicks in minitile outside the panel and returns the event unchanged.

Keys: the keyboard tap's router holds at most one open screen, the window switcher or the help screen, with sessions from one counter, so opening either replaces the other in the router, and the main thread then closes the one replaced without changing anything. A bound `help show` toggles the screen: it opens it, or closes it when it is open; the binding is swallowed with its key-up, and key repeats are swallowed without toggling again. Releasing modifiers does nothing. While it is open, Esc closes it and is swallowed with its key-up, and every other key, binding and shortcut passes through as if the screen were not there, except that a switcher binding opens the window switcher in its place when the switcher has a window to offer; a `help show` binding while the switcher is open likewise cancels the switcher and opens the help screen. The router keeps the help screen's availability flag (started and not suspended) beside the switcher's, and the main thread updates both at start, on every suspension change and on quit; suspension and quitting close an open help screen.

`mntl help show` is answered by the shell: it opens the screen as Cmd+H does, and does nothing more while it is open. It fails while minitile is suspended. `mntl debug health` reports `help_open` (see "Command line: mntl").

Untested in minitile: the panel on screen and its columns, swallowing Cmd+H and Cmd+Option+H in real apps, including apps that handle them themselves, and closing on clicks outside the panel.

### Placement

- A new window goes to the workspace being viewed. It takes the first free slot, scanning from the current page to the right; if none is free, it goes onto a new page at the end of the workspace.
- If a new window from the frontmost app lands on a page that is not shown, that page is shown, since macOS focuses such windows. Windows from background apps are placed without changing the view.
- When a window closes, the remaining windows on its page re-tile, and the freed slot is reused by the next new window. Windows never flow back from later pages.
- When focus moves to a window on a hidden page by any means (the Dock, a notification, `mntl window focus`), that page is shown. For 1.2 s after a command changes the shown page, such reports are ignored: the app that was frontmost can still report the window minitile just hid as focused, and following it would undo the navigation. Activation still shows an app's page during that time.
- When an app with no window on a shown page is activated (Cmd-Tab, the Dock), the page holding its most recently focused window is shown. macOS does the focusing. Minimized windows do not count as being on a shown page; windows of a hidden app do, since activation unhides them. See "Rules minitile must follow" for the timing.

### Navigation and focus

- Showing a page focuses the window that last had focus on it, or its first window. An empty page focuses nothing.
- When the focused window closes, is minimized or ordered out, or its app is hidden, minitile does not focus another window. macOS picks the next one, and minitile follows it.
- Ctrl+Up/Down (`workspace next|prev`) shows the page at the same position in the workspace above or below. If that workspace ends exactly one page short of the position, an empty page opens there, as Ctrl+Right from its last page would; if it is shorter still, its last page is shown. `workspace show` by index shows the page last viewed in that workspace.
- Ctrl+Right on the last page opens an empty page, and Ctrl+Down on the last workspace opens an empty workspace. Neither opens a second empty one next to an empty one.
- Past the edge of a display's grid, Ctrl+arrows cross to the display on that side: Ctrl+Left from the first page, Ctrl+Up from the first workspace, Ctrl+Right from an empty last page and Ctrl+Down from an empty last workspace. Where no managed display lies on that side, they do nothing.
- A window opened while an empty page or workspace is viewed lands in it. An empty page or workspace is removed when the view leaves it.
- Pages are otherwise created by spill and by nudging a window out of a shared page (see Keys).

Crossing displays:

- The display on a side is found from the display frames (`DisplayInfo.frame`, in global coordinates): its facing edge lies on this display's edge on that side, within 1 pt, and the two edges overlap by more than zero, so displays that only touch at a corner are not neighbours. With several, the one with the longest overlap wins, then the one whose centre is nearest. Unmanaged displays are never crossed to or from.
- Crossing makes that display active and changes nothing it shows. Its shown page keeps showing and its window that last had focus there gets focus, or its first window; an empty page focuses nothing. The position indicator shows on the display crossed into.
- Ctrl+Shift+arrows carry the focused window across where moving it would otherwise change nothing: a nudge of a window alone on the first or last page toward the edge, a carry up from the first workspace, and a carry down from a last workspace it is alone in, with no other window on any of its pages, floating and reserved ones included. The window goes onto the shown page of the display on that side by the placement rules (the first free slot from the shown page to the right, else a new page at the end of that workspace), and focus follows it, showing its page there.
- A display that a crossing leaves showing an empty page or workspace drops it and shows the nearest page instead: the page before it in the same workspace, else the page after it, else the page last viewed in the workspace above, else the one below. This covers both the empty page or workspace that Ctrl+Right or Ctrl+Down opened before crossing and a page a carried window leaves empty. With no other page, the display keeps its empty page.
- A window the mouse is dragging never crosses, since the pointer still holds it: Ctrl+arrows during a drag stop at the edge of its display's grid.
- Navigation crosses whether or not it names a display, and one that names a display crosses from that display. Swipes, which name the display under the pointer, therefore cross as Ctrl+arrows do, and a swipe that crosses moves the pointer to the middle of the usable area of the display it crossed into, so the next swipe continues there. Other crossings leave the pointer where it is.
- The commands that cross are `page next|prev` and `workspace next|prev`, with or without a display address, the nudges `window nudge left|right` and `window move left|right`, and the carries `window move up|down` and `window move workspace prev|next`. `workspace new` and moves to a page, a workspace index or a display never cross. Ctrl+arrow while dragging a window does what Ctrl+Shift+arrow does, short of crossing.
- The core's output names the display a command crossed into (`crossed`); the shell uses it for the position indicator, bounces and the pointer. A crossing emits `focus` when focus changes, `window_moved` for a carried window, and `page_shown` only for a display whose shown page changes: the display left behind when it drops an empty page, and the display crossed into when a carried window spills onto another page there.

Untested in minitile: crossing on screen with two displays, the slide back on the display left behind, the indicator on the display crossed into, what keyboard focus does after crossing into an empty page, where minitile focuses nothing and macOS keeps the window that had focus, and carrying a window across while dragging it.

### Page transitions

The mechanism and its measurements are under "Transition mechanism".

- When a key binding, menu item or `mntl` command changes a display's shown page or workspace, the old page slides out and the new one slides in, like the native desktop switch at about half its speed. Pages slide horizontally and workspaces vertically. Nudge and carry slide too when focus follows the window to another page.
- Where navigation does nothing, the page bounces instead: Ctrl+Left on the first page, Ctrl+Right on an empty last page, Ctrl+Up on the first workspace and Ctrl+Down on an empty last workspace, when no display lies on that side, by key or by swipe. A crossing slides nothing on the display crossed into; a display that drops an empty page or workspace behind a crossing slides back. The page shifts 5% of its width or height the way the slide would start, then springs back, over 0.3 s whatever the slide duration.
- A slide takes 0.5 s by default, set by `transition_ms`; 0 turns slides and bounces off. Reduce Motion also turns them off.
- Other view changes stay instant: activation (Cmd-Tab, the Dock, clicks), new windows, unminimizing, startup and display changes. Activation must not wait, since it races macOS's own desktop switch.
- A command never waits for a running slide. A navigation during a slide cuts it short and starts the next slide from the current screen.
- Each display slides on its own. The position indicator stays above the slide.
- Transitions need Screen Recording permission. Without it they are off, the menu says why, and everything else works. `mntl debug health` says whether transitions run and, if not, why.

### Minimized and hidden windows

- A minimized window keeps its slot, and its page re-tiles without it. When it is unminimized, it returns to its slot and its page is shown.
- Windows of a hidden app (hidden through its app menu or the Dock, since Cmd+H shows the help screen) keep their slots, and their pages re-tile without them until the app is unhidden.
- `mntl window hide` takes a window off its page, freeing the slot, and keeps it on the stash. `mntl window show` places it like a new window on the current workspace and focuses it.
- A window its app takes off screen without closing it (ordered out, as `orderOut:` does) leaves its page, freeing the slot. `mntl` still lists it, with `ordered_out` true and no page; `window info` and `window close` work on it and other window commands fail. When the app shows it again, it is placed like a new window on its display's current workspace.

Untested in minitile: `window close` on an ordered-out window, native window tabs, and panels that hide while their app is in the background.

### Layout

Each page holds an ordered list of windows, its slots. The layout is a fixed function of the window count and the page's variant. Ctrl+Option+Space (`mntl page variant`) cycles a page through its count's layouts in this order:

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

Drop picker:

- While a tiled window is dragged as a move (the mouse button is down and the window has moved beyond the move tolerance without changing size), a layout picker appears in the middle of its display's usable area. It shows each layout for the page's active tiled window count as a miniature, in cycling order: two windows `standard` and `alternate`; three windows `standard`, `mirrored`, `alternate` and `stacked`; four windows the 2x2. With one active tiled window there is nothing to pick and it does not appear. Edge drags (resizes) and floating windows never show it.
- Each miniature's tiles are drop targets. While the cursor is over a tile, the tile is highlighted with the dragged window's app icon and a translucent preview on the page shows the frame the window would get. Releasing the mouse there sets the page's variant to that layout and moves the dragged window into that tile; the other windows keep their relative order in the remaining tiles. Ratios reset when the layout changes, as for any variant change, and stay when only the window's tile changes.
- Releasing anywhere else keeps the behaviour below: a swap with the tiled window under the cursor, or a snap back.
- Browser tab drags keep working: the picker and the preview are click-through and never intercept the drag, and the preview shows only while the cursor is over a picker tile, so it never covers a tab strip. A window torn out of a browser by dragging a tab counts as dragged, so it can be dropped on another window's tile or on the picker. If the dragged window disappears before the release, as when it is dropped into another window's tab strip, minitile does nothing for that drop.
- The picker reflects the page the dragged window is on, including after Ctrl+arrow during the drag. It is click-through and never takes focus; the shell hit-tests the cursor against it while polling the drag. It uses the same miniature drawing as the position indicator and the window switcher.
- The core command is `window place [ID] standard|alternate|mirrored|stacked SLOT`: it sets the variant of the window's page and moves the window to that 0-based tile of the layout. The variant must be one the page's active tiled count cycles through and the tile must exist.

The move test compares the window's frame with its tile when the drag began: within 3 pt in width and height, and more than 3 pt away in x or y. A Ctrl+arrow during the drag changes the tile but not the window, so the picker stays up; a release away from the picker is still judged by the core against the window's current tile. The 30 ms drag poll updates the picker and the preview from the frame the window's move notifications last read, so polling reads no AX attributes, and from the cursor's current event location. On release the shell reads the frame once more and repeats the move test and the hit test. A drop on a picker tile runs `window place ID VARIANT SLOT` through the normal command path; any other release sends the usual drag end to the core. A frame that cannot be read at release means the window went away, and the release does nothing. The picker and the preview hide when the drag ends, when the dragged window goes away, on suspension, which display changes cause, and on quit.

The picker's cells have the switcher's 256x160 pt of area, in the usable area's proportions, in one row 24 pt apart with 24 pt margins, and the panel is centred in the usable area. A row too wide or tall for the usable area less 16 pt on each side is scaled down with its cells, margins and spacing (see "Visual style"), and hit-testing uses the scaled cells. Tiles are empty; the hovered one is highlighted with a lit neon line and holds the dragged window's app icon, and the page's current layout is outlined as the indicator outlines the shown page. Anywhere in a cell counts as its nearest tile, so the target does not drop out in the gaps between tiles. The preview is the lit outline described under "Visual style", at the frame `window place` would lay out: with the page's ratios for the layout the page uses now, with the defaults for any other. Both are borderless, non-activating, click-through panels that cannot become key or main and join all Spaces, including fullscreen ones. The picker's level is `.floating`, the position indicator's, above the page-transition overlays, so a Ctrl+arrow slide leaves it shown; the preview's is one below, the overlays' level.

`window place` counts SLOT among the page's active tiles, the tiles of its layout, while the `slot` field of `window list` also counts reserved minimized and app-hidden slots. The window goes before the active tile now at SLOT, or after the last one, so reserved and floating windows keep their places in the page's list. A page keeping `mirrored` or `stacked` with two windows already uses `standard`, so placing a window in `standard` keeps its ratios. The command shows the window's page, focuses the window and emits `window_moved` for each window whose tile changed. A placement that changes nothing emits nothing and only rewrites the window's frame, which snaps a dropped window back. A floating, minimized, app-hidden or explicitly hidden window has no tile, and placing it fails.

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

Untested in minitile: the mirrored and stacked layouts on screen, keyboard resizing with physical keys, key repeat, the drop picker and its preview on screen, hover tracking during real drags, and browser tab drags in both directions.

## Keys

minitile takes over the Ctrl+arrow shortcuts macOS uses for desktops and Mission Control, and the Cmd+\` shortcut for cycling windows, and gives them the same meaning on its grid. There is no Hypr key and no Caps Lock remap. Closing and quitting stay on Cmd+W and Cmd+Q.

Default bindings:

| Keys | Action | Replaces in macOS |
|---|---|---|
| Ctrl+Left/Right | Show the previous or next page. Past the first page, or past an empty last page, focus the display on that side (see "Navigation and focus"). | Move left/right a space |
| Ctrl+Up/Down | Show the page above or below: same position in the workspace above or below, an empty page when that workspace ends one page short, or its last page when it is shorter still. Past the first workspace, or past an empty last workspace, focus the display on that side. | Mission Control, App Expose |
| Cmd+\` / Cmd+Shift+\` | Focus the next or previous window on the shown page: tiles in reading order (top to bottom, then left to right), then floating windows, wrapping around. | Move focus to next window, which cycles the frontmost app's windows |
| Cmd+Option+\` / Cmd+Option+Shift+\` | Swap the focused window with the window in the next or previous slot on its page, wrapping around; focus stays with it. With two windows this swaps them. | Nothing by default |
| Cmd+H | Toggle the help screen (see "Help screen"). | Hide the frontmost app |
| Cmd+Option+H | Nothing: swallowed so other apps are not hidden. | Hide other apps |
| Ctrl+Option+Space | Cycle the shown page through its window count's layouts (see Layout). | Switch input sources |
| Ctrl+Option+arrows | Resize the focused window: the divider on that side moves the way the arrow points (see Layout). | Nothing by default; VoiceOver uses Ctrl+Option as its modifier |
| Cmd+Tab / Cmd+Shift+Tab | Open the window switcher and step through windows (see "Window switcher"). | App switcher |
| Ctrl+Shift+Left/Right | Nudge the focused window. If it shares its page, it moves onto a new page of its own on that side. If it is alone, it joins the neighbouring page; if that page is full, it joins the next page with room in the same direction, or a new page at that end of the workspace. Alone on the first or last page, it moves to the display on that side. Focus follows. | Select to line start or end in text fields, which Cmd+Shift+arrows also does |
| Ctrl+Shift+Up/Down | Carry the focused window to the workspace above or below, placed by the placement rules. Past the last workspace, it carries the window into a new one. From the first workspace, or from a last workspace it is alone in, it carries the window to the display above or below. Focus follows. | - |

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

Nudging a window that is alone on the first or last page toward the edge moves it to the display on that side; with no display there it does nothing, and a nudge that does nothing emits no event or focus action.

Sharing a page includes floating and reserved minimized/app-hidden windows. A nudge always moves the window in its direction: it never lands back on the page it left.

Mouse:

- Drag a tiled window's edge to resize, drag it onto another tile to swap, or drop it on a slot of the layout picker (see Layout). Edge drags have no live preview.
- Press Ctrl+arrow while dragging a window to do to it what Ctrl+Shift+arrow does. This is how macOS moves a window to another desktop. Frames of a window being dragged are not written until the mouse button is released.
- A move or resize that minitile did not cause, seen while the mouse button is down, is a user drag. minitile acts on release.

Trackpad (the mechanism is under "Trackpad swipe mechanism"):

- The swipe macOS uses to switch desktops and open Mission Control and App Expose (three or four fingers, as set in System Settings) navigates the grid instead. Fingers left show the next page, fingers right the previous page, fingers up the workspace below and fingers down the workspace above. These run the same commands as Ctrl+Right, Ctrl+Left, Ctrl+Down and Ctrl+Up, with the same slides and edge bounces.
- A swipe acts when it ends, if it travelled at least 30% of the way or was still moving fast (end velocity of at least 2). A shorter, slower swipe, or one macOS cancels, does nothing; it still never reaches macOS.
- It acts on the display under the pointer as the swipe begins, as the native swipe does, whichever display has focus. Past the edge of that display's grid it crosses to the display on that side as Ctrl+arrows do (see "Crossing displays"), and moves the pointer there, so the next swipe continues on that display.
- minitile leaves the whole swipe to macOS when, as it begins, the display under the pointer is unmanaged or not showing its visible desktop (for example a fullscreen app's Space), when minitile is not started or is suspended, or when `trackpad_swipes` is false. It also stays with macOS while minitile's swipe tap is unavailable or disabled.
- Mission Control and App Expose stay reachable through their keys and the Dock.

Everything else (floating, spatial focus, exact ratios) is a command: reachable from `mntl` and bindable to keys in the config.

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
- `mntl help show` is answered by the app shell and opens the help screen; `mntl help` alone prints the grammar.
- `mntl ignore` does nothing and replies OK, without changing state or emitting events. Binding a chord to it swallows that chord, which is how Cmd+Option+H is blocked.
- `mntl switcher next|prev|commit|cancel` commands are answered by the app shell, since the switcher is shell UI; committing runs `window focus ID` through the core.
- `mntl debug <verb>` commands are answered by the app shell and expose internals: raw desktops per display, the last applied scene, timings. Debug verbs can be added freely. Every other command is answered by the core.

The shell provides `debug spaces`, `debug windows`, `debug scene`, `debug timings` and `debug health`. Spaces include the native display identifier, every native Space and its type, current Space, and core display metadata. The desktop list comes from the last catalog refresh; current Space is read for each request. Windows include allowed apps' raw layer-0 windows, AX observation status, current spaces, frames and tileability. Scene frame keys are decimal window-ID strings. Health includes process ID, startup/suspension state and reasons, secure input, tap availability, paths and warnings. The menu can open config, retry startup after a config error, or quit while normal command handling is still unavailable.

`grid_indicator_displays` counts physical displays whose indicator state is tracked, including hidden indicators; `grid_indicator_visible_displays` counts currently visible panels, and `grid_indicator_duration_ms` is 1500. `switcher_open` says whether the window switcher is open, and `switcher_selected` is its selected window ID, or null. `help_open` says whether the help screen is open. `grab_window` is the window the grab highlight holds, or null; `grab_held` says whether a binding's held modifiers hold it, rather than the 1 s timeout; `grab_visible` says whether its outline is on screen. `desktop_notice_visible_displays` counts the second-desktop notices on screen, and `warnings` lists the menu's warnings by title, setup advice first. `transitions_enabled` says whether page transitions run, and `transitions_disabled_reason` says why not (`transition_ms` is 0, Reduce Motion is on, Screen Recording is not granted, or screen capture content is not loaded) or is null. `trackpad_swipes` is the configured setting; `swipe_tap_running` says whether the swipe tap exists and is enabled; `swipe_tap_unavailable` says it could not be created or its thread exited unexpectedly. `last_swipe` is the latest swipe that began, or null: its `location` in global points, the `display` minitile took it for (null when it went to macOS) and the `command` it ran (null when none). Timing diagnostics include the last resume's duration (`resume_ms`), the latest key binding or swipe's wait for the main thread (`input_wait_ms`) and the longest since launch (`input_wait_max_ms`), full-scan counts and wall time (`full_scans`, `full_scan_ms`, from the snapshot to the last app's applied result; the three-second scans run off the main thread), recheck requests/passes, and the latest 128 activation-triggered first move submissions. Activation latency runs from delivery of the workspace or AX notification callback through return of the bridged move submission; it does not measure time before notification delivery or completion in WindowServer.

Commands are noun then verb. Windows are addressed by window ID and default to the focused window. Pages and workspaces are addressed by index or `next`/`prev`, and default to the display with the focused window.

| Command | Effect |
|---|---|
| `mntl help` | The command grammar. |
| `mntl state` | Dump the whole model: displays, workspaces, pages, windows and focus. |
| `mntl watch` | Stream events as JSON lines: focus, page shown, window added, removed or moved, display change, config reload. |
| `mntl window list` | List windows with ID, app, title, display, workspace, page, slot, floating and ordered-out state. |
| `mntl window info [id]` | One window in full: where it is (display, workspace, page, slot), shown or hidden, floating, focused, ordered out, app name, bundle ID and pid, title, frame. |
| `mntl window show [id]` | Show the page holding the window and focus it. A hidden window joins the current workspace. |
| `mntl window hide [id]` | Take the window off its page and keep it on the stash until shown. |
| `mntl window move [id] <target>` | Move the window to a direction, page, workspace or display. |
| `mntl window nudge [id] <dir>` | The Ctrl+Shift+Left/Right action. |
| `mntl window swap [id] <id>\|next\|prev` | Swap two tiled windows, or a window with the next or previous active tile on its page. |
| `mntl window resize [id] <size>` | Tiled: set the page cuts so the window gets that share. Floating: set its size. |
| `mntl window place [id] <variant> <slot>` | Set the page's layout and put the window in that tile of it, as dropping it on the layout picker does. |
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
help [show]
ignore
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
window swap [ID] OTHER_ID|next|prev
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

Page and workspace addresses are 1-based; tiled slots are 0-based. Floating and explicitly hidden windows have a null slot. Window IDs are decimal. With no focused window, commands use the most recently selected display, then the primary managed display. `page list` lists the current workspace; `workspace list` lists the current display. An explicit display UUID can inspect an unmanaged display. `info`, `show` and `variant` addresses resolve within the current context; `next`/`prev` in these addresses clamp at the ends. Only navigation commands and window moves create pages or workspaces. `workspace new` appends an empty workspace unless the current one is already empty. `page next|prev` and `workspace next|prev` navigate the display named by a trailing `display UUID` instead of the current context, with the same edge behaviour, crossing from that display past the edge of its grid; the display must be known and managed, otherwise the command fails. Trackpad swipes use this to act on the display under the pointer.

Window moves and swaps follow the addressed source window. A move to its existing page does nothing. Left/right moves are nudges; up/down moves carry between workspaces. Page and workspace navigation, nudges and carries cross to the neighbouring display at the edge of the grid, navigation from the display it names if any (see "Navigation and focus"). Explicit moves to a full page use placement spill. Spatial focus chooses the nearest window center in the requested half-plane on the same page, with grid order breaking ties; it does not wrap. Minimized and app-hidden windows are excluded from spatial focus. Next and previous focus walk the focused window's page with its tiles in reading order (top to bottom, then left to right, by their frames) and then its floating windows, and wrap; they skip minimized and app-hidden windows. With no managed window focused, both focus the first window of the shown page in the current display context. Like `window focus ID`, they emit a focus action. When no other window on the page can take focus, including on an empty page, they do nothing. Swapping with `next` or `prev` trades the window with the active tile after or before it on its page, wrapping around and skipping reserved slots of minimized and app-hidden windows; with fewer than two active tiles it does nothing, and a floating window is an error.

Directional resize moves the window's cuts by 0.05 as described under Layout, or grows or shrinks a floating window by 0.05 of the layout area. For tiled resize, a single share applies along the layout's split axis, the axis r1 cuts: the long axis, except for two windows `alternate` and three `stacked`. `WIDTHxHEIGHT` supplies physical-axis fractional shares; an axis the tile spans whole ignores its share. Cuts are clamped by the layout rules. Floating resize requires `WIDTHxHEIGHT` in positive points and emits an explicit frame-write action. `page ratio R1` leaves r2 unchanged. Config reload is completed by the shell before its socket reply; failures keep the previous config. `config open` opens the config file in the user's editor.

### JSON data contract

Every response has `ok`, `text` and `data`. Errors and successful mutations use null data; inspection commands use the shapes below. Missing addresses, bundle IDs, desktop IDs and focus values are null rather than omitted. Rectangles use `{x, y, width, height}` in global points. `info` text contains one field per line; list text uses aligned columns. Text is for people; scripts should use `--json`.

| Command | Data |
|---|---|
| `help` | Grammar string. |
| `window list`, `window info` | Array of window objects, or one window object. Fields: `id`, `pid`, `bundle_id`, `app`, `title`, `frame`, `display`, `workspace`, `page`, `slot`, `floating`, `hidden`, `focused`, `shown`, `minimized`, `app_hidden`, `ordered_out`, `tileable`. `frame` is the latest observed or explicitly resized frame. `hidden` means explicitly hidden by mntl; `ordered_out` means its app took it off screen without closing it; `shown` also excludes minimized/app-hidden windows and pages not being viewed. |
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
- Display changes are debounced: about 2 s, or 5 s after wake. At wake and at unlock, the shell first compares the displays with its catalog and waits out the debounce only when they changed, so shortcuts work as soon as the screen is on; a monitor that reconnects later still reports a screen change, which is debounced then. Commands are rejected while the debounce runs. False display-change notifications (calls, colour profile changes) are filtered by comparing a fingerprint of the display set.
- While active, the shell also probes native desktop topology every three seconds. Changes to display identifiers or desktop IDs, types and order schedule the same debounced refresh, so creating a second desktop does not require switching to it. The probe ignores the current Space and does not update the catalog before the debounce completes; failed or empty reads retain the last catalog.
- Native desktop switches bounce from the stash, refresh window membership and shortcut blockers, and schedule presence checks without suspending the shell. When the final sleep, session, lock or display interruption ends, the shell refreshes topology, rereads focus and reapplies the current scene.
- When a display goes away, its workspaces are appended below those of the primary display, the one with the menu bar after the change. Each workspace keeps its home display UUID.
- When the home display returns, every workspace tagged with it moves back, including windows opened into it in the meantime. If one of those workspaces is being viewed, the primary display switches to the workspace above it.
- Workspaces created while merged belong to the display they were created on.
- macOS moves a vanished display's windows on its own. minitile ignores where they land and places them from its own state.

If the focused display disappears, focus moves to the primary display's currently shown page after merging. When several returning workspaces precede the viewed one, the host selects the nearest preceding workspace that remains; if none remains above, it selects its first remaining workspace or creates an empty one. If no display can be managed, grids are retained with no scene placement until a managed display returns. A physically present unmanaged display retains its grid but receives no scene and adopts no new windows. Explicitly hidden windows retain their last workspace's home UUID so they use the merged host's stash and can return home later.

## Floating windows

- minitile tiles standard windows: role `AXWindow`, subrole `AXStandardWindow`, not modal, with a settable size.
- Everything else floats, along with windows set floating through `mntl window float` or a key binding for it, and apps on the always-float list in the config. Popups are not managed at all (see "Discovery").
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
- A display with fewer than two desktops is left unmanaged until it has a second one, and minitile says so in the user's words, since macOS does not let apps add desktops and the user has to add it in Mission Control.
- Windows on any extra desktops are left alone.

The status menu names each display that needs a second desktop by its name as macOS shows it (`NSScreen.localizedName`), as in "LG UltraFine needs a second desktop", with the explanation as the row's subtitle, which the menu wraps: "minitile keeps hidden pages on a second desktop. macOS does not let apps add one: open Mission Control and click + at the top of this display." An "Open Mission Control" item, listed once however many displays need a desktop, opens `/System/Applications/Mission Control.app`. With "Displays have separate Spaces" off, a single row, "Displays have separate Spaces is off", explains that minitile gives each display its own pair of desktops and that the setting is turned on in Desktop & Dock settings, then takes a log out and back in; an "Open Desktop & Dock Settings" item opens `x-apple.systempreferences:com.apple.Desktop-Settings.extension`. These rows come first among the menu's warnings, the menu bar title gets its " !" for them, and a warning that repeats one of their titles, as the startup failure for separate Spaces does, is listed once. `mntl display list` and `display info` give the same need as the display's `unmanaged_reason`: "Needs a second desktop: open Mission Control and click + at the top of this display", or "Needs Displays have separate Spaces: turn it on in Desktop & Dock settings, then log out".

A notice on the display itself says the same when the display starts needing a second desktop: at launch, when it is connected without one, or when its second desktop is removed. It is centered on that display's usable area in the shared panel style (see "Visual style"): two desktops as Mission Control shows them, the first in wire with a window in it and the second as a lit neon outline with a lit +, labelled "Desktop 1" in dim and "Desktop 2" in neon; the header "LG UltraFine needs a second desktop" in ink, 13 pt semibold; and below it, in dim at 12 pt, the menu's explanation followed by "Until then, minitile leaves this display's windows alone." It is 440 pt wide and as tall as its text, at most the usable area. It hides as soon as the display has a second desktop, which the three-second topology probe notices without a desktop switch, followed by the display settling; otherwise it hides 12 s after it appeared. Probes that still find the desktop missing neither show it again nor keep it longer; it shows again only once the display has had a second desktop or been disconnected. Separate Spaces is one setting for every display, so it gets no notice, only the menu row. The notice shows only while minitile is started and not quitting. The panel is borderless, non-activating and click-through, cannot become key or main, and joins all Spaces, including fullscreen ones; its level is `.floating`, the position indicator's.

Untested in minitile: the notice and the menu's setup rows on screen, and opening Mission Control and Desktop & Dock settings from the menu.

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

- Which changes animate: only outputs of `.command` inputs (key bindings, the menu, `mntl`). For each display, the shell compares the shown workspace and page identities before and after the command. A changed page within a workspace slides horizontally, by the pages' order; a changed workspace slides vertically, by the workspaces' order. The order comes from the state that holds both identities, before the command first, since cleanup removes the page or workspace being left and navigation creates the one entered; failing both, the old index before is compared with the new index after. `page next|prev` and `workspace next|prev` that leave the display they navigate unchanged bounce on that display: the display named by their `display UUID` suffix, else the core's command display (the focused window's display, else the last active one, else the primary). A command that crossed to another display, as the core's output reports, bounces nowhere, and the shell shows the position indicator on the display crossed into. The shell takes the state before every command, whether transitions run or not.
- Capture: `SCScreenshotManager` with a per-display content filter that excludes minitile's own application, so the overlays, the position indicator and the grab outline never appear in a capture; `sourceRect` is the usable area in display-local top-left coordinates, at full backing resolution, BGRA, without the cursor. Shareable content is fetched when transitions turn on, after display changes, and on a config reload or Reduce Motion change while it is not loaded, followed by a throwaway capture. Until it arrives, view changes are instant.
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
- Command: the tap thread sends the command to the main thread asynchronously with the swiped display's address, for example `page next display UUID`, and the main thread runs it through the same path as a key binding, so it slides, bounces, crosses, holds the reconcile and focuses like Ctrl+arrows. After a swipe that crossed, the main thread warps the pointer to the middle of the usable area of the display crossed into (`CGWarpMouseCursorPosition`, then `CGAssociateMouseAndMouseCursorPosition` so the user's next movement is not held back). A command that fails, for example because the session went inactive, is logged and dropped.
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
    var orderedOut: Bool           // off screen by its app's doing; not saved
    var fromFrontmostApp: Bool     // when it appeared or was ordered back in
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
    case windowUpdated(WindowInfo)             // title, frame, minimized, app-hidden or ordered-out changed
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
- answers `debug`, `switcher` and `help show` commands itself and passes every other command to the core as `.command(argv)`.

Scene visible/stashed lists express desktop ownership, including minimized and app-hidden windows. Frame targets cover active tiled windows on both shown and stashed pages; minimized, app-hidden, floating and explicitly hidden windows have no tiled frame target. Ordered-out windows are in neither list, so minitile leaves them where their app put them. `Action.setFrame` is a one-shot floating resize using the normal AX frame-write safeguards. `Action.openConfig` opens the config file. Both run before focus actions. IPC handlers supplied on `.main` use `MainActor.assumeIsolated` to access the shell's main-actor state.

## State and lifecycle

- The grid is saved to `~/.local/state/minitile/state.json` on every change (`MINITILE_STATE` overrides the path). It records each window's ID and pid, its slot or hidden state, the page variants and ratios, and each workspace's home display UUID.
- Window IDs stay valid while their app runs, so a restarted minitile resumes the same grid. Windows whose ID no longer exists, or whose pid changed, are dropped from the saved state.
- Windows found at start that are not in the state are adopted:
  - windows on the visible desktop fill pages of the first workspace;
  - windows on the stash follow on further pages.
- On quit, stashed windows stay on the stash, where Mission Control can reach them.
- Startup checks, in order: Accessibility permission (prompt, explain in the menu bar, and wait until granted); the SkyLight functions (refuse to run if missing); "Displays have separate Spaces" (refuse to run without it, and explain in the menu bar how to turn it on); a desktop pair per display (a display without one is left unmanaged, named in the menu bar with how to add a desktop, and shown a notice; see "Hiding pages: stash desktop"). If the current desktop of a display is its stash, minitile switches to the visible one.

Adoption preserves discovery order within the visible and stash groups. Stash adoption begins after the first workspace's last populated page, even if a visible page has free slots. Unknown windows join the first workspace without changing a valid saved view; the shell's startup focus observation can show a different page. Known windows keep their saved placement regardless of macOS's observed display position. Repeated observations of the same ID are ignored after the first. Unsupported or structurally invalid saved snapshots fall back to adoption. A changed pid in a later appearance/update is treated as a new window identity. Only `SavedState` supplies defaults for absent top-level fields. `PageState`, `WorkspaceState`, `DisplayState` and `WindowState` use synthesized decoding, so a missing required key fails decoding of the entire saved-state file. The script-facing `state` shape is documented separately above.

## Config

- The config lives in `~/.config/minitile/minitile.toml` (`MINITILE_CONFIG` overrides the path) and is reloaded when the file changes. Editors often replace the file, so the watch covers its directory.
- It is parsed with TOMLDecoder (github.com/dduan/TOMLDecoder, from 0.4.5: pure Swift, decodes into `Codable` types, MIT). A hand-written parser can replace it later if the dependency becomes a burden.
- A config error keeps the previous config and shows the error in the menu bar and in the reply to `mntl config reload`.
- There is no settings GUI. The menu bar item is the active display's scene label (workspace and page, for example 2:3) as text; see "Menu bar". Its menu lists the state and any warnings, then Help and Quit Minitile, each a command. Display setup minitile cannot make itself (a missing second desktop, separate Spaces off) is listed with an explanation and an item that opens Mission Control or Desktop & Dock settings (see "Hiding pages: stash desktop"). Page and workspace changes also show the position indicator described under "Model".

An initial config error leaves the app inactive with a menu warning; the config watcher, or `mntl config reload`, retries startup once the file is corrected. The watcher starts before the config is parsed, and the IPC listener stays available after an initial config error. The watcher observes both the directory for atomic replacements and the file for in-place writes, debounced by 150 ms. A missing directory is watched through its nearest existing ancestor. Config reloads are deferred while the session or display topology is suspended and retried after display recovery.

Menu bar: the item is plain text with no image: the active display's scene label, for example 2:3, or "minitile" before start or with no managed display. Warnings never change it: they are rows in the menu and the item's tooltip. The menu holds the state line, the warnings and their fixes, a separator, Help (shown with Cmd+H, opening the help screen) and Quit Minitile. Floating, layout variants and the config are reached through key bindings, `mntl` and the config file watcher, not the menu.

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
"ctrl+alt+space" = "page variant"
"cmd+tab" = "switcher next"
"cmd+shift+tab" = "switcher prev"
"ctrl+alt+left" = "window resize left"
"ctrl+alt+right" = "window resize right"
"ctrl+alt+up" = "window resize up"
"ctrl+alt+down" = "window resize down"
"cmd+alt+`" = "window swap next"
"cmd+alt+shift+`" = "window swap prev"
"cmd+h" = "help show"
"cmd+alt+h" = "ignore"
```

The command strings above use the final grammar. A chord is modifiers (`ctrl`, `shift`, `alt`, `cmd`) and one key (a letter, a digit, `left`, `right`, `up`, `down`, `return`, `space`, `tab`, `escape`, `f1` to `f20`, and `` ` `` for the key of macOS's Move focus to next window shortcut), joined with `+`.

`Config.parse` accepts file contents, with nil for an absent file; file I/O stays in the shell. Gaps and padding must be finite, nonnegative numbers. `trackpad_swipes` is a boolean. App lists contain nonempty bundle ID strings without surrounding whitespace. Unknown config keys, invalid field types, unsupported keys, repeated modifiers and duplicate normalized chords are rejected. Chords accept case and modifier-order variations and are displayed as ctrl, shift, alt, cmd, then key. Binding commands are split on whitespace; they are not shell commands and do not perform shell expansion. Command validation happens when executed, allowing shell-owned debug, switcher and `help show` verbs.

## macOS behaviour to respect

Learned from HyprMac and the spikes.

Frame writes:

- Turn `AXEnhancedUserInterface` off on the app around frame writes and restore it afterwards, once per app per pass.
- Write size, then position, then size again. macOS clamps size to the screen the window currently stands on.
- Round frames to whole points. Skip writes when the cached frame already matches.
- If a size write fails with AX error -25205 (Dia), nudge it by 1 pt and retry.
- Read back once after the window settles, with loose tolerance (about 20 pt, since Terminal snaps to its cell grid). If a window refuses its slot, adjust once; never fight the app.
- Ignore move and resize notifications caused by minitile's own writes for about 1-1.5 s, since AX reads lag on macOS 26 and 27. Otherwise they look like user drags.

While the left mouse button is down, an AX frame differing from the last write by more than 20 points identifies a user drag even during suppression. Delayed frame verification skips held mouse buttons and dragged windows. The 30 ms release poll runs only while a drag is active. A dragged window's frame is read on its move notifications even during suppression, so the drop picker can follow it.

Discovery:

- One `AXObserver` per app. App-level notifications: window created, focused window changed, main window changed, application activated. Window-level notifications: element destroyed, moved, resized, title changed, miniaturized, deminiaturized.
- Also handle NSWorkspace notifications: launch, terminate, hide, unhide, activate, active space changed.
- Window IDs come from `_AXUIElementGetWindow` only, never matched by position.
- Treat a window as real only if the CG window list shows it at layer 0 with alpha above 0.01.
- Never manage popups: an `AXWindow` whose subrole is `AXUnknown` and that has no close button, such as Chrome's address bar suggestions. Chrome reuses these windows, lists them in `AXWindows` only while they are open, and cannot focus them: managed, one would become its page's focus target, and Chrome's answer would send the view to another page. A managed window that rereads as a popup is dropped.
- A failed AX read means "unknown", not "closed". A destroyed element may not report its pid, so use the observer's pid.
- Apps can keep listing a destroyed window briefly. Confirm disappearance with a few rechecks; busy Electron apps flicker otherwise.
- Some apps (Teams, Mail) reuse window IDs on close and reopen.
- While the session is locked or the displays sleep, the on-screen window list empties. Freeze lifecycle changes until the interruption ends.

The shell confirms disappearance after three WindowServer snapshots no longer contain the same window ID and pid. A snapshot counts a miss only for a window that was already known when it was taken. Event-triggered rechecks share one pending sequence at 150, 400 and 900 ms, scoped to affected pids; later notifications extend the affected pid's confirmations without duplicating timers. Focus and destroy rechecks read WindowServer presence only, while creation rechecks inspect the supplied new-window elements. A scan every three seconds catches missed notifications and retries incomplete observer registrations; it runs off the main thread (see Responsiveness). An app is recorded as observed only after each app-level registration succeeds or reports the notification unsupported; unsupported notifications are not retried, and other failed app or window registrations are retried. An empty or failed WindowServer snapshot is unknown. A window counts as ordered out after three snapshots in a row show it off screen (no `kCGWindowIsOnscreen`) on a desktop its display is showing, unless it is minimized or app-hidden, and back on the first snapshot showing it on screen. Stashed windows are off screen too, so the desktops of off-screen windows are read right after each snapshot, on its thread. `AXWindows` omits ordered-out windows, so startup does not adopt them. Background agents with prohibited activation policy are excluded from AX observation. Sleep, session inactivity, lock and pending display reconfiguration suspend lifecycle changes.

Responsiveness:

- Set `AXUIElementSetMessagingTimeout` to about 1 s system-wide; the default of about 6 s freezes the manager on a hung app.
- The keyboard event tap runs on its own thread. Re-enable it on `tapDisabledByTimeout` and `tapDisabledByUserInput`, reset modifier state, and check periodically that it is still alive. Secure input silently stops it; show that in the menu bar (`IsSecureEventInputEnabled`).
- Swallow the key-up of every swallowed key-down.
- Opt out of App Nap: hold a user-initiated activity (`ProcessInfo.beginActivity`, allowing idle system sleep) for the app's lifetime, and set `NSAppSleepDisabled` in Info.plist. A windowless accessory app otherwise looks idle and gets napped, and a napping app runs its main thread at low priority and delays its timers, so the first keys and gestures after a break are handled late.
- After sleep, a session switch or a lock ends, reload screen capture content and take a throwaway capture, so the first slide afterwards is not slowed by a cold capture.
- The main thread handles input and never waits on discovery. The three-second scan and the presence rechecks take their WindowServer snapshot and make their AX reads on background threads, one task per app, so a slow or hung app delays only its own results; the main thread then applies them. A pass skips an app whose previous read is still running. Discovery reads regular apps, and accessory apps only while they own a real window in the snapshot, and starts observing an app only from such a read; helper processes such as a browser's web content processes own none, and can stop answering for the full timeout. A launched app is read in the background the same way, and so is a hidden or unhidden app, whose windows' hidden state updates at once. The scan rereads the attributes of the windows it already knows. An app whose first read in a pass (its window list, or a new window's role) fails with -25204, as a hung app's does at the timeout, is not read further in that pass. A window's result is dropped if, after the snapshot was taken, a notification updated the window, minitile wrote its frame, or the window was discovered or removed; every result is dropped if lifecycle changes are suspended when it arrives or were suspended since its snapshot. Observer registrations, first and retried, run on the main thread only for apps whose latest background read was answered, that is, did not fail with -25204. A resume starts a scan after its reconcile and does not wait for it. Startup discovery and adoption, including a config reload's, stay on the main thread, with the same choice of apps.
- Commands still make their AX frame writes and focus calls on the main thread, so a busy app can delay the command that targets it.
- Input waits behind work on the main thread, so the shell logs at notice level: each wake, and whether the displays were unchanged; each resume, with the time spent refreshing displays and reconciling; any key binding or swipe that waited over 150 ms for the main thread, with the wait; any key command that takes over 100 ms; any reconcile over 100 ms, including one held for a slide; any AX call on the main thread over 200 ms, with its app and attribute; and any app whose background read took over 500 ms.

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
- `scripts/build-app.sh` wraps `minitile` in `build/Minitile.app` (`LSUIElement` set; bundle ID `app.minitile.dev` and name "Minitile Dev", or `app.minitile` and "Minitile" with `MINITILE_CHANNEL=release`) and places `mntl` next to it. It signs with `MINITILE_SIGN_IDENTITY`, default "Apple Development", so the Accessibility grant survives rebuilds; an ad-hoc signature changes every build.
- Logging uses unified logging with subsystem `minitile`.
- Threads:
  - the main thread runs the `NSApplication` loop, AX observer registrations, writes, focus calls and notification reads, the core and the reconciler;
  - discovery takes its WindowServer snapshots, reads the desktops of known off-screen windows right after each one, and makes its scan and recheck AX reads on a concurrent background queue (`minitile.discovery`), one task per app, and hands the results to the main thread;
  - the keyboard event tap runs on its own thread and hands commands, window switcher and help screen keys and grab releases to the main thread;
  - the trackpad swipe tap runs on its own thread and does the same;
  - the socket server reads on a background queue and does the same.

  If hung apps still stall the main thread through command AX calls in practice, those move to per-app threads, as AeroSpace does.

The shell uses the Swift 6 language mode. AX observer callbacks run on the main run loop; the keyboard tap owns a separate run loop and locks its small command-matching state, and the swipe tap does the same for its swipe decision and policy snapshot. Letter and digit bindings use the current keyboard layout, with function and navigation keys matched by native keycode. Stash Desktop N blockers use user-desktop order from the native display-space enumeration; their numbering with multiple displays is unverified. State writes are atomic and serialized off the main thread, and quit flushes pending writes.

## Development and testing

- Core, IPC and the shell's pure helpers have unit tests run with `swift test`. They need no permissions and never touch windows.
- CI (`.github/workflows/ci.yml`) builds and runs `swift test` on GitHub's macOS 26 Apple silicon runner for every push to main and every pull request. The website workflow (`pages.yml`) runs the website's tests and publishes `web/` to GitHub Pages at minitile.app when main changes under `web/`.
- Releases are Apple silicon only and ship as a disk image. Pushing a `v*` tag runs `release.yml`: the tests, then `scripts/release.sh VERSION`, which builds in release mode with the version from the tag and the run number as the build, signs `mntl` and the app with the Developer ID certificate, the hardened runtime and a secure timestamp, notarizes and staples the app, builds `minitile.dmg` with `dmgbuild` from `packaging/dmg.py` (an lzfse-compressed HFS+ image: the styled window described in `BRAND.md`, the app and an Applications link at fixed positions, the app icon as the volume icon), then signs, notarizes and staples the disk image. The release workflow installs `dmgbuild` 1.6.7 with pip into a venv. The workflow publishes `minitile.dmg` and its SHA-256 as a GitHub Release with generated notes; the asset name stays the same across versions, so `releases/latest/download/minitile.dmg` always fetches the newest. Its secrets: `MACOS_CERTIFICATE_P12` (base64) and `MACOS_CERTIFICATE_PASSWORD`, and an App Store Connect API key as `NOTARY_KEY_P8` (base64), `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`. A local release uses the login keychain, a notarytool profile in `NOTARY_PROFILE` and `dmgbuild` on the PATH (`python3 -m pip install dmgbuild==1.6.7`, in a venv where pip refuses); `release.sh` stops before building if it is missing.
- Homebrew: the tap `fiorix/homebrew-tap` holds the `minitile` cask, installed with `brew tap fiorix/tap`, `brew trust --cask fiorix/tap/minitile` and `brew install --cask fiorix/tap/minitile`. It installs the app from the latest release's disk image, links `mntl`, requires macOS 26 on Apple silicon, quits minitile before upgrades and uninstalls, and zaps `~/.config/minitile` and `~/.local/state/minitile`. A workflow in the tap follows the latest release every three hours, by hand, or on a `repository_dispatch` event, and commits the new version and checksum.
- `scripts/build-app.sh` puts `mntl` inside the app at `Contents/MacOS/mntl`, with a copy at `build/mntl`, and the app icon at `Contents/Resources/AppIcon.icns` (`CFBundleIconFile`). The icon and the disk image background are generated by the branding script and committed under `packaging/`, so builds need no browser. Releases have the bundle ID `app.minitile` (`scripts/release.sh` builds with `MINITILE_CHANNEL=release`); local builds are on the dev channel, "Minitile Dev" with the bundle ID `app.minitile.dev`, so macOS keeps their Accessibility and Screen Recording grants and their LaunchServices entry apart from an installed release. `mntl` is signed as `app.minitile.mntl` or `app.minitile.dev.mntl`. Changing a released app's bundle ID makes macOS ask for its permissions again. Both builds share `~/.config/minitile`, the state file and the socket, so run only one at a time.
- The shell is tested live with `scripts/smoke.sh`. Runs use a temporary config with `only_apps = ["com.apple.TextEdit"]`, temporary state and socket paths, and TextEdit documents the test opens itself, so the user's windows are never moved or closed.
- Running minitile over every app rearranges the user's desktops, so the first such run needs the user's go-ahead.
- `dev/` is internal working space and is not tracked: work orders, progress notes, and in `dev/spikes/` the throwaway programs that validated the primitives, with their logs. They are reference code for SkyLight, focus, activation pre-emption and the event tap, not a base to build on. Upstream sources: yabai `src/misc/macho_dlsym.h` and `src/space_manager.c`.

`scripts/smoke.sh` modes:

- default: drives minitile through `mntl`, compares the requested scene with raw WindowServer spaces and AX frames (20 pt tolerance), and checks a document TextEdit orders out and back in, invalid-config retention and restart persistence;
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
- the drop picker for dragged windows;
- the grab highlight for keyboard moves and resizes;
- the Cmd+H help screen.

Not planned:

- focus-follows-mouse;
- persistent focus borders and dimming;
- a mouse-driven overview;
- live previews of edge drags;
- saved layouts;
- a URL scheme (status bars can use `mntl watch`);
- a settings GUI;
- animations other than page transitions.

## Open

- Multiple displays, to be tested with the user's second monitor:
  - each display's stash works on its own: moves and page flips on one display leave the other alone;
  - crossing displays with Ctrl+arrows, Ctrl+Shift+arrows and swipes, including the slide back on the display left behind and the pointer following a swipe;
  - the window switcher across displays, its slide between them, and the monitor markers;
  - activation pre-emption when the app's window sits on the other display's stash;
  - what macOS does with a disconnected display's desktops and the windows on its stash, and whether they come back on reconnect. Seen once: after an unplug, the laptop had user desktops 1, 1244 and 1264, where 1264 had been the external display's stash.
