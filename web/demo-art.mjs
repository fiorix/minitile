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
  control: "ctrl",
  option: "opt",
  cmd: "cmd",
  backtick: "`",
  "shift-r": "shift",
  "cmd-r": "cmd",
  "option-r": "opt",
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
const keyById = Object.fromEntries(keys.map((key) => [key.id, key]));
const macKeys = {
  control: ["⌃", "control"],
  option: ["⌥", "option"],
  cmd: ["⌘", "command"],
  shift: ["⇧", "shift"],
  tab: ["⇥", "tab"],
  backtick: ["`", ""],
  n: ["N", ""],
  up: ["↑", ""],
  down: ["↓", ""],
  left: ["←", ""],
  right: ["→", ""],
  space: ["␣", "space"],
};

export function keyZoomFrame(sample) {
  const amount = sample.reduced ? 1 : ease((sample.local - 0.08) / 0.6);
  return sample.keys.map((id, index) => {
    const key = keyById[id];
    const y = 220 - sample.keys.length * 39 + index * 78;
    return {
      id,
      x: mix(key.x + key.width / 2, 87, ease(amount * 1.6)),
      y: mix(key.y + key.height / 2, y + 30, ease((amount - 0.18) / 0.82)),
      scale: mix(key.width / 72, 1, amount),
      opacity: mix(0, 1, amount),
    };
  });
}
const rect = (x, y, width, height, cls = "", rx = 0) =>
  `<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="${rx}" class="${cls}"/>`;
const text = (x, y, value, cls = "", extra = "") =>
  `<text x="${x}" y="${y}" class="${cls}" ${extra}>${value}</text>`;

function handMarkup(side) {
  return `<g class="wire-hand" data-hand="${side}"><path class="hand-palm"/><path class="hand-mesh"/>${Array.from({ length: 5 }, () => '<g class="hand-finger"><path class="finger-outline"/><path class="finger-mesh"/><circle class="finger-joint" r="2.3"/><circle class="finger-tip" r="3.2"/></g>').join("")}</g>`;
}

function windowMarkup(id) {
  return `<g data-window="${id}" class="wire-window">
    <rect class="window-surface" rx="5"/><svg class="window-interior" overflow="hidden">
      <path class="window-rule"/><g class="window-dots"><circle cx="13" cy="13" r="3"/><circle cx="24" cy="13" r="3"/><circle cx="35" cy="13" r="3"/></g>
      ${text(48, 16, apps[id].name, "window-app")}
      <g class="window-content"/>
    </svg></g>`;
}

