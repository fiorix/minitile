# Shell implementation journal

Implement the macOS shell from `agent-2-shell.md` against `core-v1`, preserving core sources. Live runs use temporary config/state/socket paths and TextEdit only. User participation is required for Accessibility, hardware keys and monitor tests. Merging into main remains subject to approval.

## Plan

- [x] 1: SkyLight bridge compiles with ARC. Symbol resolution is checked separately without moving windows.
- [ ] 2: Accessory app, startup checks, menu and signed bundle build.
- [ ] 3: IPC dispatch and raw debug commands.
- [ ] 4: AX discovery, lifecycle confirmation and startup stash adoption.
- [ ] 5: Display enumeration, desktop topology, debounce and bounce.
- [ ] 6: Ordered reconciliation, frame safeguards and focus.
- [ ] 7: Dedicated keyboard tap, drag commands and secure-input reporting.
- [ ] 8: Engine wiring, persistence and directory config watcher.
- [ ] 9: Automated isolated smoke test, then interactive validation.
- [ ] 10: Document verified behavior, gaps and interpretation choices.

## Checkpoint

The requested sibling worktree was created and fast-forwarded to core-v1, but this session forbids file edits there and refused its relocation. Implementation uses the writable, ignored `.build-shell/` worktree on `shell-build`, based on core-v1. The untouched sibling `shell` remains at core-v1. Standalone Git writes work; chained Git mutations can be blocked.
