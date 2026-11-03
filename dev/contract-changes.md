# Contract integration notes

## Additions after contract-v1

- `Action.setFrame(WindowID, Rect)` applies an explicit floating-window resize. Handle it with the same AX frame-write safeguards as tiled frames, before focus actions. Ordinary floating windows remain absent from `DisplayScene.frames`.
- `SavedState.activeDisplay` remembers command context when the current page is empty and no window has focus. It defaults to nil.

No names or existing meanings have changed.
