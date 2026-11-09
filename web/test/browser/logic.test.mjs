// Click logic in the browser (ADR 0007, step 2): handlers run only with allow-logic, in QuickJS, sealed off from the
// page; without it a click does its own set and toggle; a runaway or broken handler leaves the state alone.
//   npm run test:browser      (builds first)

import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { chromium } from "playwright";
import { serve } from "./serve.mjs";

let browser;
before(async () => { browser = await chromium.launch(); });
after(async () => { await browser?.close(); });

const id = (n) => `0000000${n}-0000-4000-8000-00000000000${n}`;
const style = { bowing: 1, dash: "solid", fill: { a: 0, b: 0, g: 0, r: 0 }, fillStyle: "solid", fontSize: 14, roughness: 0,
  stroke: { a: 1, b: 0, g: 0, r: 0 }, strokeWidth: 2 };
const LOGIC = `
function next(s, click) { return { stage: (s.stage + 1) % 3, count: s.count + 1, by: click.text === "next" }; }
function peek() {
  globalThis.leak = 1;
  return { window: typeof window === "undefined", document: typeof document === "undefined", fetch: typeof fetch === "undefined",
    xhr: typeof XMLHttpRequest === "undefined", timer: typeof setTimeout === "undefined", date: typeof Date === "undefined",
    random: typeof Math.random === "undefined", parent: typeof parent === "undefined" };
}
function spin() { for (;;) {} }
`;
const drawing = JSON.stringify({ version: 3, pages: [{ id: id(1), name: "p", layers: [{ id: id(2), name: "L", visible: true, locked: false }],
  variables: { stage: 0, count: 0 }, logic: LOGIC,
  elements: ["next", "peek", "spin"].map((t, i) => ({ id: id(3 + i), kind: "rectangle", layerID: id(2), seed: 1, x: i * 150, y: 0, width: 120,
    height: 60, style, text: t, click: { run: t, set: { count: 99 } } })) }] });

async function open(script, { classic = false, allow = true } = {}) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await serve(page, { "/d.dottie": drawing,
    "/t.html": `<!doctype html><script ${classic ? "" : 'type="module" '}src="${script}"></script>`
      + `<body><dottie-player src="/d.dottie" ${allow ? "allow-logic" : ""}></dottie-player></body>` });
  await page.goto("http://dottie.test/t.html");
  await page.waitForFunction(() => document.querySelector("dottie-player")?.playback);
  return { page, errors, close: () => context.close() };
}

/** Clicks element `n` and waits until the variables change or a logic error comes. */
const click = (page, n) => page.evaluate(async (elementID) => {
  const p = document.querySelector("dottie-player");
  const failed = new Promise((r) => p.addEventListener("logicerror", (e) => r({ error: e.detail.error }), { once: true }));
  const changed = new Promise((r) => p.addEventListener("state", () => r({ state: p.variables }), { once: true }));
  p.activate(elementID);
  return Promise.race([failed, changed, new Promise((r) => setTimeout(() => r({ timeout: true, state: p.variables }), 8000))]);
}, id(3 + n));

test("with allow-logic a click runs its handler, in turn, the same in module and classic players", async () => {
  for (const [script, classic] of [["/web/dist/dottie-player.js", false], ["/web/dist/dottie-player.min.js", true]]) {
    const { page, errors, close } = await open(script, { classic });
    let r;
    for (let i = 0; i < 4; i++) r = await click(page, 0);
    assert.deepEqual(r.state, { stage: 1, count: 4, by: true }, script);
    assert.deepEqual(errors, [], script);
    await close();
  }
});

test("without allow-logic the click does its own set instead, and the engine isn't loaded", async () => {
  const { page, close } = await open("/web/dist/dottie-player.js", { allow: false });
  const r = await click(page, 0);
  assert.deepEqual(r.state, { stage: 0, count: 99 });
  assert.equal(await page.evaluate(() => typeof globalThis.DottieLogic), "undefined");
  await close();
});

test("a handler can't reach the page, the network, timers, the clock or randomness", async () => {
  const { page, close } = await open("/web/dist/dottie-player.js");
  const r = await click(page, 1);
  assert.deepEqual(r.state, { stage: 0, count: 0, window: true, document: true, fetch: true, xhr: true, timer: true, date: true,
    random: true, parent: true });
  assert.equal(await page.evaluate(() => typeof globalThis.leak), "undefined", "its globals are its own");
  await close();
});

test("a handler that never stops is stopped, and the state stays as it was", async () => {
  const { page, close } = await open("/web/dist/dottie-player.js");
  const start = Date.now();
  const r = await click(page, 2);
  assert.match(r.error ?? "", /ran too long/);
  assert.ok(Date.now() - start < 5000);
  assert.deepEqual(await page.evaluate(() => document.querySelector("dottie-player").variables), { stage: 0, count: 0 });
  await close();
});

test("a compiled drawing with the engine inlined runs its logic, with no file beside it", async () => {
  const { readFileSync } = await import("node:fs");
  const { compile } = await import("../../dist/compile.js");
  const runtime = readFileSync(new URL("../../dist/dottie-player.min.js", import.meta.url), "utf8");
  const logicEngine = readFileSync(new URL("../../dist/dottie-logic.min.js", import.meta.url), "utf8");
  const context = await browser.newContext();
  const page = await context.newPage();
  // Only these two files exist: no dottie-logic.min.js to fetch.
  await page.route("http://dottie.test/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/c.html") return route.fulfill({ body: `<!doctype html><body><script src="/c.js"></script></body>`, contentType: "text/html" });
    if (path === "/c.js") return route.fulfill({ body: compile(drawing, runtime, { logicEngine }), contentType: "text/javascript" });
    return route.fulfill({ status: 404 });
  });
  await page.goto("http://dottie.test/c.html");
  await page.waitForFunction(() => document.querySelector("dottie-player")?.playback);
  assert.equal(await page.evaluate(() => document.querySelector("dottie-player").hasAttribute("allow-logic")), true);
  const r = await click(page, 0);
  assert.deepEqual(r.state, { stage: 1, count: 1, by: true });
  await context.close();
});
