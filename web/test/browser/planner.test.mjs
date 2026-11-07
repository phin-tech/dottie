// Planning a big animation in a worker (planner.ts): the module player and the classic script each start one, the
// plan is exactly the one the page would make, the page isn't held up meanwhile, and where workers are refused the
// player plans in place.
//   npm run test:browser      (builds first)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, before, test } from "node:test";
import { chromium } from "playwright";
import { serve } from "./serve.mjs";

let browser;
before(async () => { browser = await chromium.launch(); });
after(async () => { await browser?.close(); });

/** A 14 × 14 grid of shapes joined three ways each, with flows across it and a shape moving for 10 seconds: about
 * 750 elements over 121 frames, well past what plans in place. */
function big() {
  const id = (n) => `${n.toString(16).toUpperCase().padStart(8, "0")}-0000-4000-8000-${n.toString(16).toUpperCase().padStart(12, "0")}`;
  const style = { bowing: 1, dash: "solid", fill: { a: 0, b: 0, g: 0, r: 0 }, fillStyle: "solid", fontSize: 14, roughness: 1, stroke: { a: 1, b: 0.13, g: 0.12, r: 0.12 }, strokeWidth: 2 };
  const N = 14, L = id(1), els = [], shapes = [];
  let k = 10;
  for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) {
    const s = id(k++); shapes.push(s);
    els.push({ id: s, kind: "rectangle", layerID: L, seed: k * 7919, x: c * 160, y: r * 120, width: 100, height: 60, style, text: `${r}.${c}` });
  }
  for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) {
    const a = shapes[r * N + c];
    for (const [b, routing] of [[c + 1 < N ? shapes[r * N + c + 1] : null, "straight"], [r + 1 < N ? shapes[(r + 1) * N + c] : null, "curved"],
      [r + 1 < N && c + 1 < N ? shapes[(r + 1) * N + c + 1] : null, "elbow"]]) {
      if (!b) continue;
      els.push({ id: id(k++), kind: "connector", layerID: L, seed: k * 31, x: 0, y: 0, width: 0, height: 0, style,
        connector: { start: { elementID: a, x: 0, y: 0 }, end: { elementID: b, x: 0, y: 0 }, routing, hops: true, startHead: "none", endHead: "arrow" } });
    }
  }
  const flows = Array.from({ length: 8 }, (_, i) => ({ id: id(k++), from: shapes[i], to: [shapes[N * N - 1 - i]], every: 0.4 }));
  return JSON.stringify({ version: 1, pages: [{ id: id(2), name: "big", layers: [{ id: L, name: "L", visible: true, locked: false }], elements: els, flows,
    timeline: { duration: 10, fps: 12, tracks: [{ element: shapes[0], keys: [{ t: 0, x: 0 }, { t: 10, x: 400 }] }] } }] });
}
const BIG = big();

/** A page with the player script `script` (a module unless `classic`), counting the workers it starts. */
async function open(script, { classic = false, csp = null, extra = {} } = {}) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.addInitScript(() => {
    const Real = window.Worker;
    window.__workers = 0;
    window.Worker = class extends Real { constructor(...a) { super(...a); window.__workers++; } };
  });
  const meta = csp ? `<meta http-equiv="Content-Security-Policy" content="${csp}">` : "";
  await serve(page, { "/big.dottie": BIG, ...extra,
    "/t.html": `<!doctype html><head>${meta}</head><script ${classic ? "" : `type="module" `}src="${script}"></script><body></body>` });
  await page.goto("http://dottie.test/t.html");
  await page.waitForFunction(() => window.Dottie && customElements.get("dottie-player"));
  return { page, errors, close: () => context.close() };
}

/** Gives a new player the big drawing, then reports: whether it was showing as soon as setFile returned, how many
 * timer ticks ran before it was, and whether its plan is the one this page makes itself. */
