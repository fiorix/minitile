import { mkdir, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { geometrySVG, LOOP_SECONDS } from "../../web/geometry.mjs";

const assets = fileURLToPath(new URL("../../web/assets/", import.meta.url));
const font = process.env.BRAND_FONT;
const raster = process.argv.includes("--raster");
const temporary = await mkdtemp(join(tmpdir(), "minitile-brand-"));
const mark = await readFile(join(assets, "mark.svg"), "utf8");
const markContent = mark.replace(/<svg[^>]*>|<\/svg>/g, "").trim();
const svg = (width, height, content) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${content}</svg>\n`;

function banner(seconds = 0) {
  return svg(
    1200,
    500,
    `<rect width="1200" height="500" rx="14" fill="#0b0d10"/>
<path d="M32 1h1136" stroke="#c8ddf8" stroke-opacity=".35"/>
<g transform="translate(56 44) scale(.95)" fill="none">${markContent}</g>
<g font-family="Helvetica,Arial,sans-serif" fill="#eef0f4">
<text x="107" y="72" font-size="28" font-weight="600">minitile</text>
<text x="56" y="195" font-size="66" font-weight="500">A little order.</text>
<text x="56" y="267" font-size="66" font-weight="500" fill="#9da6b3">A lot of space.</text>
<text x="59" y="322" font-size="18" fill="#adb7c5">A minimal tiling window manager for macOS.</text>
<text x="59" y="351" font-size="18" fill="#adb7c5">Your windows, in place. Your habits, intact.</text>
<text x="59" y="446" font-size="12" fill="#c8ddf8" letter-spacing="1.4">FREE &amp; OPEN SOURCE</text>
<text x="272" y="446" font-size="12" fill="#8993a3">/</text>
<text x="291" y="446" font-size="12" fill="#9da6b3" letter-spacing="1.4">MADE FOR macOS</text>
</g><g transform="translate(605 10)">${geometrySVG(590, 480, seconds)}</g>
<text x="1136" y="449" text-anchor="end" fill="#8993a3" font-family="Helvetica,Arial,sans-serif" font-size="9" letter-spacing="1.5">SPACE, ARRANGED.</text>`,
  );
}

function run(command, args) {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.error || result.status !== 0)
    throw result.error || new Error(`${command} exited ${result.status}`);
}

try {
  await mkdir(assets, { recursive: true });
  await writeFile(
    join(assets, "wireframe.svg"),
    svg(640, 555, geometrySVG(640, 555)),
  );
  await writeFile(join(assets, "welcome.svg"), banner());
  await writeFile(
    join(assets, "wordmark.svg"),
    svg(
      245,
      56,
      `<g transform="translate(0 8)" fill="none">${markContent}</g><text x="54" y="41" font-family="Helvetica,Arial,sans-serif" font-size="40" font-weight="600" fill="#eef0f4">minitile</text>`,
    ),
  );
  await writeFile(
    join(assets, "download.svg"),
    svg(
      320,
      52,
      '<rect width="320" height="52" rx="7" fill="#c8ddf8"/><text x="160" y="32" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" font-size="14" fill="#15202e">Download for macOS - coming soon</text>',
    ),
  );
  console.log("Generated SVG brand assets.");
  if (raster) {
    const fontArgs = font ? ["-font", font] : [];
    const fps = 8;
    const frames = [];
    for (let index = 0; index < LOOP_SECONDS * fps; index++) {
      const path = join(
        temporary,
        `frame-${String(index).padStart(3, "0")}.svg`,
      );
      await writeFile(path, banner(index / fps));
      frames.push("-delay", index % 2 ? "13" : "12", path);
    }
    run("magick", [
      ...fontArgs,
      join(assets, "welcome.svg"),
      join(assets, "welcome.png"),
    ]);
    run("magick", [
      ...fontArgs,
      ...frames,
      "-resize",
      "960x400",
      "-background",
      "#0b0d10",
      "-alpha",
      "remove",
      "-colors",
      "96",
      "-dither",
      "None",
      "-layers",
      "Optimize",
      "-loop",
      "0",
      join(assets, "welcome.gif"),
    ]);
    console.log(
      `Generated welcome.png and the ${LOOP_SECONDS}-second welcome.gif.`,
    );
  }
} finally {
  await rm(temporary, { recursive: true, force: true });
}
