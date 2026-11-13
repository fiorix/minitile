# minitile website

A static consumer website using HTML, CSS, and browser JavaScript modules. A single wireframe desktop tour moves windows while the keys of each shortcut light up on a keyboard, and swipes show on a trackpad. No framework, dependency installation, or build step is required.

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

The tests verify layout partitions, valid scene states, window conservation, focus versus position swaps, page splitting and merging, resizing, four-finger swipe directions, layout cycling, animation continuity, and reduced-motion frames. They also check the grid's exact projection of window positions and sizes, that every key a step lights is on the keyboard, and that swipe fingertips move in the swipe's direction and stay on the trackpad. The original geometry tests still cover the shared README artwork. Browser verification should cover every chapter and step, narrow and wide screens, chapter selection and wrapping, step dots, keyboard focus, download navigation, the setup section and its diagram, reduced motion, pause, offscreen suspension, and JavaScript disabled.

The tour is an illustration, not a native app recording or a second implementation of the window manager. Its controls change only the example on the page. It does not capture operating-system shortcut chords.

## Guided tour

- `demo-scenes.mjs` contains four independently replayable chapters with explicit window states and timed actions. It also samples transitions and reuses `layouts.mjs` for tile geometry.
- `demo-art.mjs` renders the SVG monitor, app windows, workspace map, keyboard, and trackpad in one coordinate system. The map uses the same animated window rectangles as the screen, including their aspect ratio, gaps, and resize proportions. A step's keys light up on the keyboard while it plays; swipes show four lit fingertips sliding across the trackpad. Unlit keys stay faint so the lit ones read at a glance.
- `main.mjs` owns playback and accessible controls: chapter tabs and a play button above the picture, and below it one action line (the chord as keycaps, or the swipe, beside a short caption) and a dot per step. The current step's dot fills as it plays; choosing a dot pauses on that step's settled frame. The tour pauses outside the viewport and in hidden tabs. Reduced motion starts paused and shows settled states. Keyboard focus on the tour's controls pauses autoplay.
- `assets/demo.svg` is a standalone snapshot of the opening illustration, used before JavaScript loads and when it is disabled. After changing the illustration or its styles, rebuild it with `scripts/branding/snapshot-demo.mjs`, which embeds the rules between the `illustration:start` and `illustration:end` markers in `style.css`.

The four chapters teach navigation with Control+arrows and four-finger swipes, focus cycling and slot swaps, window moves and layout cycling, and resizing. Control+Option+Space cycles layouts, matching Control+Option+arrows for resizing. The move chapter shows both split and merge behavior. Cmd+Tab, Cmd+H, and mouse swaps appear as supporting explanations. Chapter selection resets the example to that chapter's starting state; every chapter uses the same pre-populated grid.

## Setup section

The page explains, in its own section and from the hero, that every display needs a second desktop added by hand in Mission Control: minitile keeps hidden pages there and macOS does not let apps create desktops. Keep this visible rather than behind a disclosure, and keep its wording in step with the app's menu and notice and the README's getting-started steps.

## Publication

The site is served at https://minitile.app from GitHub Pages. `.github/workflows/pages.yml` runs `npm test`, then publishes `index.html`, `style.css`, the browser modules and `assets/` whenever `main` changes under `web/`; `serve.mjs`, the tests and this file are not published. Asset paths are relative, so the site also works under a repository subpath. `.nojekyll` keeps the output static.

The download button and the README badge point at the latest release's `minitile.dmg`, whose name stays the same across versions.

Not yet set: a canonical URL and an absolute `og:image` URL for `assets/welcome.png`.

See [BRAND.md](../BRAND.md) for the palette, identity, and reproducible asset exports.
