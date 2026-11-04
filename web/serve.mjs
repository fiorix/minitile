import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, sep, extname } from "node:path";

const root = fileURLToPath(new URL(".", import.meta.url));
const port = Number(process.env.PORT || 4173);
const types = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".gif": "image/gif",
  ".png": "image/png",
};
const server = createServer(async (request, response) => {
  try {
    if (!["GET", "HEAD"].includes(request.method)) {
      response.writeHead(405, { Allow: "GET, HEAD" }).end();
      return;
    }
    const pathname = decodeURIComponent(
      new URL(request.url, "http://localhost").pathname,
    );
    let path = resolve(root, `.${pathname}`);
    if (!path.startsWith(root) && path !== root.slice(0, -1)) {
      response.writeHead(403).end("Forbidden");
      return;
    }
    if ((await stat(path)).isDirectory()) path += `${sep}index.html`;
    const body = await readFile(path);
    response.writeHead(200, {
      "Content-Type": types[extname(path)] || "application/octet-stream",
      "Cache-Control": "no-cache",
      "X-Content-Type-Options": "nosniff",
    });
    response.end(request.method === "HEAD" ? undefined : body);
  } catch (error) {
    const status =
      error instanceof URIError
        ? 400
        : ["ENOENT", "ENOTDIR"].includes(error.code)
          ? 404
          : 500;
    response
      .writeHead(status)
      .end(status === 404 ? "Not found" : "Request failed");
  }
});
server.listen(port, "127.0.0.1", () =>
  console.log(`minitile preview: http://127.0.0.1:${port}`),
);
