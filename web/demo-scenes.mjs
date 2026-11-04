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
    steps: [
      step(
        "Pages run across and workspaces run down. Each page holds up to four windows.",
        home,
        [],
        { duration: 2 },
      ),
      step("Move to the next page.", browsing, [
        "control",
        "right",
      ]),
      step(
        "Move to the workspace below, in the same column.",
        below,
        ["control", "down"],
      ),
      step("Back to the workspace above.", browsing, [], {
        device: "trackpad",
        gesture: "down",
      }),
      step("Back to the previous page.", home, [], {
        device: "trackpad",
        gesture: "right",
      }),
      step(
        "Move to the workspace below.",
        board(original, 1, 0, "mail"),
        [],
        { device: "trackpad", gesture: "up" },
      ),
      step("Move to the next page.", below, [], {
        device: "trackpad",
        gesture: "left",
      }),
    ],
  },
  {
    id: "cycle",
    label: "Focus",
    title: "Cycle focus. Add Option to swap.",
    steps: [
      step("Three windows share this page. The editor has focus.", home, [], {
        duration: 2,
      }),
      step(
        "Focus moves to Notes. No window moves.",
        { ...home, focus: "notes" },
        ["cmd", "backtick"],
      ),
      step("Focus moves on to Terminal.", { ...home, focus: "terminal" }, [
        "cmd",
        "backtick",
      ]),
      step(
        "Add Option to swap: Terminal takes the first slot.",
        board(
          [[["terminal", "notes", "editor"], ["browser"]], original[1]],
          0,
          0,
          "terminal",
        ),
        ["cmd", "option", "backtick"],
      ),
      step(
        "Again: Terminal moves to the next slot.",
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
    label: "Move",
    title: "Move windows. Cycle the layout.",
    steps: [
      step(
        "Notes shares this page with the editor and Terminal.",
        { ...home, focus: "notes" },
        [],
        { duration: 2 },
      ),
      step(
        "Notes moves out to a page of its own.",
        board(
          [[["editor", "terminal"], ["notes"], ["browser"]], original[1]],
          0,
          1,
          "notes",
        ),
        ["control", "shift", "right"],
      ),
      step(
        "Again: on its own, Notes joins the next page.",
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
        "Notes is carried to the workspace below.",
        carried,
        ["control", "shift", "down"],
      ),
      step(
        "The page switches to its next layout.",
        { ...carried, variant: 1 },
        ["control", "option", "space"],
      ),
      step(
        "Again: three columns.",
        { ...carried, variant: 2 },
        ["control", "option", "space"],
      ),
    ],
  },
  {
    id: "resize",
    label: "Resize",
    title: "Resize with Control + Option + arrows.",
    steps: [
      step("The editor has focus on a three-window page.", home, [], {
        duration: 2,
      }),
      step(
        "The editor grows. Its neighbours stay tiled.",
        { ...home, split: [0.64, 0.5] },
        ["control", "option", "right"],
      ),
      step(
        "The divider moves back.",
        { ...home, split: [0.54, 0.5] },
        ["control", "option", "left"],
      ),
      step(
        "Focus moves to Notes.",
        { ...home, focus: "notes", split: [0.54, 0.5] },
        ["cmd", "backtick"],
      ),
      step(
        "Notes grows taller.",
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
