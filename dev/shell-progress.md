# Shell implementation journal

Implement the macOS shell from `agent-2-shell.md` against `core-v1`, preserving core sources. Live runs use temporary config/state/socket paths and TextEdit only. User participation is required for Accessibility, hardware keys and monitor tests. Merging into main remains subject to approval.

## Plan

- [x] 1: SkyLight bridge compiles with ARC. Symbol resolution is checked separately without moving windows.
- [x] 2: Accessory app, startup checks, menu and bundle assembly build successfully. Signing is blocked in-session: `Apple Development: no identity found`.
- [x] 3: Main-queue IPC dispatch and spaces/windows/scene/timings/health debug commands.
- [x] 4: AX discovery, lifecycle confirmation and startup stash adoption compile; live behavior awaits signing and Accessibility.
- [x] 5: Display enumeration, desktop topology and bounce compile; notification debounce is wired with the app lifecycle.
- [x] 6: Ordered reconciliation, frame safeguards and focus implemented; move ordering covered by helper tests.
- [x] 7: Dedicated keyboard tap, drag commands and secure-input reporting implemented; routing and release behavior covered by helper tests.
- [x] 8: Engine wiring, persistence and directory/file config watcher implemented; replacement, deletion, recreation and ordered persistence tests pass.
- [ ] 9: Isolated smoke script implemented and statically checked. Signing and live validation remain blocked on access outside this sandbox and user-granted Accessibility.
- [x] 10: Document current evidence and interpretation choices. Live results and merging into main remain pending.

## Checkpoint

The requested sibling worktree was created and fast-forwarded to core-v1, but this session forbids file edits there and refused its relocation. Implementation uses the writable, ignored `.build-shell/` worktree on `shell-build`, based on core-v1. The untouched sibling `shell` remains at core-v1. Standalone Git writes work; chained Git mutations can be blocked.

Bridge validation: a separate read-only C probe resolved every SkyLight symbol and bridged operation selector successfully. No window moves or app launches have run. SwiftPM builds the integrated app without compiler warnings. The bundle script assembled `build/Minitile.app` and `build/mntl`, then failed signing because the sandbox cannot see a usable Apple Development identity.

## Verification

- 74 core tests, 12 shell tests and 5 sandbox-compatible IPC tests pass. Full socket tests were previously verified by agent 1 outside the sandbox; no IPC implementation changed here. Current logs are `.build/final-tests.log`.
- Shell tests cover multi-display show-before-hide ordering, ignoring unknown/already-placed windows, coordinate conversion, frame tolerance, semantic key flags, key-up retention across reloads, explicit drag IDs, stash-shortcut matching, smoke document restrictions, atomic config replacement/deletion/recreation, and ordered state persistence.
- `shellcheck` and `bash -n` pass for both shell scripts; the assembled Info.plist passes `plutil -lint`. The smoke helper compiles. The smoke scene assertion accepts matching fixture data and rejects both wrong-space and wrong-frame fixtures.
- No live AX discovery, window manipulation, key interception, application activation race, restart or display hotplug has been verified in this session. The original spike measurements remain unchanged.

## Implementation choices

- Use the first and last user desktop when extras exist; initial discovery ignores intermediate and fullscreen Spaces. Stable UUIDs identify grids; native identifiers are retained separately for switching.
- Retry startup stash discovery four times over one second; restore unreadable windows and report them. Sort startup windows by ID for deterministic adoption.
- Confirm disappearance after three CG snapshots; retry notifications at 150/400/900 ms and scan every three seconds. Preserve unknown AX reads and freeze lifecycle changes across session/display interruptions.
- Keep Swift 6 throughout; bridge C callback execution with explicit main-actor assumptions and use a locked value router on the keyboard thread. Letter bindings follow the current layout.
- Watch both config file and directory, including creation from an absent path; initial parse errors suspend startup rather than applying unrestricted defaults. Persist atomically on a serial queue.
- Restrict smoke discovery by exact document directory in addition to TextEdit's bundle ID. Stash recovery on smoke restart requires the runner's captured ID/pid pairs, protecting unrelated TextEdit windows.
- Worktree path and branch differ from the original handoff because of sandbox write boundaries. No core, IPC or mntl source was edited. Package changes are limited to CSkyLight ARC/framework settings and the shell test target.

## Resume

The user ran the smoke script from Terminal: signing succeeded, but startup never exposed its socket within 60 seconds. The run opened no TextEdit documents. The user has since confirmed granting Accessibility. Direct app launch and unified-log access are also blocked by the session sandbox; the next run must again start from Terminal. Startup now writes its stage and any failure to stderr as well as unified logging, and the smoke script prints those diagnostics on timeout.

From a normal Terminal, run `./.build-shell/scripts/smoke.sh` in the repository root. This rebuilds/signs, launches only with temporary config/state/socket paths and TextEdit restrictions, then validates and cleans up its own documents. Grant Accessibility to that `Minitile.app` when prompted; the script waits up to 60 seconds and can be rerun after granting. If signing still fails outside the sandbox, inspect `security find-identity -v -p codesigning` and supply the installed identity through `MINITILE_SIGN_IDENTITY`.

After automatic smoke passes, run the user-assisted checks from `agent-2-shell.md`: physical Ctrl+arrows, Cmd-Tab pre-emption, drag resize/swap/carry, trackpad stash bounce, and external-display unplug/replug. Update DESIGN.md only with observed results. The first unrestricted run and merge into main still require explicit approval.