const giveBig = (page) => page.evaluate(async () => {
  const text = await (await fetch("/big.dottie")).text();
  const file = Dottie.parseDottie(text);
  const p = document.createElement("dottie-player");
  document.body.append(p);
  let ticks = 0;
  const timer = setInterval(() => { ticks++; }, 1);
  const loaded = new Promise((r) => p.addEventListener("load", r, { once: true }));
  p.setFile(file);
  const atOnce = p.playback !== null;
  await loaded;
  clearInterval(timer);
  // Planned here, from a page of its own (the player's is remembered with the plan the worker sent).
  const mine = Dottie.plan(Dottie.parseDottie(text).pages[0]);
  return { atOnce, ticks, workers: window.__workers, same: JSON.stringify(p.playback.plan) === JSON.stringify(mine), frames: p.playback.frameCount };
});

test("the module player plans a big animation in a worker, and shows exactly what it would have", async () => {
  const { page, errors, close } = await open("/web/dist/dottie-player.js");
  const got = await giveBig(page);
  assert.equal(got.atOnce, false, "setFile returns before the plan is made");
  assert.ok(got.ticks > 0, "the page runs while the worker plans");
  assert.deepEqual({ workers: got.workers, same: got.same, frames: got.frames }, { workers: 1, same: true, frames: 121 });
  assert.deepEqual(errors, []);
  await close();
});

test("the classic script plans in a worker of its own source", async () => {
  const { page, errors, close } = await open("/web/dist/dottie-player.min.js", { classic: true });
  const got = await giveBig(page);
  assert.equal(got.atOnce, false);
  assert.deepEqual({ workers: got.workers, same: got.same, frames: got.frames }, { workers: 1, same: true, frames: 121 });
  assert.deepEqual(errors, []);
  await close();
});

test("a compiled drawing of a big animation plans in a worker", async () => {
  const { compile } = await import("../../dist/compile.js");
  const runtime = readFileSync(new URL("../../dist/dottie-player.min.js", import.meta.url), "utf8");
  const { page, errors, close } = await open("/web/dist/dottie-player.min.js", { classic: true, extra: {
    "/c.html": `<!doctype html><body><script src="/big.js"></script></body>`, "/big.js": compile(BIG, runtime) } });
  await page.goto("http://dottie.test/c.html");
  await page.waitForFunction(() => document.querySelector("dottie-player")?.playback, null, { timeout: 20000 });
  const got = await page.evaluate(() => ({ workers: window.__workers, frames: document.querySelector("dottie-player").playback.frameCount }));
  assert.deepEqual(got, { workers: 1, frames: 121 });
  assert.deepEqual(errors, []);
  await close();
});

test("where workers are refused, the player plans in place", async () => {
  for (const [script, classic] of [["/web/dist/dottie-player.js", false], ["/web/dist/dottie-player.min.js", true]]) {
    const { page, errors, close } = await open(script, { classic, csp: "worker-src 'none'" });
    const got = await giveBig(page);
    assert.deepEqual({ same: got.same, frames: got.frames }, { same: true, frames: 121 }, script);
    assert.deepEqual(errors, [], script);
    await close();
  }
});

test("small drawings plan in place, and a file given while a big one plans wins", async () => {
  const { page, close } = await open("/web/dist/dottie-player.js");
  const got = await page.evaluate(async () => {
    const big = Dottie.parseDottie(await (await fetch("/big.dottie")).text());
    const small = Dottie.parseDottie(await (await fetch("/fixtures/design/example.dottie")).text());
    const p = document.createElement("dottie-player");
    document.body.append(p);
    p.setFile(big);
    p.setFile(small);
    const atOnce = p.playback?.page.name;
    await new Promise((r) => setTimeout(r, 1500));
    return { atOnce, later: p.playback?.page.name, small: small.pages[0].name };
  });
  assert.equal(got.atOnce, got.small, "a small drawing shows as soon as it is given");
  assert.equal(got.later, got.small, "the big plan, coming back later, doesn't replace it");
  await close();
});
