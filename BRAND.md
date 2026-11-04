# minitile brand

## Direction

Quiet geometry. The product makes space by adding a little structure; the identity uses that same idea. Near-black surfaces carry fine three-dimensional wireframe windows, a restrained ice-blue accent, and slow, continuous movement. The forms come from the product's layouts rather than unrelated science-fiction imagery.

The lowercase wordmark is `minitile`. The mark is the three-window layout: one tall tile beside two smaller tiles. The central line is **A little order. A lot of space.** Consumer copy explains what happens to windows and what stays familiar. Project copy explains the model, the implementation, and how to contribute.

## Palette and typography

| Role | Value | Use |
| --- | --- | --- |
| Background | `#0b0d10` | Main canvas and brand images |
| Panel | `#13161b` | Surfaces and code examples |
| Text | `#eef0f4` | Headings and primary content |
| Secondary text | `#9da6b3` | Supporting copy |
| Ice blue | `#c8ddf8` | Mark, key edges, primary action |
| Rules | `#292f39` | Quiet dividers |

Use the system sans-serif stack for the website, with restrained weight and tight heading spacing. Use the system monospace stack for labels, coordinates, shortcuts, and code. SVG assets use Helvetica with Arial and generic sans-serif fallbacks. Fonts are not downloaded at runtime.

## Motion

The website uses one guided wireframe desktop, with a screen, keyboard, trackpad, mouse, and animated hands. Four selectable chapters teach navigation, focus and slot cycling, moves and layouts, and resizing. Keyboard navigation and four-finger swipes share one chapter; the examples use the same pre-populated grid. Cmd+Tab, Cmd+H, and mouse swaps have short supporting explanations. Keep the action readable: fingers reach the keys before windows move, enlarged Mac-style keycaps show the chord beside the screen, and captions explain each action. The grid map mirrors the screen's window geometry. As the visitor scrolls, the hands and input devices dissolve into the shortcut table; scrolling back restores them. The tour offers pause, replay, and manual stepping, stops outside the viewport or in a hidden tab, and starts paused with settled frames for reduced-motion preferences. Reduced motion omits the zoom and scroll dissolve. A static SVG provides the opening illustration without JavaScript.

The README retains the original sixteen-second wireframe grid loop: pages run horizontally across two vertically stacked workspaces, and one highlighted window moves between them while surrounding windows retile. It uses a looping GIF with a static PNG selected by `prefers-reduced-motion` where the Markdown host supports it. Hosts that strip the picture source may still play the GIF; keep its movement slow and avoid flashes. The static [welcome image](web/assets/welcome.png) is also available directly.

## Assets

| File | Purpose |
| --- | --- |
| `web/assets/mark.svg` | Standalone mark and favicon |
| `web/assets/wordmark.svg` | Horizontal mark and name |
| `web/assets/demo.svg` | Static fallback for the website's guided desktop tour |
| `web/assets/wireframe.svg` | Original static grid geometry |
| `web/assets/welcome.svg` | Scalable welcome composition |
| `web/assets/welcome.png` | Static welcome image |
| `web/assets/welcome.gif` | Animated README welcome image |
| `web/assets/download.svg` | README download placeholder |

The tour uses `web/demo-scenes.mjs` and `web/demo-art.mjs`, sharing tile layouts from `web/layouts.mjs`. The original grid and README assets use `web/geometry.mjs`. Regenerate those original SVGs with Node:

```sh
node scripts/branding/generate.mjs
```

To regenerate the PNG and GIF, install ImageMagick and supply an available font if ImageMagick cannot resolve its defaults. On macOS:

```sh
BRAND_FONT=/System/Library/Fonts/Supplemental/Arial.ttf node scripts/branding/generate.mjs --raster
```

The GIF is exported at 960x400, eight frames per second, with a limited palette and optimized frames. The editable SVG composition is 1200x500. Generated assets are checked in so serving the site and rendering the README require no build tooling.

## References

[Ruflo](https://github.com/ruvnet/ruflo) supplied the reference for a moving README welcome; [RuView](https://github.com/ruvnet/RuView) supplied the reference for dimensional wireframe imagery. Chan's local marketing site and animation components informed the quiet atmosphere and motion lifecycle. minitile's geometry, mark, and compositions are original; no reference images or animation code are bundled.
