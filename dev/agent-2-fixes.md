# Agent 2: shell fixes and multi-display validation

You continue the macOS shell of minitile, a small tiling window manager for macOS. A previous agent 2 built the shell; you start without its context. The user hands you this file; it authorizes the work and the commits described here.

## Read first

1. `DESIGN.md` in full. It is the source of truth and a snapshot of the current design.
2. `dev/agent-2-shell.md`: the original work order. Its ownership, safety and live-testing rules still apply, except for the worktree location below.
3. `dev/shell-progress.md`: the previous agent's journal. It explains the smoke tooling, what was verified live, and why live runs are started by the user from Terminal (signing and app launch are blocked in the agent sandbox).
4. `dev/contract-changes.md`.

## Where to work

- Worktree `/Users/fiorix/dev/github.com/fiorix/minitile/.build-shell`, branch `shell-build`. Work and commit only there. Branch `shell` and `../minitile-shell` are stale; ignore them.
- Never run `git clean` in the repository root. `.build-shell` is an ignored directory there (`.build*/`), so it would delete this worktree.
- `Sources/MinitileCore`, `Sources/MinitileIPC` and `Sources/mntl` belong to agent 1, which has finished. Do not edit them. If you need a core change, tell the user what and why.

## Step 0

1. `DESIGN.md` has uncommitted edits from the design session: the position indicator now shows for 1.5 s on page and workspace changes, a held binding fires once, and run history was removed. Commit them unchanged, together with this file, before your own work.
2. A previous run left `/var/folders/q2/3g45h5q10wb0pfzx3t_2yjgr0000gn/T/minitile-smoke.n2jP9E`. It holds only test files; TextEdit is not running and nothing is on the stash. Delete that exact directory, or ask the user to.

## Step 1: fixes

A design review found these. Items 1 to 4 and 8 were confirmed by reading the code paths end to end. Items 5 and 6 are plausible from the code but not reproduced; confirm the failure mode while fixing. Commit each fix separately. Add a regression test wherever the logic can be exercised as a pure helper.

1. Desktop switches must not suspend the shell (`Sources/minitile/Lifecycle.swift:24-30`, `93-115`). `activeSpaceDidChange` calls `scheduleDisplays()`, which suspends with reason "display" for at least 2 s. During that time:
   - Ctrl+arrows are swallowed and then rejected (`App.swift:204`);
   - activation pre-emption is off (`Lifecycle.swift:118`);
   - the space-change handler returns early, so a second slide into the stash is not bounced (`Lifecycle.swift:25`);
   - focus notifications are dropped (`Discovery.swift:190`), and a drag's release is reported late.

   Every bounce from the stash is itself a desktop switch, so this repeats. Fix: on a desktop switch, bounce, refresh window spaces and recheck without suspending; the three-second topology probe already catches added or removed desktops. Keep suspension for screen-parameter changes, sleep, wake and session changes. When any suspension ends, re-read the focused window and re-apply the current scene.

2. Focus forwarding can flip pages (`Discovery.swift:193-197`, `App.swift:143-146`, `Reconciler.swift:42-45`).
   - Focus and main-window notifications from background apps reach the core, so a background app changing its main window shows that window's page.
   - The echo filter drops only the exact window minitile focused. An app whose `kAXFocusedWindow` lags can report its old window right after a Ctrl+arrow, and the core shows the old page again.
   - A failed `kAXFocusedWindow` read is sent as "no focus".

   Fix: forward focus changes only from the frontmost app. While minitile's own focus is in effect, drop all focus notifications from that pid and re-read once when it expires. Treat a failed read as unknown, not nil.

3. Drags inside the echo window are lost (`Lifecycle.swift:130`, `Reconciler.swift:122-129`). A drag that starts within 1.2 s of a minitile move or frame write is taken for an echo, so no drag is registered. The verify pass at 1.25 s then rewrites the frame mid-drag. Fix: while the left mouse button is down, a move whose AX frame differs from the last write by more than 20 pt is a user drag, even inside the suppression window. Skip the verify pass while the button is down or the window is being dragged.

4. Swallowed-key bookkeeping (`Keyboard.swift:60`, `143-146`).
   - A key-up that is never seen leaves its keycode in `swallowed`, and the next press of that key with any modifiers is eaten.
   - Tap-disabled events do not clear the set.
   - Autorepeat re-runs bound commands.

   Fix: clear `swallowed` on tap-disabled events, and honour it on key-down only for autorepeat events. Swallow the autorepeat of a bound chord without running the command again, so a held binding fires once, as "Keys" in `DESIGN.md` states.

5. AX observer registration errors are ignored (`Discovery.swift:66-69`, `133-136`). Apps that are still launching often refuse registration. They are recorded as observed anyway and never retried, so their windows are seen only by the three-second scan. Fix: check the results, and do not mark an app observed until its app-level registrations succeed; retry on the next scan.

6. Rechecks pile up on the main thread (`Discovery.swift:183-187`). Each focus, create or destroy notification queues three full scans, which read `kAXWindows` for every allowed app plus several attributes per window. Bursts stack, and activation pre-emption has only 6-25 ms of margin. Fix: keep one pending recheck series, and make rechecks check WindowServer presence for the pids involved instead of a full AX scan. Measure the time from an activation notification to the move submission before and after, and report both numbers.

7. Small items:
   - If the tap thread exits without `stop()` (`Keyboard.swift:119-124`, `137`), report it in health and the menu, or recreate the tap.
   - Block system shortcuts 79 and 81 (Move left/right a space) when they would lead into a stash, as Desktop N already is. This matters when the user unbinds Ctrl+arrows.
   - Keep the keyboard layout data alive while its pointer is in use (`Keyboard.swift:174-185`, `withExtendedLifetime`).
   - Run the 30 ms drag-release poll only while a drag is active.

8. Position indicator: implement "Position indicator" in `DESIGN.md`. A display's grid appears for 1.5 s when its shown page or workspace changes, and another change restarts the timer. It replaces the always-visible panel. The `grid_indicator_displays` health field and the `--displays` smoke precondition currently assume the panel is always present; change them so they do not depend on it being visible.

## Step 2: verify

- `swift build` and `swift test` pass with no warnings. Review your own diff in a separate pass for unintended behaviour changes.
- Ask the user for an automatic smoke run, then an `--interactive` run that covers:
  - swiping into the stash, then pressing Ctrl+Right and Cmd-Tab straight away (fix 1);
  - a background app opening or closing a window without the page changing (fix 2);
  - dragging a window right after a page flip (fix 3);
  - holding Ctrl+Right (fix 4);
  - the indicator appearing and hiding (fix 8).

## Step 3: multiple displays

Run `./.build-shell/scripts/smoke.sh --displays` from the repository root with the user and their monitor, as described under "Resume" in `dev/shell-progress.md`. Answer the questions under "Open" in `DESIGN.md`.

## Documentation rules

- `DESIGN.md` is a snapshot of the current design and of measured facts. It holds no history: no run IDs, dates, test counts, "the user confirmed", earlier failures, or what changed. When a live test settles an item under "Untested" or "Open", state the fact in its place and remove the item.
- Run results, history and reasoning go in `dev/shell-progress.md`. Start a new section for your session.
- Code comments describe the current code, not its history.

## Finish

- Ask the user before merging `shell-build` into `main` and before the first run without `only_apps`.
- Give the user a final report:
  - what was fixed, with test results;
  - live results, with numbers where they matter, including the activation latency from item 6;
  - what is still unverified;
  - every place where you interpreted `DESIGN.md`.
