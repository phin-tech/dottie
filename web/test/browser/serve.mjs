// Serves the repo to a Playwright page at http://dottie.test/ without a local server.
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = normalize(join(fileURLToPath(import.meta.url), "..", "..", "..", ".."));
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".json": "application/json",
  ".dottie": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".css": "text/css", ".woff2": "font/woff2" };

export async function serve(page, extra = {}) {
  await page.route("http://dottie.test/**", async (route) => {
    const path = decodeURIComponent(new URL(route.request().url()).pathname);
    if (extra[path] !== undefined) return route.fulfill({ body: extra[path], contentType: types[extname(path)] ?? "text/plain" });
    const file = normalize(join(ROOT, path));
    if (!file.startsWith(ROOT)) return route.fulfill({ status: 403 });
    try { route.fulfill({ body: await readFile(file), contentType: types[extname(file)] ?? "application/octet-stream" }); }
    catch { route.fulfill({ status: 404, body: "not found" }); }
  });
}
