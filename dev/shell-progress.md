# Shell implementation journal

Implement the macOS shell from `agent-2-shell.md` against `core-v1`, preserving core sources. Live runs use temporary config/state/socket paths and TextEdit only. User participation is required for Accessibility, hardware keys and monitor tests. Merging into main remains subject to approval.

## Plan

- [x] 1: SkyLight bridge compiles with ARC. Symbol resolution is checked separately without moving windows.
- [x] 2: Accessory app, startup checks, menu and bundle assembly build successfully. Signing and Accessibility are verified through the user's Terminal run; signing remains unavailable in the agent sandbox.
- [x] 3: Main-queue IPC dispatch and spaces/windows/scene/timings/health debug commands.
- [x] 4: AX discovery, close detection and startup stash adoption passed the TextEdit command smoke test; two of two stash handles were acquired on the first pass.
- [x] 5: Display enumeration, desktop topology and bounce compile; notification debounce is wired with the app lifecycle.
- [x] 6: Ordered reconciliation, frame safeguards and focus implemented; move ordering covered by helper tests.
- [x] 7: Dedicated keyboard tap, drag commands and secure-input reporting implemented; routing and release behavior covered by helper tests. Physical Ctrl+arrows and suppression of Mission Control/App Expose are verified.
- [x] 8: Engine wiring, persistence and directory/file config watcher implemented; replacement, deletion, recreation and ordered persistence tests pass.
- [ ] 9: Automatic TextEdit smoke and physical Ctrl+arrow navigation passed. Modified-arrow moves, gestures, activation and multiple displays still need user-assisted checks. Recovery of the preserved test session completed; the interactive runner now prints the remaining single-display checks.
- [x] 10: Document current evidence and interpretation choices. Remaining live results and merging into main are pending.

## Checkpoint

The requested sibling worktree was created and fast-forwarded to core-v1, but this session forbids file edits there and refused its relocation. Implementation uses the writable, ignored `.build-shell/` worktree on `shell-build`, based on core-v1. The untouched sibling `shell` remains at core-v1. Standalone Git writes work; chained Git mutations can be blocked.

The user's successful automatic run is `build/smoke-20261103-192823`, using shell commit 4d7c37b. Signing, Accessibility, native placement, config errors and restart are now verified on one display. Core subsequently advanced through 19b3ada with minimized-activation, native-focus and directional-nudge fixes; these are merged into shell-build at 7e14e39. The merged source passes 84 core tests and 12 shell tests. The physical-key run `build/smoke-20261103-194657` used the rebuilt integration and the user reported "correct". Its final state and cleanup files are empty because minitile quit normally through its menu before the response was entered, as confirmed by the saved unified log.

## Verification

- 84 core tests and 12 shell tests pass after merging the core follow-up fixes; log: `.build/core-integration-tests.log`. The prior combined check also passed five sandbox-compatible IPC tests. Full socket tests were verified by agent 1 outside the sandbox; no IPC implementation changed here.
- Shell tests cover multi-display show-before-hide ordering, ignoring unknown/already-placed windows, coordinate conversion, frame tolerance, semantic key flags, key-up retention across reloads, explicit drag IDs, stash-shortcut matching, smoke document restrictions, atomic config replacement/deletion/recreation, and ordered state persistence.
- `shellcheck` and `bash -n` pass for both shell scripts; the assembled Info.plist passes `plutil -lint`. The smoke helper compiles. The smoke scene assertion accepts matching fixture data and rejects both wrong-space and wrong-frame fixtures.
- Live command smoke passed on a 2056x1329-point display, visible frame 2056x1290 at y=39, native visible/stash spaces 1/1176. Five TextEdit documents exercised navigation, nudge/carry, empty workspace creation, hide/show, float toggle, swap, close, invalid-config retention and restart. Native spaces and tiled frames were checked throughout. Final four-window geometry had zero error across all 16 components. The three-page/two-workspace grid, window ordering, alternate layout and ratios 0.4/0.7 survived restart exactly. Both of two stashed windows yielded AX handles on the first discovery pass. Temporary files were removed and desktop 1 remained current.
- The invalid-padding error in the terminal transcript was intentional, and the subsequent valid reload succeeded. The tap was available and health reported no warnings, but physical keys were not exercised. Floating resize was issued without an independent AX assertion before tiling resumed. The final 0.036 ms timing was idle reconciliation, not a page-flip measurement.
- The physical-key run recorded 17 `page_shown` events, including page 1/2 navigation, an empty third page, and repeated workspace 1/2 transitions. The user's "correct" response confirms the requested one-window/four-window/empty-workspace/four-window behavior without Mission Control or App Expose. This verifies the basic Ctrl+arrow bindings, not Ctrl+Shift+arrows or drag commands.
- Recovery-script fixtures pass for closing only matching test documents, preserving files after a missing socket, preserving files for a known window missing from the managed state, and preserving files if raw-window inspection fails. Missing arguments, incompatible options and directories outside TMPDIR are rejected. `shellcheck`, `bash -n` and `git diff --check` pass. The live recovery run `build/smoke-20261103-204510` succeeded: managed state and raw TextEdit windows were already empty, the temporary directory was removed, and desktop 1 remained current. This verifies cleanup of an already-closed session, not recovery of still-open stash windows.
- Modified-arrow moves, drag behavior, native activation races, trackpad gestures, display hotplug, sleep/wake and the other original untested macOS cases remain unverified. The original spike timings remain unchanged.

