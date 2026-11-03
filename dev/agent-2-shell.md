# Agent 2: macOS shell and integration

You are building the macOS-facing half of minitile, a small tiling window manager for macOS, then wiring it to the core and testing it live on the user's Mac. Another agent builds the core, the socket layer and `mntl` at the same time. The user hands this file to you; it authorizes the work and the commits described here.

Read `DESIGN.md` at the repository root in full before anything else. It is the source of truth for behaviour. This file says what you own, in what order to work, and how to coordinate with the other agent. When the two disagree, `DESIGN.md` wins; tell the user.

## Work order for both agents

1. Agent 1 bootstraps the repository and publishes the core contract as tag `contract-v1`. The user then starts you.
2. Both agents work in parallel, each in its own git worktree:
   - agent 1, branch `core`, in the repository root: `MinitileCore`, `MinitileIPC`, `mntl` and their tests;
   - agent 2 (you), branch `shell`, in `../minitile-shell`: `CSkyLight`, the `minitile` app, the build and smoke scripts, live testing.
3. Agent 1 tags `ipc-v1` once the socket and `mntl` work, and `core-v1` when everything is done. You merge `core` at those tags, wire it up and run the live tests.
4. You ask the user before merging into `main`.

## Before you start

1. In the repository root, check that tag `contract-v1` exists (`git tag -l contract-v1`). If it does not, tell the user agent 1 has not published the contract yet, and stop.
2. Create your worktree: `git worktree add ../minitile-shell -b shell contract-v1`. Work only there. The repository directory may have been renamed; use whatever it is now.
3. To pick up agent 1's work, run `git merge core` in your worktree, or merge a tag. `git tag -l` shows what is published. Read `dev/contract-changes.md` after each merge if it exists.

## What you own

- `Sources/CSkyLight`, `Sources/minitile`, `scripts/`, and tests for any pure helpers you add to the app.
- Your targets' entries in `Package.swift`. Keep changes small; agent 1 owns the rest of the file.
- Do not edit agent 1's sources. If the core or IPC needs a change, tell the user what and why, so they can relay it to agent 1. If you are blocked and the change is trivial, make it in a separate commit and mention it in your report.

## Safety on the user's machine

This runs on the user's own Mac, with their windows and their work.

- Until the user says otherwise, run minitile only with a temporary config (`MINITILE_CONFIG`) that sets `only_apps = ["com.apple.TextEdit"]`, and use a temporary state file (`MINITILE_STATE`).
- Only move or close windows your tests opened: TextEdit documents in a temporary directory. Never close or quit the user's apps or windows. Leave TextEdit as you found it.
- The user's own windows may sit on their second desktop, which minitile treats as the stash. With `only_apps` they are not touched.
- Ask the user before:
  - the first run without `only_apps`;
  - changing any System Settings;
  - anything outward-facing.
- Some steps need the user at the desk. Ask them clearly and wait:
  - granting Accessibility to `Minitile.app` (System Settings > Privacy & Security > Accessibility);
  - real keypresses for the key tests;
  - plugging and unplugging the second monitor.
- If you lose control of the machine state (windows stuck on the stash, a tap swallowing keys), stop minitile first (`mntl quit`, then `pkill -x minitile`) and tell the user. Stashed windows are reachable through Mission Control.

## Rules

- Do not change design decisions. Where `DESIGN.md` is ambiguous, pick the simplest reading that fits it, make `DESIGN.md` describe what you built, and list the choice in your final report. If live behaviour contradicts `DESIGN.md`, record what you measured in `DESIGN.md` and ask the user before redesigning.
- Keep it small. minitile exists because HyprMac grew to 38k lines. Port only what each step needs.
- `dev/spikes/` holds the throwaway programs that validated the primitives on this machine, with logs. Read them for the exact calls, byte layouts and timings, then write clean code. Do not copy their test harness.
- Prefer `@MainActor` for the app. The event tap thread is the exception. If C callbacks (AX observers, the tap) fight Swift 6 strict concurrency, the `minitile` target may use the Swift 5 language mode.
- Commit at the end of each step with an imperative subject line and a short body when useful. No attribution trailers or signatures.
- Keep `DESIGN.md` honest. When a live test verifies or refutes something listed as untested or "not yet verified", update the doc with what you measured.

