import test from "node:test";
import assert from "node:assert/strict";
import {
  apps,
  scenes,
  sampleScene,
  sceneDuration,
  stepStart,
  windowRects,
  frameWindows,
} from "../demo-scenes.mjs";
import {
  keys,
  minimapFrame,
  mapMetrics,
  gestureFrame,
  trackpad,
} from "../demo-art.mjs";

const chapter = (id) => scenes.find((scene) => scene.id === id);
const shown = (state) => state.grid[state.workspace][state.page];
const ids = (state) => state.grid.flat(2).sort();

test("the grid is an exact scaled projection of the animated screen, including moves, layout changes, and resizing", () => {
  const scale = mapMetrics.width / 766;
  const strideX = mapMetrics.width + mapMetrics.padding * 2 + mapMetrics.gap;
  const strideY = mapMetrics.height + mapMetrics.padding * 2 + mapMetrics.gap;
  for (const scene of scenes)
    for (let time = 0; time < sceneDuration(scene); time += 0.2) {
      const sample = sampleScene(scene, time);
      const screen = frameWindows(sample);
      const mini = minimapFrame(sample);
      assert.deepEqual(
        mini.map((tile) => tile.id),
        screen.map((window) => window.id),
      );
      const cameraX =
        sample.previous.state.page +
        (sample.state.page - sample.previous.state.page) * sample.transition;
      const cameraY =
        sample.previous.state.workspace +
        (sample.state.workspace - sample.previous.state.workspace) *
          sample.transition;
      for (const [i, window] of screen.entries()) {
        const tile = mini[i];
        assert.ok(
          Math.abs(tile.width / scale - (window.width * 766 - 8)) < 1e-8,
        );
        assert.ok(
          Math.abs(tile.height / scale - (window.height * 328 - 8)) < 1e-8,
        );
        assert.ok(
          Math.abs(
            (tile.x - window.page * strideX - mapMetrics.padding) / scale -
              ((window.x + (cameraX - window.page) * 1.08) * 766 + 4),
          ) < 1e-8,
        );
        assert.ok(
          Math.abs(
            (tile.y - window.workspace * strideY - mapMetrics.padding) / scale -
              ((window.y + (cameraY - window.workspace) * 1.14) * 328 + 4),
          ) < 1e-8,
        );
        assert.equal(tile.opacity, window.opacity);
      }
    }
});

test("the three-window grid uses one tall tile and two stacked tiles, and tracks divider changes", () => {
  const resize = chapter("resize");
  const [editor, notes, terminal] = minimapFrame(sampleScene(resize, 0, true));
  assert.ok(editor.height > notes.height * 2);
  assert.equal(notes.x, terminal.x);
  assert.ok(terminal.y > notes.y);
  assert.equal(editor.y, notes.y);
  const changed = minimapFrame(sampleScene(resize, stepStart(resize, 1), true));
  assert.ok(changed.find((tile) => tile.id === "editor").width > editor.width);
  assert.ok(changed.find((tile) => tile.id === "notes").width < notes.width);
});

test("each authored state has unique windows, a visible focus, and valid tiled pages", () => {
  for (const scene of scenes)
    for (const { state } of scene.steps) {
      const all = ids(state);
      assert.equal(new Set(all).size, all.length, scene.id);
      assert.ok(shown(state).includes(state.focus), scene.id);
      if (state.switcher) assert.ok(all.includes(state.switcher));
      for (const id of all) assert.ok(apps[id]);
      const rects = windowRects(state);
      for (const workspace of state.grid)
        for (const page of workspace) {
          assert.ok(page.length >= 1 && page.length <= 4);
          assert.ok(
            Math.abs(
              page.reduce(
                (sum, id) => sum + rects[id].width * rects[id].height,
                0,
              ) - 1,
            ) < 1e-9,
          );
          for (const [i, id] of page.entries()) {
            const a = rects[id];
            assert.ok(
              a.x >= 0 && a.y >= 0 && a.x + a.width <= 1 && a.y + a.height <= 1,
            );
            for (const other of page.slice(i + 1)) {
              const b = rects[other];
              assert.ok(
                Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x) <
                  1e-9 ||
                  Math.min(a.y + a.height, b.y + b.height) -
                    Math.max(a.y, b.y) <
                    1e-9,
              );
            }
          }
        }
    }
});

test("the tour teaches four groups using the same pre-populated grid", () => {
  assert.deepEqual(
    scenes.map((scene) => scene.id),
    ["navigate", "cycle", "move", "resize"],
  );
  for (const scene of scenes)
    for (const item of scene.steps)
      assert.deepEqual(ids(item.state), ids(scenes[0].steps[0].state));
});

test("keyboard navigation and four-finger swipes preserve page columns and follow finger directions", () => {
  const steps = chapter("navigate").steps;
  assert.deepEqual(
    steps.map(({ state }) => [state.workspace, state.page]),
    [
      [0, 0],
      [0, 1],
      [1, 1],
      [0, 1],
      [0, 0],
      [1, 0],
      [1, 1],
    ],
  );
  assert.deepEqual(
    steps.slice(3).map((item) => item.gesture),
    ["down", "right", "up", "left"],
  );
  assert.ok(
    steps
      .slice(3)
      .every((item) => item.device === "trackpad" && item.keys.length === 0),
  );
});