export function illustration() {
  return `<svg class="desk-illustration" viewBox="0 0 1120 704" role="img" aria-labelledby="desk-title desk-desc">
    <title id="desk-title">A wireframe Mac, keyboard, trackpad, mouse, and two hands</title>
    <desc id="desk-desc">Three tiled windows on a Mac-like screen. The guided demo highlights the keys and hand movements that arrange and navigate windows.</desc>
    <defs>
      <clipPath id="screen-clip">${rect(168, 49, 784, 363, "", 3)}</clipPath>
      <pattern id="desk-grid" width="24" height="24" patternUnits="userSpaceOnUse"><path d="M24 0H0V24" fill="none" stroke="#c8ddf8" stroke-opacity=".035"/></pattern>
      <radialGradient id="desk-glow"><stop stop-color="#29425f" stop-opacity=".18"/><stop offset="1" stop-color="#0b0d10" stop-opacity="0"/></radialGradient>
    </defs>
    <ellipse cx="560" cy="340" rx="550" ry="330" fill="url(#desk-glow)"/>
    <g class="construction-lines"><path d="M135 26H985M145 16V449M975 16V449M135 439H985M158 467H974"/><path d="M120 38h14m-7-7v14M993 38h14m-7-7v14M120 428h14m-7-7v14M993 428h14m-7-7v14"/></g>
    <g class="key-zoom-trails" data-zoom-trails></g>
    ${text(31, 53, "01 / DISPLAY", "hardware-label")}
    ${text(31, 70, "YOUR SPACE, ARRANGED", "hardware-note")}
    ${rect(157, 27, 806, 414, "monitor-shell", 12)}
    ${rect(163, 33, 794, 402, "monitor-inner", 8)}
    <circle cx="560" cy="41" r="2" class="camera-dot"/>
    <g clip-path="url(#screen-clip)">
      ${rect(168, 49, 784, 363, "screen-bg")}
      ${rect(168, 49, 784, 363, "screen-grid")}
      <g data-windows>${Object.keys(apps).map(windowMarkup).join("")}</g>
      <g class="window-switcher" data-switcher></g>
      <g class="screen-pointer" data-pointer><path d="M0 0v21l5-5 5 9 4-2-5-9 8-1Z"/></g>
      <g class="tab-ghost" data-tab-ghost>${rect(0, 0, 118, 26, "", 4)}${text(12, 17, "Research ↗")}</g>
    </g>
    <g class="screen-menubar">${rect(168, 49, 784, 21)}${text(179, 63, "◆", "menu-mark")}${text(199, 63, "Editor", "menu-app", 'data-menu-app=""')}${text(258, 63, "File   Edit   View   Window", "menu-items")}${text(938, 63, "W1 / P1     9:41", "menu-location", 'text-anchor="end" data-location=""')}</g>
    <g class="monitor-chin"><path d="M157 417H963"/>${text(560, 431, "minitile", "monitor-wordmark", 'text-anchor="middle"')}</g>
    <path class="monitor-stand" d="M526 441 519 467H601L594 441M519 467 496 476H624L601 467"/>
    <g data-minimap transform="translate(988 104)"></g>
    ${text(988, 92, "THE GRID", "hardware-note")}
    ${text(988, 201, "PAGES →", "hardware-note")}
    ${text(988, 219, "WORKSPACES ↓", "hardware-note")}
    <g class="input-hardware">
    <g class="construction-lines"><path d="M168 479V641M952 479V641"/></g>
    <g class="keyboard">${rect(181, 488, 570, 149, "device-outline", 9)}${rect(185, 492, 562, 141, "device-inset", 6)}
      ${keys.map((key) => `<g data-key="${key.id}" class="keyboard-key">${rect(key.x, key.y, key.width, key.height, "", 3)}${text(key.x + key.width / 2, key.y + 14, keyLabels[key.id] ?? key.id, "", 'text-anchor="middle"')}</g>`).join("")}
    </g>
    <g class="trackpad">${rect(775, 492, 115, 141, "device-outline", 9)}${rect(780, 497, 105, 131, "device-inset", 6)}<g data-gesture></g></g>
    <g class="mouse" data-mouse><path class="device-outline" d="M947 506c-20 0-31 14-31 38v38c0 25 12 40 31 40s31-15 31-40v-38c0-24-11-38-31-38Z"/><path class="mouse-button" d="M947 506c-20 0-31 14-31 38v10h31Z"/><path class="device-inset" d="M947 507v47m-30 0h60"/><rect x="944" y="523" width="6" height="19" rx="3" class="device-inset"/></g>
    ${text(181, 660, "02 / KEYBOARD", "hardware-label")}${text(775, 660, "03 / TRACKPAD", "hardware-label")}${text(916, 660, "04 / MOUSE", "hardware-label")}
    </g>
    <g class="input-hands">${handMarkup("left")}${handMarkup("right")}</g>
    <g class="key-callout" aria-hidden="true">
      ${text(87, 112, "", "key-callout-label", 'text-anchor="middle" data-key-label=""')}
      <g data-key-zoom></g>
      <g data-input-hint></g>
    </g>
  </svg>`;
}

