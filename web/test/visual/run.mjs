// Visual comparison: every SVG golden (Dottie's own export) and dottie.js's SVG for the same page and moment,
// rasterized in the same headless Chromium and compared pixel by pixel. Clean renders must match tightly;
// sketchy ones loosely. Failures are written side by side to test-results/visual/report.html.
//
//   npm run visual            (builds first)

import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import pixelmatch from "pixelmatch";
import { chromium } from "playwright";
import { PNG } from "pngjs";
import { ROOT } from "../browser/serve.mjs";

const { fontFaces, fontFile, parseDottie, resolved, svg, usedFonts, withRoughness } = await import(join(ROOT, "web", "dist", "dottie.js"));
const LIMITS = { clean: 0.001, sketchy: 0.01 };   // fraction of pixels allowed to differ
const OUT = join(ROOT, "web", "test-results", "visual");
mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ deviceScaleFactor: 1 });

async function raster(markup) {
  const m = /width="([\d.]+)" height="([\d.]+)"/.exec(markup);
  const w = Math.min(4000, Math.ceil(Number(m[1]))), h = Math.min(4000, Math.ceil(Number(m[2])));
  await page.setViewportSize({ width: Math.max(w, 1), height: Math.max(h, 1) });
  await page.setContent(`<!doctype html><body style="margin:0;background:#fff">${markup}</body>`);
  await page.evaluate(() => document.fonts.ready);
  return PNG.sync.read(await page.screenshot({ clip: { x: 0, y: 0, width: w, height: h } }));
}

/** `markup` with the bundled fonts the player would add for it (Dottie's SVG embeds its own). */
function withFonts(markup, families) {
  let css = "";
  for (const family of families) {
    for (const face of fontFaces(family)) {
      const data = readFileSync(join(ROOT, "web", "dist", "fonts", fontFile(family, face))).toString("base64");
      css += `@font-face{font-family:'${family}';font-weight:${face.startsWith("bold") ? "bold" : "normal"};`
        + `font-style:${face.endsWith("Italic") || face === "italic" ? "italic" : "normal"};src:url(data:font/woff2;base64,${data})}`;
    }
  }
  return css ? `<style>${css}</style>${markup}` : markup;
}

const failures = [];
let count = 0;
for (const group of ["design", "edge"]) {
  const dir = join(ROOT, "fixtures", "goldens", "svg", group);
  for (const f of readdirSync(dir).sort()) {
    const m = /^(.+)-p(\d+)-t([\d.]+)-(clean|sketchy)\.svg$/.exec(f);
    if (!m) continue;
    const [, name, pageNo, t, look] = m;
    const file = parseDottie(readFileSync(join(ROOT, "fixtures", group, `${name}.dottie`), "utf8"));
    let p = resolved(file.pages[Number(pageNo) - 1], Number(t));
    if (look === "clean") p = withRoughness(p, 0);
    const golden = readFileSync(join(dir, f), "utf8");
    const mine = withFonts(svg(p), usedFonts(p));
    const a = await raster(golden), b = await raster(mine);
    count++;
    if (a.width !== b.width || a.height !== b.height) { failures.push({ f, why: `size ${a.width}x${a.height} vs ${b.width}x${b.height}`, golden, mine }); continue; }
    const diff = new PNG({ width: a.width, height: a.height });
    const bad = pixelmatch(a.data, b.data, diff.data, a.width, a.height, { threshold: 0.1 });
    const share = bad / (a.width * a.height);
    if (share > LIMITS[look]) {
      const img = `${group}-${f.replace(/\.svg$/, "")}-diff.png`;
      writeFileSync(join(OUT, img), PNG.sync.write(diff));
      failures.push({ f: `${group}/${f}`, why: `${(share * 100).toFixed(2)}% of pixels differ`, golden, mine, img });
    }
  }
}
await browser.close();

const report = `<!doctype html><meta charset="utf-8"><title>dottie.js visual diff</title>
<style>body{font:14px system-ui;margin:24px} .row{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px;margin:16px 0 40px}
.row>div{border:1px solid #ccc;overflow:auto} img,svg{max-width:100%;height:auto;display:block}</style>
<h1>dottie.js visual diff: ${failures.length} of ${count} differ</h1>
${failures.map((x) => `<h2>${x.f}: ${x.why}</h2><div class="row"><div><b>Dottie</b>${x.golden}</div><div><b>dottie.js</b>${x.mine}</div>
<div><b>difference</b>${x.img ? `<img src="${x.img}">` : ""}</div></div>`).join("\n")}`;
writeFileSync(join(OUT, "report.html"), report);
console.log(`${count - failures.length} of ${count} match${failures.length ? `; see ${join(OUT, "report.html")}` : ""}`);
for (const x of failures) console.log(`  ${x.f}: ${x.why}`);
process.exit(failures.length ? 1 : 0);
