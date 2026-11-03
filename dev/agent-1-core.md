# Agent 1: core, IPC and mntl

You are building part of minitile, a small tiling window manager for macOS, and `mntl`, its command line client. Another agent builds the macOS-facing half at the same time. The user hands this file to you; it authorizes the work and the commits described here.

Read `DESIGN.md` at the repository root in full before anything else. It is the source of truth for behaviour. This file says what you own, in what order to work, and how to coordinate with the other agent. When the two disagree, `DESIGN.md` wins; tell the user.

## Work order for both agents

1. Agent 1 (you) bootstraps the repository and publishes the core contract as tag `contract-v1`. You then tell the user to start agent 2.
2. Both agents work in parallel, each in its own git worktree:
   - agent 1, branch `core`, in the repository root: `MinitileCore`, `MinitileIPC`, `mntl` and their tests;
   - agent 2, branch `shell`, in `../minitile-shell`: `CSkyLight`, the `minitile` app, the build and smoke scripts, live testing.
3. Agent 1 tags `ipc-v1` once the socket and `mntl` work, and `core-v1` when everything is done. Agent 2 merges `core` at those tags, wires it up and runs the live tests.
4. Agent 2 asks the user before merging into `main`.

## What you own

- `Sources/MinitileCore`, `Sources/MinitileIPC`, `Sources/mntl`, `Tests/MinitileCoreTests`, `Tests/MinitileIPCTests`.
- `Package.swift`, `.gitignore` and the stub files from step 0. After step 0, change `Package.swift` only for your own targets and keep changes small, since agent 2 merges it.
- Do not edit `Sources/CSkyLight`, `Sources/minitile` or `scripts/` after step 0.

## Rules

- You never run the minitile app and never touch windows. Your work needs no permissions; everything is verified with `swift build` and `swift test`.
- Do not change design decisions. Where `DESIGN.md` is ambiguous, pick the simplest reading that fits it, make `DESIGN.md` describe what you built, and list the choice in your final report. If `DESIGN.md` contradicts itself, or a choice would change behaviour the user can see in a way the doc does not cover, ask the user.
- Keep it small. minitile exists because HyprMac grew to 38k lines. No speculative abstraction, no protocols with one conformer, no configuration nobody asked for.
- Swift 6 language mode with strict concurrency. Core types are `Sendable` value types. `Engine.handle` does no I/O, never sleeps, and runs in time roughly linear in the number of windows.
- Tests use swift-testing (`import Testing`). Add a test for every rule in `DESIGN.md` that you implement.
- Commit at the end of each step with an imperative subject line and a short body when useful. No attribution trailers or signatures.
- Public API that agent 2 calls gets doc comments.

## Step 0: bootstrap

1. If the repository root is not a git repository, run `git init -b main`.
2. Write `.gitignore`: `.build*/`, `build/`, `.swiftpm/`, `*.app`, `.DS_Store`.
3. Write `Package.swift`. A starting point; fix whatever the toolchain (Swift 6.4, Xcode, macOS 27) rejects:

   ```swift
   // swift-tools-version: 6.2
   import PackageDescription

   let package = Package(
       name: "minitile",
       platforms: [.macOS(.v26)],
       products: [
           .executable(name: "minitile", targets: ["minitile"]),
           .executable(name: "mntl", targets: ["mntl"]),
       ],
       dependencies: [
           .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
       ],
       targets: [
           .target(name: "MinitileCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
           .target(name: "MinitileIPC"),
           .target(name: "CSkyLight"),
           .executableTarget(name: "minitile", dependencies: ["MinitileCore", "MinitileIPC", "CSkyLight"]),
           .executableTarget(name: "mntl", dependencies: ["MinitileIPC"]),
           .testTarget(name: "MinitileCoreTests", dependencies: ["MinitileCore"]),
           .testTarget(name: "MinitileIPCTests", dependencies: ["MinitileIPC"]),
       ]
   )
   ```

4. Add a minimal source file per target so the package builds. `CSkyLight` needs `include/CSkyLight.h` and one `.c` file. `minitile/main.swift` and `mntl/main.swift` print a placeholder.
5. `swift build` and `swift test` pass. Commit on `main`, then create branch `core` and continue there.

## Step 1: the contract

1. In `MinitileCore`, define the types from "Architecture" in `DESIGN.md`: `WindowID`, `DisplayID`, `Rect`, `Point`, `WindowInfo`, `DisplayInfo`, `Input`, `Output`, `Scene`, `DisplayScene`, `Action`, `Reply`, `Event`, `Config`, `SavedState`, and `Engine` with `init(config:)`, `handle(_:) -> Output` and `savedState()`. Bodies can be stubs. Also expose the chord type the shell matches keys against (modifiers plus a key name) and the default config.
2. In `MinitileIPC`, define the public API with stub bodies:
   - a server created with a socket path, a handler, and the dispatch queue the handler runs on (the shell passes `.main`). The handler receives the request's `argv` and a completion that takes a `Reply`. The server also has `broadcast(event:)` for `watch` clients;
   - a client that sends one request and returns the reply, plus a streaming call for `watch`;
   - the socket path resolution: `MINITILE_SOCKET`, else `confstr(_CS_DARWIN_USER_TEMP_DIR)` plus `minitile.sock`.
