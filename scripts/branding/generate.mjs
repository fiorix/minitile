import { mkdir, mkdtemp, writeFile, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { geometrySVG, LOOP_SECONDS } from "../../web/geometry.mjs";
import { faviconSVG, lockup, lockupSVG, markSVG, palette } from "./logo.mjs";

const assets = fileURLToPath(new URL("../../web/assets/", import.meta.url));
const raster = process.argv.includes("--raster");
const temporary = await mkdtemp(join(tmpdir(), "minitile-brand-"));
const svg = (width, height, content) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${content}</svg>\n`;

function banner(seconds = 0) {
  const brand = lockup();
  return svg(
    1200,
    500,
    `<defs><filter id="banner-glow" x="-10%" y="-40%" width="120%" height="180%"><feGaussianBlur stdDeviation="5"/></filter></defs>
<rect width="1200" height="500" rx="14" fill="${palette.void}"/>
<path d="M32 .5h1136" stroke="${palette.wire}" stroke-opacity=".3"/>
<g transform="translate(52 40) scale(1.05)">${brand.content}</g>
<g font-family="Helvetica Neue,Helvetica,Arial,sans-serif" fill="${palette.ink}">
<text x="56" y="200" font-size="68" font-weight="200" letter-spacing="-2.6">A little order.</text>
<text x="56" y="276" font-size="64" font-weight="200" letter-spacing="9" fill="${palette.neon}" filter="url(#banner-glow)">A lot of space.</text>
<text x="56" y="276" font-size="64" font-weight="200" letter-spacing="9" fill="${palette.core}">A lot of space.</text>
<text x="59" y="332" font-size="18" font-weight="300" fill="${palette.dim}">A minimal tiling window manager for macOS.</text>
<text x="59" y="360" font-size="18" font-weight="300" fill="${palette.dim}">Your windows, in place. Your habits, intact.</text>
<text x="59" y="446" font-size="13" fill="${palette.dim}">Free and open source</text>
<path d="M210 436v12" stroke="${palette.wire}" stroke-opacity=".5"/>
<text x="224" y="446" font-size="13" fill="${palette.dim}">Made for macOS</text>
</g><g transform="translate(605 10)">${geometrySVG(590, 480, seconds)}</g>`,
  );
}

function run(command, args, stdio = "inherit") {
  const result = spawnSync(command, args, { stdio });
  if (result.error || result.status !== 0)
    throw result.error || new Error(`${command} exited ${result.status}`);
}

// Chrome renders the banner's filters, tracking and font weights faithfully; ImageMagick's own SVG renderer does not.
const chrome = [
  process.env.CHROME,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  join(homedir(), "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
].find((path) => path && existsSync(path));

function screenshot(source, target) {
  if (!chrome) throw new Error("set CHROME to a Chrome or Chromium binary");
  run(
    chrome,
    [
      "--headless=new",
      "--disable-gpu",
      "--hide-scrollbars",
      "--no-first-run",
      `--user-data-dir=${join(temporary, "chrome")}`,
      "--default-background-color=00000000",
      "--force-device-scale-factor=1",
      "--window-size=1200,500",
      `--screenshot=${target}`,
      `file://${source}`,
    ],
    "ignore",
  );
}

try {
  await mkdir(assets, { recursive: true });
  await writeFile(
    join(assets, "wireframe.svg"),
    svg(640, 555, geometrySVG(640, 555)),
  );
  await writeFile(join(assets, "welcome.svg"), banner());
  await writeFile(join(assets, "mark.svg"), markSVG());
  await writeFile(join(assets, "favicon.svg"), faviconSVG());
  await writeFile(join(assets, "wordmark.svg"), lockupSVG());
  await writeFile(
    join(assets, "download.svg"),
    svg(
      320,
      52,
      `<rect x=".5" y=".5" width="319" height="51" rx="9" fill="${palette.neon}" fill-opacity=".08" stroke="${palette.neon}"/><text x="160" y="31" text-anchor="middle" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="14" fill="${palette.core}">Download for macOS - coming soon</text>`,
    ),
  );
  console.log("Generated SVG brand assets.");
  if (raster) {
    const fps = 8;
    const frames = [];
    for (let index = 0; index < LOOP_SECONDS * fps; index++) {
      const name = `frame-${String(index).padStart(3, "0")}`;
      await writeFile(join(temporary, `${name}.svg`), banner(index / fps));
      screenshot(join(temporary, `${name}.svg`), join(temporary, `${name}.png`));
      frames.push("-delay", index % 2 ? "13" : "12", join(temporary, `${name}.png`));
    }
    screenshot(join(assets, "welcome.svg"), join(assets, "welcome.png"));
    run("magick", [
      ...frames,
      "-resize",
      "960x400",
      "-background",
      palette.void,
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
