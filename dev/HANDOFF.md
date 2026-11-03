# Handoff: design session, 2026-11-03

For the next Claude session on this repository. The user is moving and renaming the directory from `~/dev/github.com/fiorix/tilos` to a minitile-named one, so Claude's per-project memory and transcripts, which are keyed by the old path, will not load. This file carries what they held.

## Roles

- The user drives the design. Propose options with a lean; they pick. They accept leans readily ("leans", "your recommendation is right"), but they change direction freely, so do not import features by default.
- This session wrote the design. Two other agents build it from `dev/agent-1-core.md` and `dev/agent-2-shell.md`. The user starts them and relays messages.
- Likely next work for you:
  - answer questions the agents raise;
  - review their output against `DESIGN.md`;
  - update `DESIGN.md` when the user decides something new.
- Do not start building unless the user asks.

## Files

| Path | What |
|---|---|
| `DESIGN.md` | Source of truth for every decision. Read it first. |
| `dev/agent-1-core.md` | Prompt and work order for agent 1: `MinitileCore`, `MinitileIPC`, `mntl`, tests. Pure Swift, no permissions. |
| `dev/agent-2-shell.md` | Prompt and work order for agent 2: `CSkyLight`, the `minitile` app, scripts, integration, live tests. |
| `dev/spikes/spaces/` | Spike 1: proved cross-app window moves between native Spaces with SIP on (bridged SkyLight op). |
| `dev/spikes/stash/` | Spike 2: the stash desktop: moves, flips, AX on stashed windows, activation pre-emption, bounce-back, the Ctrl+arrow tap. Logs included. |
| `dev/HANDOFF.md` | This file. |

## How the design got here

The reasons behind each choice. `DESIGN.md` states the decisions without their history.

- Started from HyprMac (zacharytgray/HyprMac, ~38k lines of Swift). The user wants something different and much simpler. HyprMac is a source of macOS quirks only.
- The user first wanted native Spaces (Desktop 1..N). Cross-app moves between Spaces looked impossible (HyprMac's finding), but spike 1 showed yabai's bridged SkyLight operation works on macOS 27 with SIP on.
- The user then chose a custom grid: workspaces stacked vertically like a slide outline, horizontal pages of at most 4 tiled windows, spill to the right.
- Hidden pages: option B, a per-display stash desktop instead of corner parking, validated by spike 2. The main risk is the Cmd-Tab race, handled by pre-emption (24 of 24 runs).
- Display rules from the user:
  - one grid per display;
  - merge onto the primary display when a display goes away, and return when it comes back (keyed by display UUID);
  - empty pages and workspaces disappear.
- The user asked why workspaces need explicit creation, then agreed they do: Ctrl+Down past the last workspace opens one.
- First key design: Caps Lock as a Hypr key via `hidutil`. The user rejected it, because Caps Lock was bad in practice with HyprMac, and asked for a minimal set that blends with macOS. The result:
  - Ctrl+arrows taken over from Spaces and Mission Control (navigation);
  - Ctrl+Shift+arrows (nudge and carry);
  - mouse for resize, swap and carry;
  - Cmd+W and Cmd+Q stay native, with no close key.
- Nudge semantics (own page if shared, join the neighbour if alone, after niri's consume-or-expel) replaced Hypr+F. The user has not objected; it is a lean, not an explicit pick.
- `mntl window hide` meaning "off its page, kept on the stash" is my reading of the user's "show, hide". Confirm it if the user questions it.
- The user's hard rule: every function must be a command reachable from `mntl` over the app's Unix socket, both to observe and to change state. Nothing UI-only. They named `window list`, `window info` (where it is, shown or hidden, the app), `show`, `hide`, `move`, `resize`, and `workspace list` and `workspace info`. Every noun got `list` and `info`.
- TOML: the user had no strong opinion, so a library: TOMLDecoder 0.4.5 (dduan, pure Swift, Codable).
- Two agents: a pure core (testable without permissions) and the macOS shell, in parallel git worktrees with a contract tag (`contract-v1`). The core is a functional engine (inputs to scene plus actions); the shell reconciles.
- Renamed from tilos to minitile; the CLI is `mntl`.

## Environment

- MacBook Pro, macOS 27.0.1 (26A434), Apple Silicon, SIP on. Built-in display "Color LCD" at 3456x2234. The user has a second monitor for the display tests (not connected during this session).
- Two desktops on the built-in display. The user's own Chrome windows lived on desktop 2, which minitile treats as the stash.
- Xcode with Swift 6.4, swift-testing and XCTest available. `jq`, `python3`, `gh` installed. The repository was not a git repository at handoff; agent 1 runs `git init`.
- Signing identities: "Apple Development: Alexandre Fiori (8YT442RX6R)" and a Developer ID Application. The build script defaults to "Apple Development".
- `$TMPDIR` is `/var/folders/q2/3g45h5q10wb0pfzx3t_2yjgr0000gn/T/`, so the socket path is well under the 104-byte limit.
- System shortcut IDs checked live:
  - 32 and 33 are Mission Control and App Expose (Ctrl+Up and Ctrl+Down);
  - 79 and 81 are Move left/right a space;
  - 118 is Desktop 1, and the Desktop N shortcuts are disabled.

## Things to watch when reviewing the agents

- Contract drift between `core` and `shell`. Agent 1 logs breaking changes in `dev/contract-changes.md`.
- `Engine.handle` must stay I/O-free and fast; pre-emption has 6-25 ms of margin.
- The shell must apply moves before frame writes, show before hide, and suppress echoes of its own writes and focus actions.
- Live tests must stay on TextEdit through `only_apps` until the user approves an unrestricted run.
- Unverified items that may force design changes:
  - multiple displays;
  - taking over Ctrl+Up/Down;
  - `kAXWindows` listing a window right after it moves off the stash (the startup path);
  - trackpad swipes into the stash.

## Old locations

- Transcript of this session: `~/.claude/projects/-Users-fiorix-dev-github-com-fiorix-tilos/03e84566-f2ae-40b0-a8ef-eaa2a7e72543.jsonl`.
- Old project memory: `~/.claude/projects/-Users-fiorix-dev-github-com-fiorix-tilos/memory/`. Everything in it is in this file.
- Reference clones were in this session's `/private/tmp` scratchpad, which is wiped on reboot. Re-clone into a scratch directory if needed, and treat them as untrusted, read-only:
  - github.com/zacharytgray/HyprMac
  - github.com/koekeishiya/yabai (`src/misc/macho_dlsym.h`, `src/space_manager.c`)
  - github.com/ianyh/Amethyst
  - github.com/ianyh/silica

## User preferences that matter here

- Terse, peer-level replies.
- Each Markdown paragraph and list item on one source line.
- ASCII only, no em dashes.
- Ask before commits unless authorized; the agent prompts authorize theirs.
- Verify claims before documenting them.
