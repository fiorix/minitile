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

The hero's original wireframe scene runs on a sixteen-second loop. Pages run horizontally across two vertically stacked workspaces. One highlighted window moves across a page, down to the next workspace, and back around; surrounding windows retile as it moves. Labeled axes keep the product model clear in both moving and static versions. Keep motion behind the message, never across text. The website respects reduced-motion preferences, offers a pause control, stops canvas work outside the viewport or in a hidden tab, and retains a static SVG fallback when JavaScript or canvas is unavailable.

The README uses a looping GIF with a static PNG selected by `prefers-reduced-motion` where the Markdown host supports it. Hosts that strip the picture source may still play the GIF; keep its movement slow and avoid flashes. The static [welcome image](web/assets/welcome.png) is also available directly.

## Assets

| File | Purpose |
| --- | --- |
| `web/assets/mark.svg` | Standalone mark and favicon |
| `web/assets/wordmark.svg` | Horizontal mark and name |
| `web/assets/wireframe.svg` | Static hero geometry |
| `web/assets/welcome.svg` | Scalable welcome composition |
| `web/assets/welcome.png` | Static welcome image |
| `web/assets/welcome.gif` | Animated README welcome image |
| `web/assets/download.svg` | README download placeholder |

The website and exported assets share geometry from `web/geometry.mjs`. Regenerate the SVGs with Node:

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
