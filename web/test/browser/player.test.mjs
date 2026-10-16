// <dottie-player> in headless Chromium: loading, playing, scenes, scrubbing, keys, reduced motion, stills, errors.
//   npm run test:browser      (builds first)

import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { chromium } from "playwright";
import { serve } from "./serve.mjs";

let browser;
before(async () => { browser = await chromium.launch(); });
after(async () => { await browser?.close(); });

async function open(body, options = {}) {
  const context = await browser.newContext({ reducedMotion: options.reducedMotion ?? "no-preference" });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  await serve(page, { "/t.html": `<!doctype html><script type="module" src="/web/dist/dottie-player.js"></script><body>${body}</body>` });
  await page.goto("http://dottie.test/t.html");
  return { page, errors, close: () => context.close() };
}

const ready = (page, sel = "dottie-player") => page.waitForFunction((s) => document.querySelector(s)?.playback, sel);
const state = (page, sel = "dottie-player") => page.evaluate((s) => {
  const p = document.querySelector(s);
  const bar = p.shadowRoot.querySelector(".bar");
  return { frame: p.playback.frame, frames: p.playback.frameCount, paused: p.paused, controls: !bar.hidden,
    scene: p.shadowRoot.querySelector(".scene").textContent, time: p.shadowRoot.querySelector(".time").textContent,
    paths: p.shadowRoot.querySelectorAll("svg path").length, viewBox: p.shadowRoot.querySelector("svg").getAttribute("viewBox") };
}, sel);

test("plays a demo and loops", async () => {
  const { page, errors, close } = await open(`<dottie-player src="/fixtures/design/live.dottie"></dottie-player>`);
  await ready(page);
  const a = await state(page);
  assert.equal(a.controls, true);
  assert.equal(a.paused, false);
  assert.ok(a.paths > 10);
  await page.waitForFunction(() => document.querySelector("dottie-player").playback.frame > 5);
  assert.deepEqual(errors, []);
  await close();
});

test("a click-through stops at each scene; next and back move between them", async () => {
  const { page, close } = await open(`<dottie-player src="/fixtures/design/tour.dottie"></dottie-player>`);
  await ready(page);
  await page.waitForFunction(() => document.querySelector("dottie-player").paused, null, { timeout: 5000 });
  let s = await state(page);
  assert.equal(s.frame, 29);
  assert.equal(s.scene, "The request comes in");
  await page.evaluate(() => document.querySelector("dottie-player").nextScene());
  await page.waitForFunction(() => { const p = document.querySelector("dottie-player"); return p.paused && p.playback.frame > 29; }, null, { timeout: 8000 });
  s = await state(page);
  assert.equal(s.frame, 77);
  assert.equal(s.scene, "The gateway checks it");
  await page.evaluate(() => document.querySelector("dottie-player").prevScene());
  assert.equal((await state(page)).frame, 29);
  await page.evaluate(() => document.querySelector("dottie-player").prevScene());
  assert.equal((await state(page)).frame, 0);
  await close();
});

test("scrubbing and keys step frames and pause", async () => {
  const { page, close } = await open(`<dottie-player src="/fixtures/design/zoom.dottie"></dottie-player>`);
  await ready(page);
  await page.evaluate(() => { const p = document.querySelector("dottie-player"); const r = p.shadowRoot.querySelector(".scrub"); r.value = "10"; r.dispatchEvent(new Event("input")); });
  let s = await state(page);
  assert.equal(s.frame, 10);
  assert.equal(s.paused, true);
  await page.focus("dottie-player");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press(".");
  assert.equal((await state(page)).frame, 12);
  await page.keyboard.press(",");
  assert.equal((await state(page)).frame, 11);
  const before = (await state(page)).viewBox;
  await page.evaluate(() => { document.querySelector("dottie-player").currentTime = 4; });
  assert.notEqual((await state(page)).viewBox, before, "the camera moves");
  await page.keyboard.press(" ");
  assert.equal((await state(page)).paused, false);
  await close();
});

test("with reduced motion it rests on the poster frame", async () => {
  const { page, close } = await open(`<dottie-player src="/fixtures/design/live.dottie"></dottie-player>`, { reducedMotion: "reduce" });
  await ready(page);
  const s = await state(page);
  assert.equal(s.paused, true);
  assert.equal(s.frame, s.frames - 1);
  await close();
});

