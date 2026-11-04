# minitile website

A static consumer website using HTML, CSS, and browser JavaScript modules. A single wireframe desktop tour pairs window movement with animated hands on a keyboard, trackpad, and mouse. No framework, dependency installation, or build step is required.

## Preview

```sh
cd web
npm run dev
```

Open `http://127.0.0.1:4173`. Set `PORT=4180` to use another port. The server binds to loopback and serves this directory. Reload the page after editing; there is no live reload.

## Checks

```sh
npm test
```

The tests verify layout partitions, valid scene states, window conservation, focus versus position swaps, page splitting and merging, resizing, four-finger swipe directions, layout cycling, animation continuity, reduced-motion frames, and fingertip positions on demonstrated keys. They also check the grid's exact projection of window positions and sizes, keycap zoom endpoints, and reversible scroll-dissolve progress. The original geometry tests still cover the shared README artwork. Browser verification should cover every chapter and action, narrow and wide screens, scene selection and wrapping, replay, manual stepping, keyboard focus, download navigation, setup disclosure, reduced motion, pause, offscreen suspension, scroll dissolution in both directions, and JavaScript disabled.

The tour is an illustration, not a native app recording or a second implementation of the window manager. Its controls change only the example on the page. It does not capture operating-system shortcut chords.

## Guided tour

- `demo-scenes.mjs` contains four independently replayable chapters with explicit window states and timed actions. It also samples transitions and reuses `layouts.mjs` for tile geometry.
- `demo-art.mjs` renders the SVG monitor, app windows, workspace map, keyboard, pointing devices, and wireframe hands in one coordinate system. The map uses the same animated window rectangles as the screen, including their aspect ratio, gaps, resize proportions, and drag positions. Active keys zoom from their wireframe positions to larger Mac-style keycaps beside the screen, with symbols and modifier names. Hands reach the highlighted keycaps; trackpad actions show four fingertips and matching swipe trails.
- `main.mjs` owns playback and accessible controls. The tour pauses outside the viewport and in hidden tabs. Reduced motion starts paused and shows settled states; Next action steps through them without interpolation. Keyboard focus on scene controls pauses autoplay.
- `demo-scroll.mjs` ties the dissolve to scroll position: the hands and input devices fade and soften as the shortcut table appears in their place. Scrolling back restores the devices. Reduced motion and JavaScript-disabled pages keep the illustration and table in ordinary document flow. The shortcut table directly follows the demo; supporting feature copy comes afterward.
- `assets/demo.svg` is a standalone snapshot of the opening illustration, used before JavaScript loads and when it is disabled. After changing the illustration, refresh this snapshot from the opening, paused SVG with its illustration styles embedded.

The four chapters teach navigation with Control+arrows and four-finger swipes, focus cycling and slot swaps, window moves and layout cycling, and resizing. Control+Option+Space cycles layouts, matching Control+Option+arrows for resizing. The move chapter shows both split and merge behavior. Cmd+Tab, Cmd+H, and mouse swaps appear as supporting explanations. Chapter selection resets the example to that chapter's starting state; every chapter uses the same pre-populated grid.

## Publication

Serve the contents of `web/` as the website root. Asset paths are relative, so the site also works under a repository subpath on GitHub Pages. `.nojekyll` keeps the output static. Nothing in this worktree publishes or deploys automatically.

Before a public release:

- Replace the disabled download button and its release note with a real release URL and verified requirements. Update the matching README badge and download section.
- Add the public repository link once the GitHub repository exists.
- Set the canonical website URL and an absolute `og:image` URL for `assets/welcome.png` after the final host is known.

See [BRAND.md](../BRAND.md) for the palette, identity, and reproducible asset exports.
