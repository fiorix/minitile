// Rebuilds web/assets/demo.svg, the tour's no-JavaScript fallback, from a rendered page.
//
// Serve the site (cd web && npm run dev), dump the opening frame with reduced motion so the tour is paused and settled,
// then pass the dump to this script:
//
//   "$CHROME" --headless=new --force-prefers-reduced-motion --virtual-time-budget=3000 \
//     --dump-dom http://127.0.0.1:4173/ > /tmp/minitile-demo.html
//   node scripts/branding/snapshot-demo.mjs /tmp/minitile-demo.html
//
// The illustration's rules between the illustration:start and illustration:end markers in web/style.css are embedded,
// so the SVG renders the same as an <img>.
import { readFile, writeFile } from "node:fs/promises";

const [dump] = process.argv.slice(2);
if (!dump) throw new Error("usage: snapshot-demo.mjs <dumped page.html>");
const web = new URL("../../web/", import.meta.url);
const html = await readFile(dump, "utf8");
const css = await readFile(new URL("style.css", web), "utf8");

const svg = html.match(/<svg class="desk-illustration"[\s\S]*?<\/svg>(?=\s*<\/div>)/)?.[0];
if (!svg) throw new Error("no rendered tour illustration in the dump");
const rules = css.match(/\/\* illustration:start[\s\S]*?\*\/\n([\s\S]*?)\/\* illustration:end \*\//)?.[1];
if (!rules) throw new Error("no illustration rules between the markers in style.css");

const snapshot = svg
  .replace("<svg ", '<svg xmlns="http://www.w3.org/2000/svg" ')
  .replace(/(<svg[^>]*>)/, `$1\n    <style>${rules.trim()}</style>`)
  .replace(/&nbsp;/g, "&#160;");
await writeFile(new URL("assets/demo.svg", web), `${snapshot}\n`);
console.log("Wrote web/assets/demo.svg.");
