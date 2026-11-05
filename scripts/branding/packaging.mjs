// The macOS app icon and the release disk image background, drawn from the mark and lockup in logo.mjs.

import { lockup, markContent, palette } from "./logo.mjs";

const n = (value) => +value.toFixed(2);
const sans = "Helvetica Neue,Helvetica,Arial,sans-serif";

// One continuous ("squircle") corner as Apple draws rounded squares, in units of the corner radius: points measured
// from the corner along the edge the path arrives on (a) and across it (b), as a line end and three cubic segments.
const corner = [
  [1.52866483, 0],
  [1.08849323, 0, 0.86840689, 0, 0.66993427, 0.065496],
  [0.63149399, 0.074911],
  [0.37282392, 0.16905899, 0.16906013, 0.37282401, 0.07491176, 0.63149399],
  [0, 0.86840701, 0, 1.08849299, 0, 1.52866483],
];

/** A rounded rectangle path with continuous corners of nominal radius `r`. */
export function continuousRect(x, y, width, height, r) {
  const right = x + width,
    bottom = y + height;
  // Each corner maps (a, b) to a point; a runs back along the edge the path arrives on, b into the next edge.
  const corners = [
    (a, b) => [right - a * r, y + b * r],
    (a, b) => [right - b * r, bottom - a * r],
    (a, b) => [x + a * r, bottom - b * r],
    (a, b) => [x + b * r, y + a * r],
  ];
  const at = (point, values) => {
    const out = [];
    for (let i = 0; i < values.length; i += 2) out.push(point(values[i], values[i + 1]).map(n).join(" "));
    return out.join(" ");
  };
  let d = `M${at(corners[3], corner[4].slice(4))}`;
  for (const point of corners) {
    const [start, curve, line, arc, end] = corner;
    d += `L${at(point, start)}C${at(point, curve)}L${at(point, line)}C${at(point, arc)}C${at(point, end)}`;
  }
  return `${d}Z`;
}

// Apple's macOS icon grid: a 1024 px canvas with a rounded-square tile 824 px across, inset 100 px.
const tile = { inset: 100, size: 824, radius: 185.4 };

/**
 * The app icon at `size` px. From 64 px up it is the framed mark at 60% of the tile with its halo; at 16 and 32 px the
 * hairlines and halo would blur together, so the mark is redrawn on the pixel grid, larger, with solid strokes, and at
 * 16 px the tile's edge is left out because it would merge with the frame.
 */
export function appIconSVG(size = 1024) {
  const { inset, size: side, radius } = tile;
  const edge = size <= 32 ? 1024 / size : 4;
  const shape = continuousRect(inset, inset, side, side, radius);
  const rim = continuousRect(inset + edge / 2, inset + edge / 2, side - edge, side - edge, radius - edge / 2);
  const mark = size <= 32 ? smallMark(size) : fullMark();
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 1024 1024" fill="none"><defs>
<filter id="icon-shadow" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur stdDeviation="8"/></filter>
<linearGradient id="icon-glass" x1="0" y1="${inset}" x2="0" y2="${inset + side}" gradientUnits="userSpaceOnUse"><stop stop-color="${palette.wire}" stop-opacity=".09"/><stop offset="1" stop-color="${palette.wire}" stop-opacity=".02"/></linearGradient>
</defs>
<path d="${shape}" fill="#000" opacity=".3" transform="translate(0 10)" filter="url(#icon-shadow)"/>
<path d="${shape}" fill="${palette.void}"/><path d="${shape}" fill="url(#icon-glass)"/>
${size > 16 ? `<path d="${rim}" stroke="${palette.wire}" stroke-opacity="${size <= 32 ? 0.35 : 0.4}" stroke-width="${n(edge)}"/>` : ""}
${mark}</svg>\n`;
}

function fullMark() {
  // The frame (34 of the mark's 40 units) spans 60% of the tile. A wider, fainter bloom under the lit tile carries its
  // glow down to Dock sizes.
  const scale = (0.6 * tile.size) / 34,
    offset = 512 - 20 * scale;
  return `<g transform="translate(${n(offset)} ${n(offset)}) scale(${n(scale)})"><defs><filter id="icon-bloom" x="-60%" y="-120%" width="220%" height="340%"><feGaussianBlur stdDeviation="3"/></filter></defs><rect x="9" y="9" width="22" height="9" rx="1.5" fill="${palette.neon}" opacity=".35" filter="url(#icon-bloom)"/>${markContent("icon-halo")}</g>`;
}

// Pixel-grid layouts of the mark for small sizes, in output pixels: the frame's origin and outer size, its stroke,
// the space inside it, the top and lower tile heights, the gaps under the top tile and between the lower tiles, the
// tiles' corner radius and the wire opacity. Lower tiles are drawn solid where an outline would close up.
const small = {
  16: { frame: [3, 10], stroke: 1, inset: 1, top: 3, lower: 2, gap: 1, split: 2, rx: 0.4, solid: true, wire: 0.9 },
  32: { frame: [7, 18], stroke: 1, inset: 2, top: 5, lower: 5, gap: 2, split: 2, rx: 0.8, solid: false, wire: 0.95 },
};

function smallMark(size) {
  const { frame, stroke, inset, top, lower, gap, split, rx, solid, wire } = small[size];
  const [origin, span] = frame,
    half = stroke / 2;
  const inner = origin + stroke + inset,
    width = span - 2 * (stroke + inset),
    lowerY = inner + top + gap,
    lowerWidth = (width - split) / 2;
  const unlit = (x, y, w, h) =>
    solid
      ? `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${rx}" fill="${palette.wire}" fill-opacity="${wire}"/>`
      : `<rect x="${x + half}" y="${y + half}" width="${w - stroke}" height="${h - stroke}" rx="${rx}" stroke="${palette.wire}" stroke-opacity="${wire}" stroke-width="${stroke}"/>`;
  return `<g transform="scale(${1024 / size})">
<rect x="${origin + half}" y="${origin + half}" width="${span - stroke}" height="${span - stroke}" rx="${n(span / 5)}" stroke="${palette.wire}" stroke-opacity="${wire}" stroke-width="${stroke}"/>
<rect x="${inner}" y="${inner}" width="${width}" height="${top}" rx="${rx}" fill="${palette.neon}"/>
${unlit(inner, lowerY, lowerWidth, lower)}${unlit(inner + lowerWidth + split, lowerY, lowerWidth, lower)}
</g>`;
}

