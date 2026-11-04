import { layout } from "./layouts.mjs";

export const LOOP_SECONDS = 16;
const STEP_SECONDS = LOOP_SECONDS / 4;
const PAGE_WIDTH = 1.72;
const PAGE_HEIGHT = 1.18;
const COLUMN_PITCH = 2.02;
const ROW_PITCH = 1.58;
const route = [
  [0, 0],
  [1, 0],
  [1, 1],
  [0, 1],
];
const contents = [
  ["editor", "terminal"],
  ["browser"],
  ["notes", "calendar"],
  ["design"],
  ["research"],
  ["music"],
];

function pageOrigin(column, row) {
  return [column * COLUMN_PITCH - 2.88, row * ROW_PITCH - 1.38];
}

function arrangement([column, row]) {
  const windows = [];
  contents.forEach((stationary, index) => {
    const page = index % 3;
    const workspace = Math.floor(index / 3);
    const ids = [...stationary];
    if (page === column && workspace === row) ids.push("moving");
    const [left, top] = pageOrigin(page, workspace);
    layout(ids.length).forEach((tile, slot) => {
      const insetX = tile.x ? 0.025 : 0;
      const insetY = tile.y ? 0.025 : 0;
      windows.push({
        id: ids[slot],
        page,
        workspace,
        x: left + 0.075 + tile.x * (PAGE_WIDTH - 0.15) + insetX,
        y: top + 0.19 + tile.y * (PAGE_HEIGHT - 0.265) + insetY,
        width:
          tile.width * (PAGE_WIDTH - 0.15) -
          insetX -
          (tile.x + tile.width < 1 ? 0.025 : 0),
        height:
          tile.height * (PAGE_HEIGHT - 0.265) -
          insetY -
          (tile.y + tile.height < 1 ? 0.025 : 0),
      });
    });
  });
  return windows;
}

/** A single window follows the grid; the source and destination pages retile. */
export function workspaceFrame(seconds = 0) {
  const time = ((seconds % LOOP_SECONDS) + LOOP_SECONDS) % LOOP_SECONDS;
  const step = Math.floor(time / STEP_SECONDS);
  const from = route[step];
  const to = route[(step + 1) % route.length];
  const travel = Math.max(0, Math.min(1, ((time % STEP_SECONDS) - 1.1) / 1.8));
  const progress = travel * travel * (3 - 2 * travel);
  const start = arrangement(from);
  const end = new Map(arrangement(to).map((window) => [window.id, window]));
  const windows = start.map((window) => {
    const target = end.get(window.id);
    const current = { ...window, z: 0.045 };
    for (const key of ["x", "y", "width", "height"]) {
      current[key] += (target[key] - window[key]) * progress;
    }
    if (window.id === "moving") {
      current.z = 0.09 + Math.sin(Math.PI * progress) * 0.34;
      [current.page, current.workspace] = progress < 0.5 ? from : to;
    }
    return current;
  });
  return {
    windows,
    from,
    to,
    progress,
    axis: from[0] === to[0] ? "workspaces" : "pages",
  };
}