## Step 1: CSkyLight

A small C/Objective-C target with a plain C header. Roughly:

- `bool csl_init(char *err, size_t len)`: `dlopen` SkyLight, resolve every symbol, and find the bridged-operation function by walking SkyLight's in-memory `LC_SYMTAB`. Return false with the missing name if anything is absent; minitile refuses to run then.
- Desktops: copy the managed display spaces, a display's current space, and the spaces for a list of windows.
- `csl_move_windows(ids, n, space)`: the bridged move.
- `csl_switch_space(display, target, hide)`: the instant switch (show, hide, set current).
- `csl_window_id(AXUIElementRef, uint32_t *)`: `_AXUIElementGetWindow`.
- `csl_focus_window(pid, wid)`: `_SLPSSetFrontProcessWithOptions` plus the two key-window event records.
- `csl_symbolic_hotkey(id, ...)`: key code, modifiers and enabled state of a system shortcut. Checked on this machine:
  - 32 and 33 are Mission Control and App Expose (Ctrl+Up and Ctrl+Down);
  - 79 and 81 are Move left/right a space;
  - 118 + N - 1 is Switch to Desktop N (Ctrl+1 is 118), turned off here by default.

Port from `dev/spikes/stash/stash.m`:

| Function | What it shows |
|---|---|
| `macho_find_symbol` | the `LC_SYMTAB` walk |
| `load_symbols` | symbol names, and the bridged symbol in `BRIDGED_SYM` |
| `topo_load` | parsing the managed display spaces |
| `bmove` | the bridged move |
| `bswitch` | the instant switch |
| `slps_front_key` | the focus byte layout |
| `hk_post` | the symbolic hotkey lookup |

Check that SwiftPM compiles the `.m` files with ARC; add the flag if it does not.

## Step 2: app skeleton and build

- `minitile`: an `NSApplication` with the accessory activation policy and a real run loop. A status item shows the scene label, and a menu shows state, warnings, and the items listed under "Config" in `DESIGN.md`, each running a command.
- Startup checks in the order given under "State and lifecycle". For Accessibility, prompt with `AXIsProcessTrustedWithOptions`, ask the user to grant it, and poll until granted.
- `scripts/build-app.sh`, as specified under "Implementation":
  - build;
  - assemble `build/Minitile.app` with an `Info.plist`;
  - copy `mntl` to `build/mntl`;
  - sign with `${MINITILE_SIGN_IDENTITY:-Apple Development}`. The keychain holds "Apple Development: Alexandre Fiori (8YT442RX6R)".
- Run with `open build/Minitile.app`, because Accessibility is granted to the bundle, not to your terminal. Logs: `log stream --predicate 'subsystem == "minitile"'`.

## Step 3: socket and debug commands

- After `ipc-v1` is tagged, merge it, start the server on the main queue, and pass `argv` to the core. `debug` commands are answered by the shell (see "Command line: mntl"). If `ipc-v1` is not out yet, do steps 4 to 7 first and come back.
- Add `mntl debug spaces` (displays, desktops, visible, stash, current) and `mntl debug windows` (raw discovery: ID, pid, app, title, frame, space, tileable). Use them to check every later step.

## Step 4: window discovery

- Per-app `AXObserver`s and the NSWorkspace notifications listed under "Discovery". Apply the filters there and in "Floating windows". Keep a table from window ID to AX element. The core gets `windowAppeared`, `windowUpdated` and `windowGone`, with disappearance confirmed by rechecks.
- `only_apps` filtering happens here as well as in the core, so ignored apps cost nothing.
- At startup, collect windows on each stash and move them to the visible desktop to obtain AX handles, as described under "Rules minitile must follow". Verify that `kAXWindows` lists them right after the move, and record the result in `DESIGN.md`.

## Step 5: displays

