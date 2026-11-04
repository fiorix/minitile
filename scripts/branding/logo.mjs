// minitile's mark and wordmark, built from one stroke system so they stay consistent at every size.
//
// The mark is a three-window layout on a 32-unit grid: one wide tile over two tall ones, 2 units apart, all with
// 3-unit corners, drawn as glass (a hairline over a faint fill). A single neon line, a pale core inside a cyan halo,
// traces an m through it: up the outer edges, over the top tile and down the gap between the lower two.
//
// The wordmark is monoline lowercase on a 20-unit x-height with 27-unit ascenders. Stems, arches and the bowl share one
// stroke with round ends. The three i-dots are small tiles, echoing the mark's three windows; the last one is lit.

export const palette = {
  void: "#05070c",
  wire: "#7d9cc9",
  ink: "#e8f0fc",
  dim: "#8e9cb4",
  neon: "#53e9ff",
  core: "#dcfbff",
};

const n = (value) => +value.toFixed(2);

const halo = (id, deviation) =>
  `<filter id="${id}" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="${deviation}"/></filter>`;

// A neon line: a blurred halo, the tube, and its pale core.
function tube(d, width, filter) {
  const line = `fill="none" stroke-linecap="round" stroke-linejoin="round"`;
  return (
    `<path d="${d}" ${line} stroke="${palette.neon}" stroke-width="${n(width * 2.4)}" stroke-opacity=".8" filter="url(#${filter})"/>` +
    `<path d="${d}" ${line} stroke="${palette.neon}" stroke-width="${n(width * 1.6)}" stroke-opacity=".9"/>` +
    `<path d="${d}" ${line} stroke="${palette.core}" stroke-width="${n(width * 0.75)}"/>`
  );
}

const tiles = [
  [3, 3, 26, 10],
  [3, 15, 12, 14],
  [17, 15, 12, 14],
];
const radius = 3;

/** The mark's drawing in its 32-unit space; `id` keeps filter ids unique when several marks share a document. */
export function markContent(id = "mark-halo") {
  const glass = `fill="${palette.wire}" fill-opacity=".09" stroke="${palette.wire}" stroke-opacity=".6" stroke-width=".75"`;
  const tile = ([x, y, width, height]) =>
    `<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="${radius}" ${glass}/>`;
  // The m runs 0.4 inside the outer edges, so its corners stay concentric with the tiles' and its halo, not its core,
  // reaches the edge. The middle stem starts in the gap under the top tile.
  const i = 0.4,
    r = radius - i,
    [, , , top] = tiles[0];
  const m = `M${3 + i} ${29 - i}V${3 + radius}A${r} ${r} 0 0 1 ${3 + radius} ${3 + i}H${29 - radius}A${r} ${r} 0 0 1 ${29 - i} ${3 + radius}V${29 - i}M16 ${3 + top + 1}V${29 - i}`;
  return `<defs>${halo(id, 1.1)}</defs>${tiles.map(tile).join("")}${tube(m, 0.9, id)}`;
}

export function markSVG(size = 32) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 32 32" fill="none">${markContent()}</svg>\n`;
}

/** The favicon: the mark on its own void tile, so it reads on light and dark tab bars alike. */
export function faviconSVG() {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32" fill="none"><rect width="32" height="32" rx="7" fill="${palette.void}"/><rect x=".5" y=".5" width="31" height="31" rx="6.5" stroke="${palette.wire}" stroke-opacity=".35"/><g transform="translate(4 4) scale(.75)">${markContent("favicon-halo")}</g></svg>\n`;
}

