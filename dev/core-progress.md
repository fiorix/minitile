# Core implementation journal

Deliver the core, IPC and mntl described in `agent-1-core.md`, with Swift 6 concurrency, no app execution or window operations, and a commit per step. `DESIGN.md` is authoritative.

## Plan and completion evidence

- [x] 0: Bootstrap SwiftPM; build and test; commit on main, then branch core.
- [x] 1: Publish documented value types and IPC API; build; tag contract-v1.
- [ ] 2: IPC and mntl implemented and compiled; real socket tests are blocked by sandbox bind EPERM. User asked asynchronously to run `swift test --filter MinitileIPCTests`. Do not tag ipc-v1 until verified.
- [x] 3: Model, placement and navigation; behavioral tests.
- [x] 4: Layout; exact geometry tests across orientations and variants.
- [x] 5: Moves, resize and drag handling; boundary and nudge tests.
- [x] 6: Floating, minimized and hidden windows; ownership and slot tests.
- [x] 7: Displays; merge/unmerge and unmanaged display tests.
- [ ] 8: Commands, replies and events; grammar and data shape tests/documentation.
- [ ] 9: Config; defaults, bindings and invalid input tests.
- [ ] 10: Saved state and adoption; JSON round trip, stale identity and ordering tests.
- [ ] 11: Final review, build and tests; document interpretations; tag core-v1.

## Decisions and integration notes

- Reply, Event and JSONValue are defined in MinitileIPC and aliased by MinitileCore. Core depends on IPC to share the wire types without making mntl depend on the model or TOMLDecoder.
- DisplayInfo includes optional visibleSpace and stashSpace IDs for display inspection commands.
- The contract milestone has stub Engine and transport implementations. Agent 2 can start from contract-v1.

## Current checkpoint

The user initialized Git after the first session could not. Commands starting with an approved Git prefix work; putting a non-Git command before them can cause sandbox index.lock failures. The initial main commit includes the draft interfaces prepared before Git was available. contract-v1 is tagged, and the user was told to start agent 2. Core steps 3-7 now pass 42 tests, including 16 parameterized geometry cases. IPC runtime checks remain pending; its real-socket tests cannot bind under the session sandbox. No app or window operations have run.

Continue with the full command grammar and JSON data shapes, config parsing, and saved-state restoration. `Action.setFrame` is an additive shell requirement recorded in contract-changes.md. DESIGN.md still needs the final grammar, data shapes and implementation interpretations. The lifecycle commit initially had an inaccessible config setter; this is corrected in the display commit, along with activation test fixtures that had changed pid through windowUpdated (now correctly treated as replacement identity).

SwiftPM uses workspace-local caches to accommodate the session sandbox. TOMLDecoder 0.4.5 was fetched into its cache using git clone; the dependency is pinned by Package.resolved. Commands:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
```
