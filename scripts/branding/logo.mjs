// minitile's framed three-tile mark on a 40-unit grid. Only the wide top tile is lit; the frame and lower tiles
// are unfilled wire outlines.
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

/** The mark's drawing in its 40-unit space; `id` keeps filter ids unique when several marks share a document. */
export function markContent(id = "mark-halo") {
  const wire = `fill="none" stroke="${palette.wire}" stroke-opacity=".6" stroke-width="1.5"`;
  const top = `<rect x="9" y="9" width="22" height="9" rx="1.5" fill="${palette.neon}"`;
  return `<defs>${halo(id, 1.1)}</defs><rect x="3" y="3" width="34" height="34" rx="7" ${wire}/><rect x="9" y="22" width="9" height="9" rx="1.5" ${wire}/><rect x="22" y="22" width="9" height="9" rx="1.5" ${wire}/>${top} opacity=".8" filter="url(#${id})"/>${top}/>`;
}

export function markSVG(size = 32) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 40 40" fill="none">${markContent()}</svg>\n`;
}

/** The favicon: the mark on its own void tile, so it reads on light and dark tab bars alike. */
export function faviconSVG() {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 40 40" fill="none"><rect width="40" height="40" rx="9" fill="${palette.void}"/>${markContent("favicon-halo")}</svg>\n`;
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

/** The horizontal lockup: the mark's frame spans the wordmark's ascender to its baseline. */
export function lockup(options = {}) {
  const { word, content } = wordContent("word-halo", options);
  const span = word.base - word.ascender,
    scale = span / 34,
    pad = 2;
  const markX = pad - 3 * scale,
    markY = word.ascender - 3 * scale,
    wordX = n(pad + span + 9);
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
