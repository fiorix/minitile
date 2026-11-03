# Core implementation journal

Deliver the core, IPC and mntl described in `agent-1-core.md`, with Swift 6 concurrency, no app execution or window operations, and a commit per step. `DESIGN.md` is authoritative.

## Plan and completion evidence

- [ ] 0: Bootstrap SwiftPM; build and test; commit on main, then branch core.
- [ ] 1: Publish documented value types and IPC API; build; tag contract-v1.
- [ ] 2: Implement sockets and mntl; real socket failure and streaming tests; tag ipc-v1.
- [ ] 3: Model, placement and navigation; behavioral tests.
- [ ] 4: Layout; exact geometry tests across orientations and variants.
- [ ] 5: Moves, resize and drag handling; boundary and nudge tests.
- [ ] 6: Floating, minimized and hidden windows; ownership and slot tests.
- [ ] 7: Displays; merge/unmerge and unmanaged display tests.
- [ ] 8: Commands, replies and events; grammar and data shape tests/documentation.
- [ ] 9: Config; defaults, bindings and invalid input tests.
- [ ] 10: Saved state and adoption; JSON round trip, stale identity and ordering tests.
- [ ] 11: Final review, build and tests; document interpretations; tag core-v1.

## Decisions and integration notes

- Reply, Event and JSONValue are defined in MinitileIPC and aliased by MinitileCore. Core depends on IPC to share the wire types without making mntl depend on the model or TOMLDecoder.
- DisplayInfo includes optional visibleSpace and stashSpace IDs for display inspection commands.
- The contract is a draft with stub Engine and transport implementations. No milestone is tagged; agent 2 should not start yet.

## Current checkpoint

Bootstrap files and the initial public contract have been written. MinitileIPC and MinitileCore compile directly with `swiftc -swift-version 6` without warnings. Full package verification and all commits remain pending.

The session's filesystem policy makes `.git` read-only. `git init -b main` failed with `Operation not permitted`; requesting escalation was rejected because sandbox approvals are disabled. There is still no Git repository, branch, commit or tag.

SwiftPM cannot fetch TOMLDecoder because this session cannot resolve github.com. Redirecting caches into `.build` and disabling SwiftPM's nested subprocess sandbox resolved its earlier cache and sandbox-launch errors, but dependency resolution still fails. The outer session sandbox remains active.

Resume with Git writes and dependency access enabled. Separate the bootstrap from the draft contract when creating the first two commits, verify with SwiftPM, create branch core, then tag contract-v1 and tell the user to start agent 2. Do not claim that steps 0 or 1 have passed until the package checks and tags exist.

Commands used to check the draft contract independently of the unavailable package dependency:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swiftc -swift-version 6 -emit-library -emit-module -module-name MinitileIPC Sources/MinitileIPC/*.swift -o .build/libMinitileIPC.dylib -emit-module-path .build/MinitileIPC.swiftmodule
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swiftc -swift-version 6 -emit-library -emit-module -module-name MinitileCore -I .build -L .build -lMinitileIPC Sources/MinitileCore/*.swift -o .build/libMinitileCore.dylib -emit-module-path .build/MinitileCore.swiftmodule
```
