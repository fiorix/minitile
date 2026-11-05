# minitile brand

## Direction

Light comes from lines. The product makes space by adding a little structure; the identity uses that same idea. Near-black surfaces carry translucent glass and fine wireframe lines, and a single neon colour marks state: the focused window, the shown page, the primary action. Everything else stays unlit. The forms come from the product's layouts rather than unrelated science-fiction imagery.

A lit line is drawn the way a neon tube looks: a pale core inside a cyan halo. The website and minitile's own panels (`PanelStyle` in the app, see "Visual style" in `DESIGN.md`) share the palette and this rule.

The central line is **A little order. A lot of space.** Consumer copy explains what happens to windows and what stays familiar. Project copy explains the model, the implementation, and how to contribute.

## Logo

The mark is a three-window layout in a frame, on a 40-unit grid: a frame 34 units square at (3, 3) with corners rounded to 7 units, and inside it one wide tile over two small ones, 4 units apart, with 1.5-unit corners: the top tile at (9, 9), 22 by 9, and the lower tiles at (9, 22) and (22, 22), 9 by 9. The top tile is the highlight, a solid lit neon rectangle with the neon halo; the frame and the two lower tiles are unlit wire outlines with no fill, 1.5 units wide. It reads as an m whose top bar is lit and whose legs are not. As the menu bar item it is a template image: outlines for the frame and lower tiles, the top tile filled, and the workspace and page over it.

The wordmark is a custom monoline lowercase `minitile`, not set in a font: a 20-unit x-height, 27-unit ascenders, and one 2.2-unit stroke with round ends for stems, arches and the bowl of the e. The three i-dots are small square tiles that echo the mark's three windows; the last one is lit. The t's crossbar gets extra room before it and its foot tucks toward the next letter.

In the horizontal lockup the mark's tiles span the wordmark's ascender to its baseline, 9 units before the first stem. Use the lockup on dark backgrounds only; the unlit parts are drawn for near-black.

## Palette and typography

| Role | Value | Use |
| --- | --- | --- |
| Void | `#05070c` | Page and panel background, brand images |
| Wire | `#7d9cc9` | Every unlit line and glass fill, always at an opacity (about 15-60%) |
| Ink | `#e8f0fc` | Headings and primary content |
| Dim | `#8e9cb4` | Supporting copy |
| Faint | `#6f7e97` | Notes and tertiary labels on the website |
| Neon | `#53e9ff` | State only: focus, the shown page, the primary action; the halo of a lit line |
| Neon core | `#dcfbff` | The stroke of a lit line |
| Bloom | `#2d5cff` | Faint background washes on the website, never lines or text |

Glass is a wire gradient from about 7% to 2% opacity with a hairline wire edge and, on the website, a backdrop blur. Lines are hairlines: 0.5 to 1 px for structure and 1 to 1.5 px for lit lines.

Use the system sans-serif stack for the website. Display type is thin (weight 200) with tight tracking; in the hero, "A little order." is set tight and "A lot of space." is set wide and lit, so the spacing acts out the line. Use the system monospace stack only for coordinates, counters, chords and code. SVG assets use Helvetica Neue with Helvetica, Arial and generic sans-serif fallbacks. Fonts are not downloaded at runtime.

## Motion

The website uses one guided wireframe desktop: a screen with a grid map beside it, and a keyboard and trackpad below. Four selectable chapters teach navigation, focus and slot cycling, moves and layouts, and resizing. Keyboard navigation and four-finger swipes share one chapter; the examples use the same pre-populated grid. Cmd+Tab, Cmd+H, and mouse swaps have short supporting explanations. Keep the action readable and plain: a step's keys light up on the keyboard before the windows move, swipes show four lit fingertips sliding across the trackpad, and one line under the picture shows the chord and a short caption. The focused window, pressed keys, swipe fingertips and the shown page in the grid map are lit; the rest of the illustration is wire. The grid map mirrors the screen's window geometry. The only controls are chapter tabs, play and pause, and a dot per step. The tour stops outside the viewport or in a hidden tab and starts paused with settled frames for reduced-motion preferences. A static SVG provides the opening illustration without JavaScript.

The README retains the sixteen-second wireframe grid loop: pages run horizontally across two vertically stacked workspaces, and one highlighted window moves between them while surrounding windows retile. It uses a looping GIF with a static PNG selected by `prefers-reduced-motion` where the Markdown host supports it. Hosts that strip the picture source may still play the GIF; keep its movement slow and avoid flashes. The static [welcome image](web/assets/welcome.png) is also available directly.

## Assets

| File | Purpose |
| --- | --- |
| `web/assets/mark.svg` | Standalone mark |
| `web/assets/favicon.svg` | The mark on a void tile, for light and dark tab bars |
| `web/assets/wordmark.svg` | Horizontal lockup of the mark and wordmark |
| `web/assets/demo.svg` | Static fallback for the website's guided desktop tour |
| `web/assets/wireframe.svg` | Original static grid geometry |
| `web/assets/welcome.svg` | Scalable welcome composition |
| `web/assets/welcome.png` | Static welcome image |
| `web/assets/welcome.gif` | Animated README welcome image |
| `web/assets/download.svg` | README download placeholder |

The mark and wordmark are built by `scripts/branding/logo.mjs`. The tour uses `web/demo-scenes.mjs` and `web/demo-art.mjs`, sharing tile layouts from `web/layouts.mjs`. The original grid and README assets use `web/geometry.mjs`. Regenerate the SVG assets with Node:

```sh
node scripts/branding/generate.mjs
```

To regenerate the PNG and GIF, add `--raster`. Frames are rendered by headless Chrome, which draws the filters, tracking and font weights faithfully, and the GIF is assembled with ImageMagick. Set `CHROME` if Chrome is not in `/Applications` or `~/Applications`.

```sh
node scripts/branding/generate.mjs --raster
```

The GIF is exported at 960x400, eight frames per second, with a limited palette and optimized frames. The editable SVG composition is 1200x500. Generated assets are checked in so serving the site and rendering the README require no build tooling.

`web/assets/demo.svg` is rebuilt from the rendered page by `scripts/branding/snapshot-demo.mjs`; its header comment has the steps. It embeds the rules between the `illustration:start` and `illustration:end` markers in `web/style.css`.

## References

[Ruflo](https://github.com/ruvnet/ruflo) supplied the reference for a moving README welcome; [RuView](https://github.com/ruvnet/RuView) supplied the reference for dimensional wireframe imagery. Chan's local marketing site and animation components informed the quiet atmosphere and motion lifecycle. minitile's geometry, mark, wordmark, and compositions are original; no reference images or animation code are bundled.