test("a still page, a chosen page and moment, inline JSON, and clean drawing", async () => {
  const json = (await import("node:fs")).readFileSync(new URL("../../../fixtures/edge/themes.dottie", import.meta.url), "utf8");
  const { page, errors, close } = await open(`
    <dottie-player id="still" src="/fixtures/design/example.dottie"></dottie-player>
    <dottie-player id="paged" src="/fixtures/edge/themes.dottie" page="blueprint"></dottie-player>
    <dottie-player id="at" src="/fixtures/design/tour.dottie" at="3.2" clean></dottie-player>
    <dottie-player id="inline" page="3"><script type="application/json">${json}</script></dottie-player>`);
  for (const id of ["still", "paged", "at", "inline"]) await ready(page, `#${id}`);
  assert.equal((await state(page, "#still")).controls, false);
  assert.equal((await state(page, "#at")).controls, false);
  const look = await page.evaluate(() => ({
    paged: getComputedStyle(document.querySelector("#paged")).backgroundColor,
    inline: document.querySelector("#inline").playback.page.name,
    roughness: document.querySelector("#at").playback.page.elements.every((e) => e.style.roughness === 0),
  }));
  assert.equal(look.paged, "rgb(27, 58, 92)");
  assert.equal(look.inline, "sepia");
  assert.equal(look.roughness, true);
  assert.deepEqual(errors, []);
  await close();
});

test("a file it can't read shows why, and unknown kinds draw as placeholders", async () => {
  const { page, close } = await open(`
    <dottie-player id="missing" src="/nope.dottie"></dottie-player>
    <dottie-player id="future" src="/fixtures/js-only/future.dottie"></dottie-player>`);
  await page.waitForFunction(() => document.querySelector("#missing").shadowRoot.querySelector(".error"));
  assert.match(await page.evaluate(() => document.querySelector("#missing").shadowRoot.textContent), /404/);
  await ready(page, "#future");
  const text = await page.evaluate(() => document.querySelector("#future").shadowRoot.querySelector("svg").textContent);
  assert.match(text, /hexagon/);
  await close();
});

test("strings from a hostile file never become markup or script", async () => {
  const { page, close } = await open(`<dottie-player src="/fixtures/js-only/hostile.dottie"></dottie-player>`);
  await ready(page);
  await page.waitForTimeout(300);
  const found = await page.evaluate(() => {
    const root = document.querySelector("dottie-player").shadowRoot;
    const all = [...root.querySelectorAll("*")];
    return {
      pwned: window.__pwned === 1,
      handlers: all.flatMap((el) => [...el.attributes].filter((a) => /^on/i.test(a.name)).map((a) => `${el.tagName} ${a.name}`)),
      tags: [...new Set(all.map((el) => el.tagName.toLowerCase()))].filter((t) => ["script", "img", "b", "foreignobject"].includes(t)),
    };
  });
  assert.deepEqual(found, { pwned: false, handlers: [], tags: [] });
  await close();
});

test("a compiled drawing shows itself where its script is, in a target, or from the head", async () => {
  const { readFileSync } = await import("node:fs");
  const { compile } = await import("../../dist/compile.js");
  const runtime = readFileSync(new URL("../../dist/dottie-player.min.js", import.meta.url), "utf8");
  const tour = readFileSync(new URL("../../../fixtures/design/tour.dottie", import.meta.url), "utf8");
  const themes = readFileSync(new URL("../../../fixtures/edge/themes.dottie", import.meta.url), "utf8");
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await serve(page, {
    "/tour.js": compile(tour, runtime),
    "/still.js": compile(themes, runtime, { page: "midnight", label: "Midnight" }),
    "/c.html": `<!doctype html><head><script src="/still.js" data-no-controls></script></head><body>
      <p id="before">before</p><script src="/tour.js"></script><p id="after">after</p>
      <div id="box"></div><script src="/tour.js" data-target="#box" data-at="3.2" data-clean></script></body>`,
  });
  await page.goto("http://dottie.test/c.html");
  await page.waitForFunction(() => document.querySelectorAll("dottie-player").length === 3
    && [...document.querySelectorAll("dottie-player")].every((p) => p.playback));
  const got = await page.evaluate(() => {
    const ps = [...document.querySelectorAll("dottie-player")];
    const inline = document.querySelector("#before").nextElementSibling;
    const boxed = document.querySelector("#box dottie-player");
    const still = ps.find((p) => p.getAttribute("label") === "Midnight");
    return {
      inline: inline.tagName.toLowerCase(), inlineFrames: inline.playback.frameCount,
      boxed: !!boxed && boxed.hasAttribute("clean") && boxed.getAttribute("at") === "3.2", boxedRoughness: boxed.playback.page.elements.every((e) => e.style.roughness === 0),
      stillParent: still.parentElement.tagName.toLowerCase(), stillName: still.playback.page.name, stillControls: !still.shadowRoot.querySelector(".bar").hidden,
    };
  });
  assert.deepEqual(got, { inline: "dottie-player", inlineFrames: 277, boxed: true, boxedRoughness: true, stillParent: "body", stillName: "midnight", stillControls: false });
  assert.deepEqual(errors, []);
  await context.close();
});