- Enumerate screens: UUID from `CGDisplayCreateUUIDFromDisplayID`, frame and visible frame converted to CG coordinates (`cg_y = primaryHeight - ns_y - height`), the primary flag.
- Desktops from the managed display spaces: user desktops only, first is visible, last is stash, fewer than two means `unmanagedReason`. Check "Displays have separate Spaces".
- Debounce and fingerprint display changes as specified, with a longer delay after wake.
- At startup, switch any display that is showing its stash to its visible desktop.

## Step 6: reconciler and focus

- Apply each `Output` in the order given under "Architecture": moves first (show before hide), then frame writes by the rules under "Frame writes", then actions with focus last. Skip frame writes to a window being dragged.
- Focus: AX main and focused plus raise, `activate`, then `csl_focus_window`. Remember what you focused and when, so the echo is not sent to the core as a user focus change.
- Drop notifications caused by your own moves and writes (see "Frame writes").
- Pre-emption fast path: on `NSWorkspaceDidActivateApplicationNotification` or the AX application-activated notification, whichever comes first, send `appActivated` and reconcile at once. Do the move before any frame write.
- Bounce back from the stash after `activeSpaceDidChange` when a display's current desktop is its stash.
- Close via `kAXCloseButton`.

## Step 7: keys and mouse

- A session-level, head-insert event tap on its own thread for key down, key up and flags changed. Match chords from the config, ignoring the fn and keypad flags, and hand the bound command to the main thread. Swallow the matching key up. Re-enable the tap when macOS disables it, and check its health.
- Swallow Desktop N shortcuts that lead into a stash, looked up with `csl_symbolic_hotkey`.
- Show secure input in the menu bar while it blocks the tap.
- Drags: a move or resize notification you did not cause, arriving while the left mouse button is down, starts a drag on that window. Detect the release (poll `NSEvent.pressedMouseButtons` while a drag is active, or use a listen-only mouse tap) and send `dragEnded` with the window's frame and the cursor in CG coordinates.
- Ctrl+arrow while a drag is active sends the nudge or carry command for the dragged window, with its ID given explicitly. Use the grammar from `mntl help`.

## Step 8: integration

- Merge `core` (at `core-v1`, or earlier to start wiring).
- Create the `Engine` on the main thread. Its inputs come from discovery, displays, the tap, drags, the socket, the menu and the config watcher. Its outputs go to the reconciler, the action handlers, socket replies, `watch` broadcasts and the state file.
- The config watcher covers the file's directory, since editors replace files. A parse error keeps the old config and shows the error.
- Startup: read the saved state, enumerate windows and displays, send `.started`, reconcile.

## Step 9: live validation

1. `scripts/smoke.sh`, fully automatic, user's windows untouched:
   - build;
   - write a temporary config with `only_apps = ["com.apple.TextEdit"]`;
   - launch;
   - open TextEdit documents from a temporary directory;
   - drive minitile with `mntl`: page next and prev, nudge, carry, workspace next past the last, window hide and show, float, swap, close;
   - assert on `mntl --json state` with `jq`;
   - clean up.
2. With the user at the desk, still on TextEdit only, check:
   - real Ctrl+arrow keypresses, including Ctrl+Up and Ctrl+Down (the Mission Control takeover is untested);
   - Cmd-Tab pre-emption to a window on a hidden page;
   - drag resize, drag-to-swap, and Ctrl+arrow while dragging;
   - a trackpad swipe between desktops;
   - quit and restart resuming the same grid.
3. Multiple displays, with the user's second monitor: the questions under "Open" in `DESIGN.md`, then unplug and replug with windows on several pages of the external display. Record the results in `DESIGN.md`.
4. Ask the user for the first run without `only_apps`.

## Step 10: finish

- `DESIGN.md` describes what was built and what was measured. Move verified items out of "Untested" and "Open", and add what you found.
- Ask the user before merging `shell` into `main`.
- Give the user a final report:
  - what works;
  - what was verified live, with numbers where they matter;
  - what is still unverified;
  - every place where you interpreted `DESIGN.md`;
  - any change you made outside your area.
