import test from "node:test";
import assert from "node:assert/strict";
import { layout, layoutNames } from "../layouts.mjs";
import { geometryFrame, workspaceFrame, LOOP_SECONDS } from "../geometry.mjs";

test("every layout covers the page without overlaps or out-of-bounds windows", () => {
  for (let count = 1; count <= 4; count++) {
    for (let variant = 0; variant < layoutNames[count].length; variant++) {
      const windows = layout(count, variant);
      assert.equal(windows.length, count);
      assert.ok(
        Math.abs(
          windows.reduce(
            (area, window) => area + window.width * window.height,
            0,
          ) - 1,
        ) < 1e-10,
      );
      for (const [i, a] of windows.entries()) {
        assert.ok(
          a.x >= 0 && a.y >= 0 && a.x + a.width <= 1 && a.y + a.height <= 1,
        );
        for (const b of windows.slice(i + 1)) {
          const overlapX =
            Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
          const overlapY =
            Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
          assert.ok(overlapX <= 1e-10 || overlapY <= 1e-10);
        }
      }
    }
    assert.deepEqual(
      layout(count, layoutNames[count].length),
      layout(count, 0),
    );
  }
});

test("geometry stays finite at mobile and desktop sizes and closes its animation loop", () => {
  for (const [width, height] of [
    [360, 345],
    [720, 600],
  ]) {
    for (let time = 0; time <= LOOP_SECONDS; time += 0.5) {
      for (const { a, b } of geometryFrame(width, height, time).segments) {
        assert.ok([...a, ...b].every(Number.isFinite));
      }
    }
    const start = geometryFrame(width, height, 0).segments;
    const end = geometryFrame(width, height, LOOP_SECONDS).segments;
    for (let i = 0; i < start.length; i++) {
      for (const key of ["a", "b"])
        for (let j = 0; j < 2; j++)
          assert.ok(Math.abs(start[i][key][j] - end[i][key][j]) < 1e-9);
    }
  }
});

test("the highlighted window moves horizontally between pages and vertically between workspaces", () => {
  const moving = (time) =>
    workspaceFrame(time).windows.find((window) => window.id === "moving");
  const positions = [0, 4, 8, 12, 16].map(moving);
  assert.deepEqual(
    positions.map(({ page, workspace }) => [page, workspace]),
    [
      [0, 0],
      [1, 0],
      [1, 1],
      [0, 1],
      [0, 0],
    ],
  );
  assert.ok(positions[1].x > positions[0].x);
  assert.ok(positions[2].y > positions[1].y);
  assert.ok(positions[3].x < positions[2].x);
  assert.ok(positions[4].y < positions[3].y);
  assert.deepEqual(positions[0], positions[4]);
});

test("the animation conserves windows and has no jumps at page and workspace transitions", () => {
  for (let time = 0; time <= LOOP_SECONDS; time += 0.125) {
    const scene = workspaceFrame(time);
    assert.equal(scene.windows.length, 9);
    assert.equal(new Set(scene.windows.map((window) => window.id)).size, 9);
    for (const window of scene.windows) {
      assert.ok(
        [window.x, window.y, window.width, window.height, window.z].every(
          Number.isFinite,
        ),
      );
      assert.ok(window.width > 0 && window.height > 0);
    }
  }
  for (const boundary of [4, 8, 12, 16]) {
    const before = new Map(
      workspaceFrame(boundary - 1e-6).windows.map((window) => [
        window.id,
        window,
      ]),
    );
    for (const after of workspaceFrame(boundary).windows) {
      for (const key of ["x", "y", "width", "height", "z"]) {
        assert.ok(Math.abs(before.get(after.id)[key] - after[key]) < 1e-8);
      }
    }
  }
});

test("settled windows stay within their page and retile without overlaps", () => {
  for (const time of [0, 4, 8, 12]) {
    const { windows } = workspaceFrame(time);
    const groups = Map.groupBy(
      windows,
      (window) => `${window.page}/${window.workspace}`,
    );
    assert.equal(groups.size, 6);
    for (const group of groups.values()) {
      assert.ok(group.length >= 1 && group.length <= 4);
      for (const [index, a] of group.entries()) {
        const left = a.page * 2.02 - 2.88;
        const top = a.workspace * 1.58 - 1.38;
        assert.ok(
          a.x > left &&
            a.y > top &&
            a.x + a.width < left + 1.72 &&
            a.y + a.height < top + 1.18,
        );
        for (const b of group.slice(index + 1)) {
          assert.ok(
            a.x + a.width <= b.x ||
              b.x + b.width <= a.x ||
              a.y + a.height <= b.y ||
              b.y + b.height <= a.y,
          );
        }
      }
    }
  }
});

test("both axes and page identifiers remain visible in the static composition", () => {
  for (const [width, height] of [
    [320, 355],
    [715, 555],
  ]) {
    const { labels } = geometryFrame(width, height);
    for (const text of ["PAGES", "WORKSPACES", "P1", "P2", "P3", "W1", "W2"]) {
      const label = labels.find((label) => label.text === text);
      assert.ok(label);
      assert.ok(label.position[0] > 8 && label.position[0] < width - 8);
      assert.ok(label.position[1] > 8 && label.position[1] < height - 8);
    }
  }
});