## Implementation choices

- Use the first and last user desktop when extras exist; initial discovery ignores intermediate and fullscreen Spaces. Stable UUIDs identify grids; native identifiers are retained separately for switching.
- Retry startup stash discovery four times over one second; restore unreadable windows and report them. Sort startup windows by ID for deterministic adoption.
- Confirm disappearance after three CG snapshots; retry notifications at 150/400/900 ms and scan every three seconds. Preserve unknown AX reads and freeze lifecycle changes across session/display interruptions.
- Keep Swift 6 throughout; bridge C callback execution with explicit main-actor assumptions and use a locked value router on the keyboard thread. Letter bindings follow the current layout.
- Watch both config file and directory, including creation from an absent path; initial parse errors suspend startup rather than applying unrestricted defaults. Persist atomically on a serial queue.
- Restrict smoke discovery by exact document directory in addition to TextEdit's bundle ID. Stash recovery on smoke restart requires the runner's captured ID/pid pairs, protecting unrelated TextEdit windows.
- Worktree path and branch differ from the original handoff because of sandbox write boundaries. No core, IPC or mntl source was edited. Package changes are limited to CSkyLight ARC/framework settings and the shell test target.

## Resume

The first Terminal run signed successfully but timed out before opening any documents. After the user granted Accessibility, the next automatic run passed. Direct app launch, signing and unified-log access remain blocked in the agent sandbox, so live runs start from Terminal. Startup stages and failures are also written to stderr for review.

The basic key check is complete. The run recorded `manual-observation.json` with "correct" and valid watch events, but `manual-end.json` and `cleanup-state.json` were empty, no `manual-health.json` was produced, and the five test files were preserved in `/var/folders/q2/3g45h5q10wb0pfzx3t_2yjgr0000gn/T/minitile-smoke.GJTjGv`. The user reported leaving the prompt idle for at least half an hour. The saved `system.log` shows a menu action at 20:27:50.591, AppKit termination at 20:27:50.855 and a voluntary exit. The 264 ms delay matches the app's Quit Minitile action, which schedules termination after 250 ms. This explains the missing socket at the attempted final capture around 20:30; no idle timeout or crash is indicated.

The user ran `--no-build --cleanup` successfully at 20:45. The preserved directory is now gone, and the report contains no surviving TextEdit windows. The mode reuses the saved config/state, restricts startup stash exposure to the original ID/pid pairs, closes observed test documents and preserves files if known windows remain. The original saved state is copied before launch so a failed discovery does not erase the recovery IDs. The interactive prompt explicitly says to keep minitile running until cleanup finishes.

Continue with `./.build-shell/scripts/smoke.sh --interactive --no-build` from the repository root. The runner prints the remaining Ctrl+Shift+arrow, Cmd-Tab, drag resize/swap/nudge and trackpad checks with expected results; basic Ctrl+arrow navigation need not be repeated. After the response it records state/health and checks native placement before cleanup. External-display unplug/replug remains a separate run. Update DESIGN.md only with observed results. The first unrestricted run and merge into main still require explicit approval.