/** Glyph geometry for "minitile": stroke paths, i-dot tiles and the advance width. */
export function wordmark({ stroke = 2.2 } = {}) {
  const xHeight = 20,
    base = 34,
    top = base - xHeight,
    ascender = base - 27,
    spacing = 5.4,
    dotSize = 3.4;
  const paths = [],
    dots = [];
  let x = stroke / 2;
  // An arch rises from a stem's foot, rounds over the x-height and drops to the next stem.
  const arch = (x0, r) =>
    `M${n(x0)} ${base}V${top + r}A${r} ${r} 0 0 1 ${n(x0 + 2 * r)} ${top + r}V${base}`;
  // A stem reaching the x-height before its first arch, as in geometric sans m and n.
  const leadingStem = (x0) => `M${n(x0)} ${top}V${base}`;
  const glyphs = {
    m() {
      const r = 6.2;
      paths.push(leadingStem(x), arch(x, r), arch(x + 2 * r, r));
      x += 4 * r;
    },
    n() {
      const r = 7.4;
      paths.push(leadingStem(x), arch(x, r));
      x += 2 * r;
    },
    i() {
      paths.push(`M${n(x)} ${base}V${top}`);
      dots.push({ x: n(x - dotSize / 2), y: n(top - 4.6 - dotSize), size: dotSize });
    },
    t() {
      const foot = 4.6;
      paths.push(
        `M${n(x)} ${ascender + 1.5}V${base - foot}A${foot} ${foot} 0 0 0 ${n(x + foot)} ${base}H${n(x + foot + 1.2)}`,
        `M${n(x - 3.4)} ${top}H${n(x + 5.8)}`,
      );
      x += 6.6;
    },
    l() {
      paths.push(`M${n(x)} ${base}V${ascender}`);
    },
    e() {
      const r = xHeight / 2,
        cx = x + r,
        cy = top + r,
        open = (40 * Math.PI) / 180;
      paths.push(
        `M${n(x)} ${cy}H${n(x + 2 * r)}A${r} ${r} 0 1 0 ${n(cx + r * Math.cos(open))} ${n(cy + r * Math.sin(open))}`,
      );
      x += 2 * r;
    },
  };
  // Optical spacing: the t's crossbar needs room before it; its foot fills some after it.
  const before = { t: 1.6, e: 0.4 },
    after = { t: -0.6 };
  const word = "minitile";
  [...word].forEach((letter, index) => {
    glyphs[letter]();
    if (index < word.length - 1)
      x += spacing + (before[word[index + 1]] ?? 0) + (after[letter] ?? 0);
  });
  return { paths, dots, width: n(x + stroke / 2), base, ascender, stroke };
}

function wordContent(id, { lit = true, color = palette.ink } = {}) {
  const word = wordmark();
  const dots = word.dots
    .map((dot, index) => {
      const rect = (fill, extra = "") =>
        `<rect x="${dot.x}" y="${dot.y}" width="${dot.size}" height="${dot.size}" rx=".8" fill="${fill}"${extra}/>`;
      return lit && index === word.dots.length - 1
        ? rect(palette.neon, ` filter="url(#${id})" opacity=".9"`) + rect(palette.core)
        : rect(color);
    })
    .join("");
  return {
    word,
    content:
      `<defs>${halo(id, 1.1)}</defs>` +
      `<path d="${word.paths.join("")}" stroke="${color}" stroke-width="${word.stroke}" stroke-linecap="round" stroke-linejoin="round"/>` +
      dots,
  };
}

/** The horizontal lockup: the mark's tiles span the wordmark's ascender to its baseline. */
export function lockup(options = {}) {
  const { word, content } = wordContent("word-halo", options);
  const span = word.base - word.ascender,
    scale = n(span / 26),
    pad = 2;
  const markX = pad - 3 * scale,
    markY = word.ascender - 3 * scale,
    wordX = n(pad + 26 * scale + 9);
  const width = n(wordX + word.width + pad),
    height = n(word.base + pad + 1);
  return {
    width,
    height,
    content: `<g transform="translate(${n(markX)} ${n(markY)}) scale(${scale})">${markContent("lockup-halo")}</g><g transform="translate(${wordX} 0)">${content}</g>`,
  };
}

export function lockupSVG(options = {}) {
  const { width, height, content } = lockup(options);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width * 4}" height="${height * 4}" viewBox="0 0 ${width} ${height}" fill="none">${content}</svg>\n`;
}