/** Project the illustrative workspace grid into shared canvas and SVG primitives. */
export function geometryFrame(width, height, seconds = 0) {
  const scene = workspaceFrame(seconds);
  const scale = Math.min(width / 7.65, height / 5.4);
  const yaw = -0.18;
  const pitch = 0.19;
  const roll = -0.055;
  const segments = [];
  const faces = [];
  const labels = [];

  function project([x, y, z = 0]) {
    const a = x * Math.cos(yaw) + z * Math.sin(yaw);
    const b = -x * Math.sin(yaw) + z * Math.cos(yaw);
    const c = y * Math.cos(pitch) - b * Math.sin(pitch);
    const depth = y * Math.sin(pitch) + b * Math.cos(pitch);
    const perspective = 10 / (10 + depth);
    return [
      width * 0.55 +
        (a * Math.cos(roll) - c * Math.sin(roll)) * scale * perspective,
      height * 0.51 +
        (a * Math.sin(roll) + c * Math.cos(roll)) * scale * perspective,
    ];
  }

  function line(a, b, alpha = 0.2, accent = false, weight = 0.7) {
    segments.push({ a: project(a), b: project(b), alpha, accent, weight });
  }

  function label(text, position, options = {}) {
    labels.push({
      text,
      position: project(position),
      size: Math.max(8, Math.min(11, scale * 0.12)),
      alpha: 0.8,
      align: "center",
      rotation: 0,
      ...options,
    });
  }

  function plate(x, y, w, h, z, strength, active = false) {
    const front = [
      [x, y, z],
      [x + w, y, z],
      [x + w, y + h, z],
      [x, y + h, z],
    ];
    const back = front.map(([a, b]) => [a, b, z - 0.09]);
    faces.push({ points: front.map(project), alpha: active ? 0.13 : 0.025 });
    for (let edge = 0; edge < 4; edge++) {
      line(back[edge], back[(edge + 1) % 4], strength * 0.3);
      line(front[edge], back[edge], strength * 0.6, active);
      line(
        front[edge],
        front[(edge + 1) % 4],
        strength,
        true,
        active ? 1.5 : 0.8,
      );
    }
  }

  // Grid scaffolding remains fixed so the two navigation axes stay legible.
  for (let column = 0; column < 3; column++) {
    for (let row = 0; row < 2; row++) {
      const [x, y] = pageOrigin(column, row);
      const source = scene.from[0] === column && scene.from[1] === row;
      const destination = scene.to[0] === column && scene.to[1] === row;
      const emphasis =
        (source ? 1 - scene.progress : 0) + (destination ? scene.progress : 0);
      plate(x, y, PAGE_WIDTH, PAGE_HEIGHT, -0.09, 0.25 + emphasis * 0.25);
      line([x, y + 0.13, -0.09], [x + PAGE_WIDTH, y + 0.13, -0.09], 0.13);
      for (let grid = 1; grid < 6; grid++) {
        const gx = x + (PAGE_WIDTH * grid) / 6;
        line([gx, y + 0.13, -0.1], [gx, y + PAGE_HEIGHT, -0.1], 0.055);
      }
    }
  }

  const moving = scene.windows.find((window) => window.id === "moving");
  const ordered = [
    ...scene.windows.filter((window) => window.id !== "moving"),
    moving,
  ];
  for (const window of ordered) {
    const { x, y, width: w, height: h, z, id } = window;
    const active = id === "moving";
    plate(x, y, w, h, z, active ? 0.95 : 0.4, active);
    line([x, y + 0.09, z], [x + w, y + 0.09, z], active ? 0.7 : 0.23, true);
    for (let dot = 0; dot < 3; dot++) {
      line(
        [x + 0.04 + dot * 0.045, y + 0.045, z],
        [x + 0.055 + dot * 0.045, y + 0.045, z],
        active ? 0.9 : 0.4,
        true,
        1.4,
      );
    }
    for (let n = 0; n < 3; n++) {
      const py = y + 0.15 + ((h - 0.2) * n) / 4;
      line(
        [x + 0.06, py, z],
        [x + w * (n === 1 ? 0.55 : 0.78), py, z],
        active ? 0.32 : 0.13,
        true,
      );
    }
  }

  label("PAGES", [0, -2.12]);
  line([-2.83, -1.94], [2.78, -1.94], 0.3, true);
  line([2.78, -1.94], [2.68, -2.0], 0.5, true);
  line([2.78, -1.94], [2.68, -1.88], 0.5, true);
  for (let column = 0; column < 3; column++) {
    label(
      `P${column + 1}`,
      [pageOrigin(column, 0)[0] + PAGE_WIDTH / 2, -1.62],
      { alpha: 0.65 },
    );
  }
  label("WORKSPACES", [-3.67, 0], { rotation: -Math.PI / 2 });
  line([-3.4, -1.35], [-3.4, 1.38], 0.3, true);
  line([-3.4, 1.38], [-3.46, 1.28], 0.5, true);
  line([-3.4, 1.38], [-3.34, 1.28], 0.5, true);
  for (let row = 0; row < 2; row++) {
    label(`W${row + 1}`, [-3.1, pageOrigin(0, row)[1] + PAGE_HEIGHT / 2], {
      size: Math.max(7, scale * 0.1),
      alpha: 0.7,
    });
  }
  label(
    scene.axis === "pages" ? "MOVE ACROSS PAGES" : "MOVE BETWEEN WORKSPACES",
    [0, 1.95],
    { alpha: 0.9 },
  );
  return { segments, faces, labels };
}

export function geometrySVG(width, height, seconds = 0) {
  const { segments, faces, labels } = geometryFrame(width, height, seconds);
  const point = ([x, y]) => `${x.toFixed(2)},${y.toFixed(2)}`;
  return (
    faces
      .map(
        ({ points, alpha }) =>
          `<polygon points="${points.map(point).join(" ")}" fill="#53e9ff" fill-opacity="${alpha}"/>`,
      )
      .join("") +
    segments
      .map(
        ({ a, b, alpha, accent, weight }) =>
          `<path d="M${point(a)}L${point(b)}" fill="none" stroke="${accent ? "#53e9ff" : "#7d9cc9"}" stroke-opacity="${alpha}" stroke-width="${weight}"/>`,
      )
      .join("") +
    labels
      .map(
        ({ text, position: [x, y], size, alpha, rotation }) =>
          `<g transform="translate(${x.toFixed(2)} ${y.toFixed(2)})${rotation ? ` rotate(${(rotation * 180) / Math.PI})` : ""}"><text x="0" y="0" fill="#9fb3d1" fill-opacity="${alpha}" font-family="Helvetica,Arial,sans-serif" font-size="${size}" text-anchor="middle">${text}</text></g>`,
      )
      .join("")
  );
}