function appContent(id, width, height, state) {
  const app = apps[id],
    w = Math.max(50, width - 32);
  if (app.kind === "browser") {
    const tabs = id === "browser" && state.tabs;
    return `<g class="browser-tabs">${rect(9, 30, tabs ? w * 0.49 : w, 18, "browser-tab", 3)}${text(16, 43, app.title)}${tabs ? rect(13 + w * 0.49, 30, w * 0.49, 18, "research-tab", 3) + text(20 + w * 0.49, 43, "Research") : ""}</g>
      ${rect(12, 55, width - 24, 20, "browser-address", 3)}${text(22, 68, id === "tab" ? "research / ideas" : "a little room to explore", "content-muted")}
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

export function handPose(side, targets, device, gesture, phase) {
  const isLeft = side === "left";
  let cx = isLeft
    ? 321
    : device === "trackpad"
      ? 833
      : device === "mouse"
        ? 951
        : 651;
  let cy = device === "keyboard" || isLeft ? 660 : 640;
  if (device === "keyboard" && targets.length) {
    const first = keyById[targets[0]];
    if (isLeft) {
      cx = targets.includes("cmd") ? 294 : 280;
      if (targets.includes("backtick") || targets.includes("tab")) {
        cx = 269;
        cy = 620;
      } else if (targets.includes("shift")) cx = 250;
    } else cx = first.x + first.width / 2 + (targets[0] === "space" ? 32 : 0);
  }
  const movement = Math.sin(
    Math.min(1, Math.max(0, (phase - 0.2) / 1.2)) * Math.PI,
  );
  if (!isLeft && gesture === "left") cx -= 27 * movement;
  if (!isLeft && gesture === "right") cx += 27 * movement;
  const dy =
    !isLeft && gesture === "up"
      ? -35 * movement
      : !isLeft && gesture === "down"
        ? 25 * movement
        : 0;
  const wrist = [
    [cx - 23, cy + 35],
    [cx + 22, cy + 35],
  ];
  const knuckles = [-36, -19, 0, 19, 38].map((x, i) => [
    cx + x,
    cy - 24 - (i === 0 || i === 4 ? -8 : 0) + dy,
  ]);
  const lengths = isLeft ? [42, 65, 76, 65, 28] : [28, 65, 76, 65, 42];
  const tips = knuckles.map(([x, y], i) => [x + (i - 2) * 3, y - lengths[i]]);
  const available = isLeft
    ? targets.map(
        (key) =>
          ({
            control: targets.includes("shift") ? 1 : 0,
            shift: 0,
            option: 2,
            cmd: 4,
            backtick: 0,
            tab: 1,
          })[key],
      )
    : targets.map((key) => (key === "space" ? 0 : 2));
  targets.forEach((id, i) => {
    const key = keyById[id];
    if (key)
      tips[available[i]] = [key.x + key.width / 2, key.y + key.height / 2];
  });
  if (!isLeft && device === "mouse") {
    tips[1] = [934, 538];
    tips[2] = [954, 536];
    tips[3] = [970, 550];
    tips[4] = [978, 573];
    tips[0] = [914, 575];
  }
  return { cx, cy: cy + dy, wrist, knuckles, tips, available };
}

function drawHand(node, side, sample) {
  const assignedKeys = (step) =>
    step.keys.filter(
      (key) =>
        ["control", "shift", "option", "cmd", "backtick", "tab"].includes(
          key,
        ) ===
        (side === "left"),
    );
  const device = side === "left" ? "keyboard" : sample.device;
  const targets = assignedKeys(sample);
  const previousDevice = side === "left" ? "keyboard" : sample.previous.device;
  const a = handPose(
    side,
    assignedKeys(sample.previous),
    previousDevice,
    null,
    0,
  );
  const b = handPose(side, targets, device, sample.gesture, sample.local);
  const point = (p, q) => p.map((v, i) => mix(v, q[i], sample.reach));
  const wrist = a.wrist.map((p, i) => point(p, b.wrist[i]));
  const knuckles = a.knuckles.map((p, i) => point(p, b.knuckles[i]));
  const tips = a.tips.map((p, i) => point(p, b.tips[i]));
  const cx = mix(a.cx, b.cx, sample.reach),
    cy = mix(a.cy, b.cy, sample.reach);
  const palm = [...wrist.slice(0, 1), ...knuckles, wrist[1]];
  node
    .querySelector(".hand-palm")
    .setAttribute("d", `M${palm.map((p) => p.join(",")).join("L")}Z`);
  node
    .querySelector(".hand-mesh")
    .setAttribute(
      "d",
      knuckles
        .map((p, i) => `M${p}L${wrist[i < 2 ? 0 : 1]}M${p}L${cx},${cy + 5}`)
        .join(""),
    );
  node.querySelectorAll(".hand-finger").forEach((finger, i) => {
    const [bx, by] = knuckles[i],
      [tx, ty] = tips[i];
    const mx = mix(bx, tx, 0.55),
      my = mix(by, ty, 0.55);
    finger
      .querySelector(".finger-outline")
      .setAttribute(
        "d",
        `M${bx - 6} ${by}L${mx - 5} ${my}L${tx - 4} ${ty + 2}Q${tx} ${ty - 7} ${tx + 4} ${ty + 2}L${mx + 5} ${my}L${bx + 6} ${by}Z`,
      );
    finger
      .querySelector(".finger-mesh")
      .setAttribute(
        "d",
        `M${bx - 6} ${by}L${mx + 5} ${my}L${tx - 4} ${ty + 2}M${bx + 6} ${by}L${mx - 5} ${my}L${tx + 4} ${ty + 2}M${mx - 5} ${my}H${mx + 5}`,
      );
    const joint = finger.querySelector(".finger-joint"),
      tip = finger.querySelector(".finger-tip");
    joint.setAttribute("cx", mx);
    joint.setAttribute("cy", my);
    tip.setAttribute("cx", tx);
    tip.setAttribute("cy", ty);
    finger.classList.toggle(
      "touching",
      sample.pressing &&
        (targets.some((_, j) => b.available[j] === i) ||
          (side === "right" &&
            (device === "trackpad" ? i > 0 : device === "mouse" && i === 1))),
    );
  });
}

export function createIllustration(root) {
  const windows = new Map(
    [...root.querySelectorAll("[data-window]")].map((node) => [
      node.dataset.window,
      node,
    ]),
  );
  let contentKey = "";
  let calloutKey = "";
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
      node.classList.toggle("drop-target", id === state.drop);
      node.classList.toggle("dragged", id === state.drag);
      const surface = node.querySelector(".window-surface"),
        interior = node.querySelector(".window-interior");
      surface.setAttribute("width", width);
      surface.setAttribute("height", height);
      interior.setAttribute("width", width);
      interior.setAttribute("height", height);
      node.querySelector(".window-rule").setAttribute("d", `M0 26H${width}`);
      const key = `${Math.round(width)}:${Math.round(height)}:${Boolean(state.tabs)}`;
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
    const top = windows.get(state.drag || state.focus);
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
    const minimapKey = JSON.stringify([
      state.grid,
      state.workspace,
      state.page,
      state.switcher,
    ]);
    if (minimapKey !== contentKey) {
      root.querySelector("[data-switcher]").innerHTML = state.switcher
        ? `${rect(289, 135, 542, 235, "switcher-panel", 12)}${text(310, 160, "WINDOWS / HOLD CMD", "switcher-label")}${state.grid.map((row, r) => row.map((page, p) => `<g transform="translate(${310 + p * 251} ${178 + r * 88})">${rect(0, 0, 240, 76, "switcher-page", 4)}${text(8, 14, `W${r + 1} / P${p + 1}`, "switcher-label")}${page.map((id, i) => `<g transform="translate(${8 + i * 75} 23)" class="switcher-entry ${id === state.switcher ? "selected" : ""}">${rect(0, 0, 68, 45, "", 3)}${text(34, 27, apps[id].name, "", 'text-anchor="middle"')}</g>`).join("")}</g>`).join("")).join("")}`
        : "";
      contentKey = minimapKey;
    }
    const nextCallout = JSON.stringify([
      sample.keys,
      sample.device,
      sample.gesture,
      sample.hold,
      previous.hold,
    ]);
    if (calloutKey !== nextCallout) {
      const label = root.querySelector("[data-key-label]");
      label.textContent = sample.keys.length
        ? "PRESS TOGETHER"
        : sample.device === "trackpad"
          ? "SWIPE"
          : sample.device === "mouse"
            ? sample.hold
              ? "CLICK + HOLD"
              : "POINT + DRAG"
            : previous.hold
              ? "RELEASE KEYS"
              : "WATCH THE HANDS";
      label.setAttribute(
        "y",
        sample.keys.length ? 203 - sample.keys.length * 39 : 154,
      );
      root.querySelector("[data-key-zoom]").innerHTML = sample.keys
        .map((id, i) => {
          const [symbol, name] = macKeys[id];
          return `<g data-zoom-key="${id}" class="mac-key">${rect(-36, -25, 72, 60, "mac-key-base", 9)}${rect(-36, -30, 72, 60, "mac-key-face", 9)}<path class="mac-key-shine" d="M-26-27H26"/>${text(name ? 25 : 0, name ? -2 : 9, symbol, "mac-key-symbol", `text-anchor="${name ? "end" : "middle"}"`)}${name ? text(25, 19, name, "mac-key-name", 'text-anchor="end"') : ""}${i < sample.keys.length - 1 ? text(0, 50, "+", "mac-key-plus", 'text-anchor="middle"') : ""}</g>`;
        })
        .join("");
      const hint =
        sample.device === "trackpad"
          ? keyLabels[sample.gesture] || "↔"
          : sample.device === "mouse"
            ? "↖"
            : "";
      root.querySelector("[data-input-hint]").innerHTML = sample.keys.length
        ? ""
        : text(87, 218, hint, "input-hint-symbol", 'text-anchor="middle"') +
          text(
            87,
            248,
            sample.device === "trackpad"
              ? "4 fingers"
              : sample.device === "mouse"
                ? "Mouse"
                : "Your workspace",
            "input-hint",
            'text-anchor="middle"',
          );
      root.querySelector("[data-zoom-trails]").innerHTML = sample.keys
        .map((id) => {
          const key = keyById[id];
          return `<path d="M${key.x + key.width / 2} ${key.y + key.height / 2}V483Q87 483 87 414V370"/>`;
        })
        .join("");
      calloutKey = nextCallout;
    }
    for (const zoom of keyZoomFrame(sample)) {
      const node = root.querySelector(`[data-zoom-key="${zoom.id}"]`);
      node.setAttribute(
        "transform",
        `translate(${zoom.x} ${zoom.y}) scale(${zoom.scale})`,
      );
      node.setAttribute("opacity", zoom.opacity);
    }
    root
      .querySelectorAll("[data-key]")
      .forEach((node) =>
        node.classList.toggle(
          "pressed",
          sample.pressing && sample.keys.includes(node.dataset.key),
        ),
      );
    const isMouse = sample.device === "mouse";
    root
      .querySelector("[data-mouse]")
      .classList.toggle("pressed", isMouse && sample.hold);
    const pointer = root.querySelector("[data-pointer]");
    pointer.style.display = isMouse ? "" : "none";
    const a = previous.state.pointer || state.pointer || [0.5, 0.5],
      b = state.pointer || a;
    const px = field.x + mix(a[0], b[0], t) * field.width,
      py = field.y + mix(a[1], b[1], t) * field.height;
    pointer.setAttribute("transform", `translate(${px} ${py})`);
    const ghost = root.querySelector("[data-tab-ghost]");
    ghost.style.display = state.tabDrag ? "" : "none";
    ghost.setAttribute("transform", `translate(${px + 9} ${py + 12})`);
    root.querySelector("[data-gesture]").innerHTML = sample.gesture
      ? `<g class="gesture-trails" transform="translate(833 554) rotate(${{ left: 180, right: 0, up: -90, down: 90 }[sample.gesture]})"><path d="${[-24, -8, 8, 24].map((y) => `M-25 ${y}H25M16 ${y - 6}l9 6-9 6`).join("")}"/></g>`
      : "";
    drawHand(root.querySelector('[data-hand="left"]'), "left", sample);
    drawHand(root.querySelector('[data-hand="right"]'), "right", sample);
  };
}
