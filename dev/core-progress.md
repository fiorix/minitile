# Core implementation journal

Deliver the core, IPC and mntl described in `agent-1-core.md`, with Swift 6 concurrency, no app execution or window operations, and a commit per step. `DESIGN.md` is authoritative.

## Plan and completion evidence

- [x] 0: Bootstrap SwiftPM; build and test; commit on main, then branch core.
- [x] 1: Publish documented value types and IPC API; build; tag contract-v1.
- [x] 2: IPC and mntl implemented; all 17 IPC tests pass in the user's unrestricted run. Tag ipc-v1 with the final verified source.
- [x] 3: Model, placement and navigation; behavioral tests.
- [x] 4: Layout; exact geometry tests across orientations and variants.
- [x] 5: Moves, resize and drag handling; boundary and nudge tests.
- [x] 6: Floating, minimized and hidden windows; ownership and slot tests.
- [x] 7: Displays; merge/unmerge and unmanaged display tests.
- [x] 8: Commands, replies and events; grammar and data shape tests/documentation.
- [x] 9: Config; defaults, bindings and invalid input tests.
- [x] 10: Saved state and adoption; JSON round trip, stale identity and ordering tests.
- [x] 11: Final review, documentation and build are complete. All 74 core and 17 IPC tests pass without warnings, verified in separate target runs. Tag ipc-v1 and core-v1 with the final commit.

## Decisions and integration notes

- Reply, Event and JSONValue are defined in MinitileIPC and aliased by MinitileCore. Core depends on IPC to share the wire types without making mntl depend on the model or TOMLDecoder.
- DisplayInfo includes optional visibleSpace and stashSpace IDs for display inspection commands.
- The contract milestone has stub Engine and transport implementations. Agent 2 can start from contract-v1.

## Current checkpoint

The user initialized Git after the first session could not. Run Git writes as standalone approved commands; combining them with read-only helpers can cause sandbox index.lock failures for the whole command chain. The initial main commit includes the draft interfaces prepared before Git was available. contract-v1 is tagged, and the user was told to start agent 2. All requested core, IPC and mntl source is implemented and committed on core. No app or window operations have run.

Final checks: SwiftPM build passes with no warnings; 74 core tests pass locally. The user ran `swift test --filter MinitileIPCTests` outside the socket-restricting sandbox and supplied the complete passing output: all 17 IPC tests passed in 0.541 seconds, including streaming, concurrent clients, stale/live paths, 64 KiB framing, slow watchers, half-closed requests, large replies and CLI exit codes. Together these target runs cover all 91 tests. The local non-socket IPC subset also passed. Parameterized tests include every layout count/variant/orientation, bad commands, invalid config values and chords. Invariant checks exercise 600 mixed operations, 2,000-window startup, and 500-window config changes. Tests cover focused-display disconnection, reused IDs, and preserving the other three-slice cut during resize.

No agent-1 implementation work remains. Both ipc-v1 and core-v1 identify the final verified source; agent 2 can merge core-v1 directly. Agent 2 must handle `Action.setFrame` and `Action.openConfig`, and complete config reload before replying; see contract-changes.md. DESIGN.md documents the final grammar, JSON shapes and implementation interpretations. Live app and display testing remains agent 2's scope.

SwiftPM uses workspace-local caches to accommodate the session sandbox. TOMLDecoder 0.4.5 was fetched into its cache using git clone; the dependency is pinned by Package.resolved. Commands:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
```

The passing sandbox-compatible subset uses `--filter 'MinitileCoreTests|replyAlwaysEncodesData|jsonValueRoundTripsNestedValues|socketPathHonorsOverride|invalidSocketPathsFail|regularFileAtSocketPathIsPreserved'`. Build and subset logs are `.build/final-build.log` and `.build/final-tests.log` (ignored by Git).
