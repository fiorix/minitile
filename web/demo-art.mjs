import { apps, ease, frameWindows, mix } from "./demo-scenes.mjs";

const field = { x: 177, y: 76, width: 766, height: 328 };
export const mapMetrics = {
  width: 34,
  height: (34 * field.height) / field.width,
  padding: 2,
  gap: 4,
};

export function minimapFrame(sample) {
  const { width, height, padding, gap } = mapMetrics;
  const strideX = width + 2 * padding + gap;
  const strideY = height + 2 * padding + gap;
  const cameraX = mix(
    sample.previous.state.page,
    sample.state.page,
    sample.transition,
  );
  const cameraY = mix(
    sample.previous.state.workspace,
    sample.state.workspace,
    sample.transition,
  );
  return frameWindows(sample).map((window) => ({
    id: window.id,
    x:
      window.page * strideX +
      padding +
      (window.x + (cameraX - window.page) * 1.08 + 4 / field.width) * width,
    y:
      window.workspace * strideY +
      padding +
      (window.y + (cameraY - window.workspace) * 1.14 + 4 / field.height) *
        height,
    width: (window.width - 8 / field.width) * width,
    height: (window.height - 8 / field.height) * height,
    opacity: window.opacity,
  }));
}

const keyRows = [
  [
    "backtick",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "0",
    "-",
    "=",
    "delete",
  ],
  ["tab", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"],
  ["caps", "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "return"],
  ["shift", "z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "shift-r"],
  ["fn", "control", "option", "cmd", "space", "cmd-r", "option-r"],
];
const keyLabels = {
  control: "control",
  option: "option",
  cmd: "command",
  backtick: "`",
  "shift-r": "shift",
  "cmd-r": "command",
  "option-r": "option",
  space: "",
  up: "↑",
  down: "↓",
  left: "←",
  right: "→",
};
export const keys = [];
keyRows.forEach((row, r) => {
  let x = 195;
  row.forEach((id) => {
    const width =
      id === "space"
        ? 162
        : ["shift", "shift-r", "return", "caps", "tab"].includes(id)
          ? 48
          : ["control", "option", "cmd", "cmd-r", "option-r"].includes(id)
            ? 38
            : 30;
    keys.push({ id, x, y: 502 + r * 25, width, height: 21 });
    x += width + 4;
  });
});
keys.push(
  ...[
    { id: "left", x: 639, y: 602 },
    { id: "down", x: 673, y: 602 },
    { id: "right", x: 707, y: 602 },
    { id: "up", x: 673, y: 577 },
  ].map((key) => ({ ...key, width: 30, height: 21 })),
);

export const trackpad = { x: 780, y: 497, width: 105, height: 131 };
const swipes = { left: [-1, 0], right: [1, 0], up: [0, -1], down: [0, 1] };

/** Four fingertips sliding across the trackpad in the swipe's direction, side by side across it. */
export function gestureFrame(sample) {
  if (sample.device !== "trackpad" || !sample.gesture) return null;
  const [dx, dy] = swipes[sample.gesture];
  const t = sample.reduced ? 1 : ease((sample.local - 0.15) / 1.1);
  const travel = 26;
  const cx = trackpad.x + trackpad.width / 2,
    cy = trackpad.y + trackpad.height / 2;
  const along = (offset, spread) => [
    cx + dx * offset + dy * spread,
    cy + dy * offset + dx * spread,
  ];
  return {
    opacity: sample.pressing ? 1 : 0,
    dots: [-21, -7, 7, 21].map((spread) => ({
      from: along(-travel, spread),
      at: along(mix(-travel, travel, t), spread),
    })),
  };
}

const rect = (x, y, width, height, cls = "", rx = 0) =>
  `<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="${rx}" class="${cls}"/>`;
const text = (x, y, value, cls = "", extra = "") =>
  `<text x="${x}" y="${y}" class="${cls}" ${extra}>${value}</text>`;

function windowMarkup(id) {
  return `<g data-window="${id}" class="wire-window">
    <rect class="window-surface" rx="5"/><svg class="window-interior" overflow="hidden">
      <path class="window-rule"/><g class="window-dots"><circle cx="13" cy="13" r="3"/><circle cx="24" cy="13" r="3"/><circle cx="35" cy="13" r="3"/></g>
      ${text(48, 16, apps[id].name, "window-app")}
      <g class="window-content"/>
    </svg></g>`;
}

// The keyboard and trackpad sit centred under the screen.
const inputShift = 24;

export function illustration() {
  return `<svg class="desk-illustration" viewBox="0 14 1120 632" role="img" aria-labelledby="desk-title desk-desc">
    <title id="desk-title">A wireframe Mac with three tiled windows, a keyboard and a trackpad</title>
    <desc id="desk-desc">Three tiled windows on a Mac-like screen. The keys of each shortcut light up as the windows move.</desc>
    <defs>
      <clipPath id="screen-clip">${rect(168, 49, 784, 363, "", 3)}</clipPath>
      <pattern id="desk-grid" width="24" height="24" patternUnits="userSpaceOnUse"><path d="M24 0H0V24" fill="none" stroke="#7d9cc9" stroke-opacity=".06" stroke-width=".5"/></pattern>
      <radialGradient id="desk-glow"><stop stop-color="#2d5cff" stop-opacity=".13"/><stop offset="1" stop-color="#05070c" stop-opacity="0"/></radialGradient>
      <filter id="neon-glow" x="-20%" y="-20%" width="140%" height="140%" color-interpolation-filters="sRGB"><feGaussianBlur in="SourceAlpha" stdDeviation="2.4" result="halo"/><feFlood flood-color="#53e9ff" flood-opacity=".85"/><feComposite in2="halo" operator="in" result="glow"/><feMerge><feMergeNode in="glow"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
    </defs>
    <ellipse cx="560" cy="300" rx="560" ry="300" fill="url(#desk-glow)"/>
    ${rect(157, 27, 806, 414, "monitor-shell", 12)}
    ${rect(163, 33, 794, 402, "monitor-inner", 8)}
    <circle cx="560" cy="41" r="2" class="camera-dot"/>
    <g clip-path="url(#screen-clip)">
      ${rect(168, 49, 784, 363, "screen-bg")}
      ${rect(168, 49, 784, 363, "screen-grid")}
      <g data-windows>${Object.keys(apps).map(windowMarkup).join("")}</g>
    </g>
    <g class="screen-menubar">${rect(168, 49, 784, 21)}${text(179, 63, "◆", "menu-mark")}${text(199, 63, "Editor", "menu-app", 'data-menu-app=""')}${text(258, 63, "File   Edit   View   Window", "menu-items")}${text(938, 63, "W1 / P1     9:41", "menu-location", 'text-anchor="end" data-location=""')}</g>
    <path class="monitor-chin" d="M157 417H963"/>
    <path class="monitor-stand" d="M526 441 519 467H601L594 441M519 467 496 476H624L601 467"/>
    <g data-minimap transform="translate(988 104)"></g>
    ${text(988, 168, "Pages →", "map-note")}
    ${text(988, 182, "Workspaces ↓", "map-note")}
    <g class="input-hardware" transform="translate(${inputShift} 0)">
    <g class="keyboard">${rect(181, 488, 570, 149, "device-outline", 9)}
      ${keys.map((key) => `<g data-key="${key.id}" class="keyboard-key">${rect(key.x, key.y, key.width, key.height, "", 3)}${text(key.x + key.width / 2, key.y + 14, keyLabels[key.id] ?? key.id, "", 'text-anchor="middle"')}</g>`).join("")}
    </g>
    <g class="trackpad">${rect(775, 492, 115, 141, "device-outline", 9)}<g data-gesture></g></g>
    </g>
  </svg>`;
}

function appContent(id, width, height, state) {
  const app = apps[id],
    w = Math.max(50, width - 32);
  if (app.kind === "browser") {
    return `<g class="browser-tabs">${rect(9, 30, w, 18, "browser-tab", 3)}${text(16, 43, app.title)}</g>
      ${rect(12, 55, width - 24, 20, "browser-address", 3)}${text(22, 68, "a little room to explore", "content-muted")}
      <g class="browser-drawing" transform="translate(${width / 2} ${Math.max(106, height / 2 + 24)})"><circle r="26"/><ellipse rx="10" ry="26"/><path d="M-26 0h52M-22-13h44M-22 13h44"/></g>`;
  }
  if (app.kind === "editor") {
    return `${text(15, 46, app.title, "content-muted")}${[0.7, 0.42, 0.63, 0.5, 0.77, 0.38, 0.57, 0.69, 0.32].map((length, i) => `<path class="code-stroke code-stroke-${i % 3}" d="M${i % 3 ? 42 : 24} ${70 + i * 18}h${w * length * 0.72}"/>`).join("")}${text(16, height - 14, "main   /   Swift", "content-muted")}`;
  }
  if (app.kind === "terminal") {
    return `${text(17, 49, "~ / projects", "content-muted")}${text(17, 72, "$ mntl page list", "terminal-line")}${text(17, 94, "1   editor · notes · terminal", "content-muted")}${rect(17, 110, 6, 11, "terminal-cursor")}`;
  }
  return `${text(18, 53, app.title, "note-title")}${[0, 1, 2].map((i) => `${rect(19, 72 + i * 23, 7, 7, "note-checkbox", 1)}<path class="note-line" d="M35 ${76 + i * 23}h${w * [0.62, 0.77, 0.48][i]}"/>`).join("")}`;
}

export function createIllustration(root) {
  const windows = new Map(
    [...root.querySelectorAll("[data-window]")].map((node) => [
      node.dataset.window,
      node,
    ]),
  );
  const keyNodes = [...root.querySelectorAll("[data-key]")];
  const gestureNode = root.querySelector("[data-gesture]");
  return (sample) => {
    const { state, previous, transition: t } = sample;
    const frames = frameWindows(sample);
    for (const [id, node] of windows) {
      const frame = frames.find((item) => item.id === id);
      node.style.display = frame && frame.opacity > 0 ? "" : "none";
      if (!frame) continue;
      const width = frame.width * field.width - 8,
        height = frame.height * field.height - 8;
      node.setAttribute(
        "transform",
        `translate(${field.x + frame.x * field.width + 4} ${field.y + frame.y * field.height + 4})`,
      );
      node.setAttribute("opacity", frame.opacity);
      node.classList.toggle("focused", id === state.focus);
      const surface = node.querySelector(".window-surface"),
        interior = node.querySelector(".window-interior");
      surface.setAttribute("width", width);
      surface.setAttribute("height", height);
      interior.setAttribute("width", width);
      interior.setAttribute("height", height);
      node.querySelector(".window-rule").setAttribute("d", `M0 26H${width}`);
      const key = `${Math.round(width)}:${Math.round(height)}`;
      if (node.dataset.content !== key) {
        node.querySelector(".window-content").innerHTML = appContent(
          id,
          width,
          height,
          state,
        );
        node.dataset.content = key;
      }
    }
    const top = windows.get(state.focus);
    if (top && top !== top.parentElement.lastElementChild)
      top.parentElement.append(top);
    root.querySelector("[data-location]").textContent =
      `W${state.workspace + 1} / P${state.page + 1}     9:41`;
    root.querySelector("[data-menu-app]").textContent = apps[state.focus].name;
    const { width: mw, height: mh, padding: mp, gap: mg } = mapMetrics;
    const pageWidth = mw + 2 * mp,
      pageHeight = mh + 2 * mp;
    const mapPages = state.grid
      .map((row, r) =>
        row
          .map((_, p) =>
            rect(
              p * (pageWidth + mg),
              r * (pageHeight + mg),
              pageWidth,
              pageHeight,
              "map-page",
              2,
            ),
          )
          .join(""),
      )
      .join("");
    const mapTiles = minimapFrame(sample)
      .map(
        (tile) =>
          `<rect data-mini-window="${tile.id}" x="${tile.x}" y="${tile.y}" width="${tile.width}" height="${tile.height}" opacity="${tile.opacity}" rx=".4" class="map-tile ${tile.id === state.focus ? "focused" : ""}"/>`,
      )
      .join("");
    const currentX = mix(previous.state.page, state.page, t) * (pageWidth + mg);
    const currentY =
      mix(previous.state.workspace, state.workspace, t) * (pageHeight + mg);
    root.querySelector("[data-minimap]").innerHTML =
      mapPages +
      mapTiles +
      rect(currentX, currentY, pageWidth, pageHeight, "map-current", 2);
    for (const node of keyNodes)
      node.classList.toggle(
        "pressed",
        sample.pressing && sample.keys.includes(node.dataset.key),
      );
    const gesture = gestureFrame(sample);
    gestureNode.setAttribute("opacity", gesture ? gesture.opacity : 0);
    gestureNode.innerHTML = gesture
      ? gesture.dots
          .map(
            ({ from, at }) =>
              `<path class="gesture-trail" d="M${from.join(" ")}L${at.join(" ")}"/><circle class="gesture-dot" cx="${at[0]}" cy="${at[1]}" r="4.5"/>`,
          )
          .join("")
      : "";
  };
}