3. `swift build` passes. Commit, tag the commit `contract-v1`, and tell the user: "contract-v1 is tagged; start agent 2."
4. After the tag, additive changes are free: new cases, new fields with defaults, new functions. Avoid renames, removals and changed meanings. If one is unavoidable, add it to `dev/contract-changes.md` (create it if needed) with what agent 2 must change on merge.

## Step 2: IPC and mntl

Agent 2 needs these early, so they come before the core logic.

- Server: the protocol, socket permissions, peer check, stale-socket and second-instance handling, request size limit and error handling are specified under "Command line: mntl" in `DESIGN.md`. Accept on a background queue; handle several clients; never block the handler queue on a slow client.
- `watch`: after the `ok` response, the connection stays open and receives every `broadcast` event as one JSON line. Drop a watcher whose writes fail.
- `mntl`: `mntl [--json] [--socket PATH] <argv...>`. It prints the reply's `text`, or its `data` as JSON with `--json`, and exits 0, 1 or 2 as specified. With no arguments it sends `help`; if minitile is unreachable it prints a short local usage and exits 2.
- Tests: round trips over a real socket in a short temporary path (Unix socket paths are limited to 104 bytes): ok and error replies, a malformed request, an oversized request, two clients at once, a `watch` client receiving broadcasts, a stale socket file, a second server on a live path.
- Tag `ipc-v1` and tell the user, so they can relay it to agent 2.

## Step 3: model, placement and navigation

Implement the "Model", "Placement" and "Navigation and focus" rules from `DESIGN.md`: displays, workspaces, pages, slots, placement with spill, the view following a new window from the frontmost app, close and slot reuse, empty page and workspace lifetime, page and workspace next and prev, last-focused window per page and last-viewed page per workspace, focus moving to a window on a hidden page.

`appActivated(pid)`: if the app has a window on a shown page, nothing changes. Otherwise show the page holding its most recently focused window (or its first window in grid order) and emit no focus action, since macOS is already activating it.

Tests cover each rule, including spill onto a new page, placement into a freed slot on an earlier page, removal of empty pages and workspaces when the view leaves them, and pre-emption choosing the right page.

## Step 4: layout geometry

Implement "Layout" and its "Geometry" subsection: frames for 1 to 4 windows, both variants, landscape and portrait, gaps, padding, rounding, ratio defaults, clamps and resets. Tests check exact frames for every count, variant and orientation, using a display with a non-zero origin so origin mistakes show up.

## Step 5: moving windows

- Nudge, with the four-line example from "Keys" as a test, and the edge cases.
- Carry to the workspace above or below, including into a new workspace past the last.
- `window move` to a page, workspace or display; `window swap`; `window resize` for tiled and floating windows.
- `dragEnded`: the mapping under "Layout", "Mouse": edge drags set ratios, corner drags set both, border-edge drags snap back, moves swap with the tile under the cursor or snap back. A snap back puts the window in `Output.rewrite`.
- The focus action follows the moved window where `DESIGN.md` says focus follows.

## Step 6: floating, minimized and hidden windows

"Floating windows" and "Minimized and hidden windows": float rules (`tileable`, `float_apps`, the toggle), floating windows belonging to their page, minimized and app-hidden windows keeping their slots, `window hide` and `window show`. Windows of apps outside a non-empty `only_apps` are ignored entirely.

## Step 7: displays

"Displays": merge onto the primary display when a display goes away, unmerge when it returns (including windows opened in the meantime and the "workspace above" rule), workspaces created while merged, unmanaged displays (`unmanagedReason`), and each window stashed on the stash of the display that currently hosts its workspace. Tests run a merge and unmerge round trip and check the scene on both sides.

## Step 8: commands, replies and events

- The full grammar from the table under "Command line: mntl": nouns, verbs, addressing by window ID, index, `next` and `prev`, and the defaults. `help` returns the grammar. Unknown or malformed commands return `ok: false` with a message that says what was expected.
- Every reply has a readable `text` (aligned columns for `list`, one field per line for `info`) and a stable `data` shape. Document the `data` shapes in `DESIGN.md`, because people will script against them.
- `state` dumps the whole model. Events for `watch` cover focus, page shown, window added, removed and moved, display change and config reload.
- `debug` is not a core command. Return `ok: false` if it ever reaches the core.

## Step 9: config

"Config": parse with TOMLDecoder into `Config`, with the defaults when the file or a key is absent; merge bindings over the defaults, `""` unbinds; parse and validate chords; reject bad values with a message naming the key. The default bindings must use the final command grammar, so update the example in `DESIGN.md` to match it. Tests cover an empty file, every key, an unbinding, and errors.

## Step 10: saved state and startup

"State and lifecycle": `savedState()` and the `.started` input. Restore windows whose ID and pid still match, drop the rest, adopt unknown windows (visible ones first, stash ones after). Tests cover a round trip through JSON, a changed pid, and adoption order.

## Step 11: finish

- `swift build` and `swift test` pass with no warnings in your targets.
- `DESIGN.md` describes what you built: the final command grammar, the `data` shapes, and anything you had to decide.
- Tag `core-v1` and give the user a final report:
  - what is done;
  - test count;
  - every place where you interpreted `DESIGN.md`;
  - anything agent 2 must know when merging (point to `dev/contract-changes.md` if it exists).