/**
 * The disk image window, in points. `packaging/dmg.py` places the icons at the same centres with the same icon and
 * label sizes; keep the two in step.
 */
export const dmgWindow = {
  width: 640,
  height: 420,
  icon: 128,
  text: 14,
  app: [160, 200],
  applications: [480, 200],
};

// Finder draws the icons' file names itself, in dark text in light appearance and light text in dark appearance. A
// soft plate whose luminance (0.179) gives black and white text the same contrast, 4.6:1, keeps either readable; its
// colour is the wire colour darkened to that luminance. The solid core, 112 by 22 pt centred 15 pt below the icon,
// leaves a few points of slack around a 14 pt label, and a feathered edge fades it into the background.
const plate = { color: "#5f779a", width: 112, height: 22, below: 15 };

/** The disk image background at 1x, 640 by 420. */
export function dmgBackgroundSVG() {
  const { width, height, icon, app, applications } = dmgWindow;
  const brand = lockup();
  const brandScale = 32 / brand.height;
  const brandX = (width - brand.width * brandScale) / 2;
  const y = app[1];
  const from = app[0] + icon / 2 + 34,
    to = applications[0] - icon / 2 - 34;
  const lines = [];
  // The website's field of page-shaped cells, 160 by 100, placed so each icon sits mid-column.
  for (let column = 80; column < width; column += 160) lines.push(`M${column} 0V${height}`);
  for (let row = 50; row < height; row += 100) lines.push(`M0 ${row}H${width}`);
  const label = ([x]) => {
    const rect = (grow, extra = "") =>
      `<rect x="${x - plate.width / 2 - grow}" y="${y + icon / 2 + plate.below - plate.height / 2 - grow}" width="${plate.width + 2 * grow}" height="${plate.height + 2 * grow}" rx="${plate.height / 2 - 2 + grow}" fill="${plate.color}"${extra}/>`;
    return rect(4, ` filter="url(#dmg-soft)"`) + rect(0);
  };
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" fill="none"><defs>
<radialGradient id="dmg-bloom" cx="320" cy="150" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(320 150) scale(384 193) translate(-320 -150)"><stop stop-color="#2d5cff" stop-opacity=".16"/><stop offset=".7" stop-color="#2d5cff" stop-opacity="0"/></radialGradient>
<radialGradient id="dmg-fade" cx="320" cy="190" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(320 190) scale(420 250) translate(-320 -190)"><stop offset=".2" stop-color="#fff"/><stop offset=".8" stop-color="#fff" stop-opacity="0"/></radialGradient>
<mask id="dmg-field"><rect width="${width}" height="${height}" fill="url(#dmg-fade)"/></mask>
<filter id="dmg-soft" x="-20%" y="-50%" width="140%" height="200%"><feGaussianBlur stdDeviation="2.5"/></filter>
<filter id="dmg-glow" x="-20%" y="-50%" width="140%" height="200%" color-interpolation-filters="sRGB"><feGaussianBlur in="SourceAlpha" stdDeviation="2.4" result="halo"/><feFlood flood-color="${palette.neon}" flood-opacity=".85"/><feComposite in2="halo" operator="in" result="glow"/><feMerge><feMergeNode in="glow"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
</defs>
<rect width="${width}" height="${height}" fill="${palette.void}"/>
<rect width="${width}" height="${height}" fill="url(#dmg-bloom)"/>
<path d="${lines.join("")}" stroke="${palette.wire}" stroke-opacity=".09" mask="url(#dmg-field)"/>
<g transform="translate(${n(brandX)} 44) scale(${n(brandScale)})">${brand.content}</g>
<g filter="url(#dmg-glow)" stroke="${palette.core}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M${from} ${y}H${to}M${to - 9} ${y - 9}L${to} ${y}L${to - 9} ${y + 9}"/></g>
<text x="${width / 2}" y="${y + 32}" text-anchor="middle" font-family="${sans}" font-size="13" font-weight="300" fill="${palette.dim}">Drag minitile to Applications</text>
${label(app)}${label(applications)}
<path d="M40 350.5H600" stroke="${palette.wire}" stroke-opacity=".2"/>
<text x="${width / 2}" y="382" text-anchor="middle" font-family="${sans}" font-size="12.5" font-weight="300" fill="${palette.dim}">Before you start, give every display a second desktop.<tspan dx="8" fill="${palette.ink}">minitile.app</tspan></text>
</svg>\n`;
}
