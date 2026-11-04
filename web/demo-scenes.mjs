import { layout } from "./layouts.mjs";

export const apps = {
  editor: { name: "Editor", title: "a-little-space.swift", kind: "editor" },
  notes: { name: "Notes", title: "A little room to think", kind: "notes" },
  terminal: { name: "Terminal", title: "~/projects", kind: "terminal" },
  browser: { name: "Browser", title: "Start here", kind: "browser" },
  mail: { name: "Mail", title: "Inbox", kind: "notes" },
  calendar: { name: "Calendar", title: "Today", kind: "notes" },
  files: { name: "Finder", title: "Projects", kind: "notes" },
};

const original = [
  [["editor", "notes", "terminal"], ["browser"]],
  [["mail", "calendar"], ["files"]],
];
const board = (grid, workspace, page, focus, extra = {}) => ({
  grid,
  workspace,
  page,
  focus,
  ...extra,
});
const home = board(original, 0, 0, "editor");
const browsing = board(original, 0, 1, "browser");
const below = board(original, 1, 1, "files");
const carried = board(
  [
    [["editor", "terminal"], ["browser"]],
    [["mail", "calendar", "notes"], ["files"]],
  ],
  1,
  0,
  "notes",
);
const step = (caption, state, keys = [], extra = {}) => ({
  caption,
  state,
  keys,
  duration: 2.8,
  device: "keyboard",
  ...extra,
});

// Authored examples, not a second window manager. Each chapter can be replayed independently.
export const scenes = [
  {
    id: "navigate",
    label: "Navigate",
    title: "Move across pages and workspaces.",
    description:
      "Control + arrows, or four-finger swipes. Pages run across; workspaces run up and down. Each page holds up to four tiled windows.",
    steps: [
      step(
        "Pages across. Workspaces down. Your windows are already in place.",
        home,
        [],
        { duration: 2 },
      ),
      step("Control + Right: move to the next page.", browsing, [
        "control",
        "right",
      ]),
      step(
        "Control + Down: the same page column in the workspace below.",
        below,
        ["control", "down"],
      ),
      step("Four fingers down: return to the workspace above.", browsing, [], {
        device: "trackpad",
        gesture: "down",
      }),
      step("Four fingers right: return to the previous page.", home, [], {
        device: "trackpad",
        gesture: "right",
      }),
      step(
        "Four fingers up: move to the workspace below.",
        board(original, 1, 0, "mail"),
        [],
        { device: "trackpad", gesture: "up" },
      ),
      step("Four fingers left: move to the next page.", below, [], {
        device: "trackpad",
        gesture: "left",
      }),
    ],
  },
  {
    id: "cycle",
    label: "Cycle & swap",
    title: "Cycle focus. Add Option to swap.",
    description:
      "Cmd + backtick focuses the next window on this page. Cmd + Option + backtick moves the current window to the next slot.",
    steps: [
      step("Three windows on one page. The editor has focus.", home, [], {
        duration: 2,
      }),
      step(
        "Cmd + backtick: focus Notes, without moving any windows.",
        { ...home, focus: "notes" },
        ["cmd", "backtick"],
      ),
      step("Cmd + backtick: focus Terminal.", { ...home, focus: "terminal" }, [
        "cmd",
        "backtick",
      ]),
      step(
        "Add Option: Terminal swaps into the first slot.",
        board(
          [[["terminal", "notes", "editor"], ["browser"]], original[1]],
          0,
          0,
          "terminal",
        ),
        ["cmd", "option", "backtick"],
      ),
      step(
        "Cmd + Option + backtick: move Terminal to the next slot.",
        board(
          [[["notes", "terminal", "editor"], ["browser"]], original[1]],
          0,
          0,
          "terminal",
        ),
        ["cmd", "option", "backtick"],
      ),
    ],
  },
  {
    id: "move",
    label: "Move & arrange",
    title: "Move windows. Cycle the layout.",
    description:
      "Control + Shift + arrows brings a window along. Control + Option + Space cycles the current page's layout.",
    steps: [
      step(
        "Notes shares this page with the editor and Terminal.",
        { ...home, focus: "notes" },
        [],
        { duration: 2 },
      ),
      step(
        "Control + Shift + Right: a shared window gets its own page.",
        board(
          [[["editor", "terminal"], ["notes"], ["browser"]], original[1]],
          0,
          1,
          "notes",
        ),
        ["control", "shift", "right"],
      ),
      step(
        "Again: a window on its own joins the neighbouring page.",
        board(
          [
            [
              ["editor", "terminal"],
              ["browser", "notes"],
            ],
            original[1],
          ],
          0,
          1,
          "notes",
        ),
        ["control", "shift", "right"],
      ),
      step(
        "Control + Shift + Down: carry Notes into the workspace below.",
        carried,
        ["control", "shift", "down"],
      ),
      step(
        "Control + Option + Space: cycle to the next layout.",
        { ...carried, variant: 1 },
        ["control", "option", "space"],
      ),
      step(
        "Same chord: arrange the three windows in columns.",
        { ...carried, variant: 2 },
        ["control", "option", "space"],
      ),
    ],
  },
  {
    id: "resize",
    label: "Resize",
    title: "Resize with Control + Option + arrows.",
    description:
      "Give the focused window more room. The shared edges move together, so the other windows stay tiled.",
    steps: [
      step("Start with the editor focused on a three-window page.", home, [], {
        duration: 2,
      }),
      step(
        "Control + Option + Right: give the editor more room.",
        { ...home, split: [0.64, 0.5] },
        ["control", "option", "right"],
      ),
      step(
        "Control + Option + Left: bring the divider back.",
        { ...home, split: [0.54, 0.5] },
        ["control", "option", "left"],
      ),
      step(
        "Cmd + backtick: focus Notes.",
        { ...home, focus: "notes", split: [0.54, 0.5] },
        ["cmd", "backtick"],
      ),
      step(
        "Control + Option + Down: make Notes taller.",
        { ...home, focus: "notes", split: [0.54, 0.66] },
        ["control", "option", "down"],
      ),
    ],
  },
];

