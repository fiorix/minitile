import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { continuousRect, dmgWindow } from "../../scripts/branding/packaging.mjs";

test("the disk image settings place the icons where the background is drawn", async () => {
  const settings = await readFile(new URL("../../packaging/dmg.py", import.meta.url), "utf8");
  const value = (name) => settings.match(new RegExp(`^${name} = (.+)$`, "m"))?.[1];
  const { width, height, icon, text, app, applications } = dmgWindow;
  assert.match(value("window_rect"), new RegExp(`\\(${width}, ${height}\\)\\)$`));
  assert.equal(value("icon_size"), String(icon));
  assert.equal(value("text_size"), String(text));
  assert.equal(value("icon_locations"), `{appname: (${app.join(", ")}), "Applications": (${applications.join(", ")})}`);
});

test("a continuous-corner rectangle is closed and touches each edge of its box", () => {
  const d = continuousRect(100, 100, 824, 824, 185.4);
  const numbers = d.match(/-?\d+(\.\d+)?/g).map(Number);
  const xs = numbers.filter((_, i) => i % 2 === 0),
    ys = numbers.filter((_, i) => i % 2 === 1);
  assert.ok(d.endsWith("Z"));
  assert.deepEqual([Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)], [100, 924, 100, 924]);
  assert.deepEqual(numbers.slice(-2), numbers.slice(0, 2));
});
