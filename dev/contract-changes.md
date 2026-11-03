# Contract integration notes

## Additions after contract-v1

- `Action.setFrame(WindowID, Rect)` applies an explicit floating-window resize. Handle it with the same AX frame-write safeguards as tiled frames, before focus actions. Ordinary floating windows remain absent from `DisplayScene.frames`.
- `SavedState.activeDisplay` remembers command context when the current page is empty and no window has focus. It defaults to nil.
- `Action.openConfig` opens the TOML file in the user's editor for `config open`; the menu item uses this command.
- `config reload` returns `Action.reloadConfig`. The shell must complete the reload before replying, replace the reply with an error if parsing fails, and send `.configLoaded` only on success.
- `Config.parse(String?) throws -> Config` parses TOML contents; pass nil for an absent file. `ConfigError` names the key. `Chord.init(_:)` parses a chord and `description` gives its canonical spelling.

No names or existing meanings have changed.

## Behaviour changes in core-v2

- The engine no longer sends a focus action after the focused window closes, is minimized, or its app is hidden. It clears focus to nil without changing the viewed page and waits for macOS to choose the next window through `focusChanged`.
- Refocusing after `window hide`, config reload and display changes is unchanged because those transitions are caused by minitile.
- Activation pre-emption ignores minimized windows, including when choosing a target page. App-hidden windows still count because activation unhides them.
- A lone tiled window nudged past a full neighbor scans in the nudge direction for room, inserting a page at that end if none has room. Edge nudges that do nothing emit no events or actions.