export const sceneDuration = (scene) =>
  scene.steps.reduce((sum, item) => sum + item.duration, 0);
export const stepStart = (scene, index) =>
  scene.steps.slice(0, index).reduce((sum, item) => sum + item.duration, 0);
export const ease = (value) => {
  const t = Math.max(0, Math.min(1, value));
  return t * t * (3 - 2 * t);
};
export const mix = (a, b, t) => a + (b - a) * t;

export function sampleScene(scene, time, reduced = false) {
  let local = Math.max(0, time);
  let index = 0;
  while (
    index < scene.steps.length - 1 &&
    local + 1e-9 >= scene.steps[index].duration
  ) {
    local = Math.max(0, local - scene.steps[index++].duration);
  }
  const current = scene.steps[index];
  const previous = index
    ? scene.steps[index - 1]
    : { ...current, device: "keyboard", keys: [] };
  return {
    ...current,
    index,
    local,
    previous,
    progress: Math.min(1, Math.max(0, time) / sceneDuration(scene)),
    transition: reduced ? 1 : ease((local - 0.45) / 0.85),
    pressing: reduced || current.hold || (local >= 0.2 && local < 1.6),
    reach: reduced ? 1 : ease(local / 0.35),
    reduced,
  };
}

export function windowRects(state) {
  const windows = {};
  state.grid.forEach((workspace, row) =>
    workspace.forEach((page, column) => {
      const current = row === state.workspace && column === state.page;
      const rects = layout(page.length, current ? state.variant || 0 : 0);
      if (
        state.split &&
        row === state.workspace &&
        column === state.page &&
        page.length === 3
      ) {
        const [x, y] = state.split;
        rects.splice(
          0,
          3,
          { x: 0, y: 0, width: x, height: 1 },
          { x, y: 0, width: 1 - x, height: y },
          { x, y, width: 1 - x, height: 1 - y },
        );
      }
      page.forEach((id, index) => {
        windows[id] = { ...rects[index], page: column, workspace: row };
      });
    }),
  );
  return windows;
}

export function frameWindows(sample) {
  const before = windowRects(sample.previous.state);
  const after = windowRects(sample.state);
  const t = sample.transition;
  const camera = {
    x: mix(sample.previous.state.page, sample.state.page, t),
    y: mix(sample.previous.state.workspace, sample.state.workspace, t),
  };
  return [...new Set([...Object.keys(before), ...Object.keys(after)])].map(
    (id) => {
      const a = before[id] || after[id];
      const b = after[id] || before[id];
      const offset = (state) =>
        state.drag === id ? state.offset || [0, 0] : [0, 0];
      const ao = offset(sample.previous.state),
        bo = offset(sample.state);
      return {
        id,
        page: mix(a.page, b.page, t),
        workspace: mix(a.workspace, b.workspace, t),
        x:
          mix(a.x + a.page * 1.08 + ao[0], b.x + b.page * 1.08 + bo[0], t) -
          camera.x * 1.08,
        y:
          mix(
            a.y + a.workspace * 1.14 + ao[1],
            b.y + b.workspace * 1.14 + bo[1],
            t,
          ) -
          camera.y * 1.14,
        width: mix(a.width, b.width, t),
        height: mix(a.height, b.height, t),
        opacity: !before[id] ? t : !after[id] ? 1 - t : 1,
      };
    },
  );
}