test("backtick changes focus; adding Option swaps slots without losing focus", () => {
  const steps = chapter("cycle").steps;
  for (const item of steps.slice(0, 3))
    assert.deepEqual(item.state.grid, steps[0].state.grid);
  assert.deepEqual(
    steps.slice(0, 3).map((item) => item.state.focus),
    ["editor", "notes", "terminal"],
  );
  for (const item of steps.slice(3)) {
    assert.deepEqual(item.keys, ["cmd", "option", "backtick"]);
    assert.equal(item.state.focus, "terminal");
  }
  assert.equal(shown(steps[3].state)[0], "terminal");
  assert.equal(shown(steps[4].state)[1], "terminal");
});

test("nudging splits a shared page, merges a solo window, then carries it down", () => {
  const steps = chapter("move").steps;
  assert.deepEqual(shown(steps[1].state), ["notes"]);
  assert.equal(steps[1].state.grid[0].length, 3);
  assert.deepEqual(shown(steps[2].state), ["browser", "notes"]);
  assert.equal(steps[2].state.grid[0].length, 2);
  assert.equal(steps[3].state.workspace, 1);
  assert.deepEqual(shown(steps[3].state), ["mail", "calendar", "notes"]);
});

test("Control+Option+Space cycles the shown page without moving windows to different pages", () => {
  const steps = chapter("move").steps;
  for (const item of steps.slice(4)) {
    assert.deepEqual(item.keys, ["control", "option", "space"]);
    assert.deepEqual(item.state.grid, steps[3].state.grid);
    assert.equal(item.state.focus, "notes");
    assert.deepEqual(
      windowRects(item.state).editor,
      windowRects(steps[3].state).editor,
    );
  }
  const mirrored = windowRects(steps[4].state);
  assert.equal(mirrored.calendar.x, mirrored.notes.x);
  assert.equal(mirrored.mail.height, 1);
  assert.equal(mirrored.mail.x, 0.5);
  const top = windowRects(steps[5].state);
  assert.deepEqual([top.mail.y, top.mail.width], [0, 1]);
  assert.equal(top.calendar.y, top.notes.y);
  assert.equal(top.calendar.y, top.mail.height);
});

test("resizes move shared dividers while the other windows remain tiled", () => {
  const steps = chapter("resize").steps;
  assert.ok(
    windowRects(steps[1].state).editor.width >
      windowRects(steps[0].state).editor.width,
  );
  assert.ok(
    windowRects(steps[2].state).editor.width <
      windowRects(steps[1].state).editor.width,
  );
  assert.ok(
    windowRects(steps[4].state).notes.height >
      windowRects(steps[3].state).notes.height,
  );
});

test("animation frames are finite and continuous across actions, and reduced motion settles immediately", () => {
  for (const scene of scenes) {
    for (let time = 0; time <= sceneDuration(scene); time += 0.1) {
      for (const rect of frameWindows(sampleScene(scene, time))) {
        assert.ok(
          [rect.x, rect.y, rect.width, rect.height, rect.opacity].every(
            Number.isFinite,
          ),
        );
        assert.ok(
          rect.width > 0 &&
            rect.height > 0 &&
            rect.opacity >= 0 &&
            rect.opacity <= 1,
        );
      }
    }
    for (let i = 1; i < scene.steps.length; i++) {
      const at = stepStart(scene, i);
      const before = frameWindows(sampleScene(scene, at - 1e-7)).filter(
        (rect) => rect.opacity > 0.999,
      );
      const after = frameWindows(sampleScene(scene, at));
      for (const a of before) {
        const b = after.find((rect) => rect.id === a.id);
        for (const prop of ["x", "y", "width", "height", "opacity"])
          assert.ok(
            Math.abs(a[prop] - b[prop]) < 1e-6,
            `${scene.id}/${i}/${prop}`,
          );
      }
      assert.equal(sampleScene(scene, at, true).transition, 1);
      assert.equal(sampleScene(scene, at, true).reach, 1);
    }
  }
});

test("every key a step lights is on the keyboard", () => {
  for (const scene of scenes)
    for (const step of scene.steps)
      for (const id of step.keys)
        assert.ok(
          keys.some((key) => key.id === id),
          `${scene.id}: ${id}`,
        );
});

test("trackpad swipes move four fingertips in the swipe's direction and stay on the trackpad", () => {
  const directions = { left: [-1, 0], right: [1, 0], up: [0, -1], down: [0, 1] };
  for (const scene of scenes)
    for (let index = 0; index < scene.steps.length; index++) {
      const step = scene.steps[index];
      const at = stepStart(scene, index);
      const early = gestureFrame(sampleScene(scene, at + 0.3));
      if (step.device !== "trackpad") {
        assert.equal(early, null);
        continue;
      }
      const late = gestureFrame(sampleScene(scene, at + 1.4));
      const [dx, dy] = directions[step.gesture];
      assert.equal(late.dots.length, 4);
      for (let i = 0; i < 4; i++) {
        const [ax, ay] = early.dots[i].at,
          [bx, by] = late.dots[i].at;
        assert.ok((bx - ax) * dx + (by - ay) * dy > 20, step.gesture);
        assert.ok(Math.abs((bx - ax) * dy) + Math.abs((by - ay) * dx) < 1e-9);
        for (const [x, y] of [early.dots[i].from, late.dots[i].at]) {
          assert.ok(x > trackpad.x && x < trackpad.x + trackpad.width);
          assert.ok(y > trackpad.y && y < trackpad.y + trackpad.height);
        }
      }
      assert.deepEqual(
        gestureFrame(sampleScene(scene, at, true)).dots.map((dot) => dot.at),
        late.dots.map((dot) => dot.at),
      );
    }
});
