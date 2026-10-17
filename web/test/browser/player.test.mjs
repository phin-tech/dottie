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

// MARK: Clicks

const button = (label) => `dottie-player .dottie-a[aria-label="${label}"]`;
const shown = (page, label) => page.evaluate((l) => {
  const g = document.querySelector("dottie-player").shadowRoot.querySelector(`.dottie-a[aria-label="${l}"]`);
  const h = g.querySelector(".dottie-h"), n = g.querySelector(".dottie-n");
  return h ? (getComputedStyle(h).display !== "none" ? "hover" : getComputedStyle(n).display !== "none" ? "normal" : "none") : "plain";
}, label);

test("clicking an element plays its scene; hover shows its hover look", async () => {
  const { page, errors, close } = await open(`<dottie-player src="/fixtures/edge/clicks.dottie"></dottie-player>`);
  await ready(page);
  let s = await state(page);
  assert.equal(s.paused, true, "a scene at 0 waits for a click");
  assert.equal(s.frame, 0);
  assert.equal(await shown(page, "Auth"), "normal");
  await page.hover(button("Auth"));
  assert.equal(await shown(page, "Auth"), "hover");
  assert.equal(await page.evaluate(() => getComputedStyle(document.querySelector("dottie-player").shadowRoot.querySelector(".dottie-a")).cursor), "pointer");
  await page.click(button("Auth"));
  await page.waitForFunction(() => { const p = document.querySelector("dottie-player"); return p.paused && p.playback.frame > 10; }, null, { timeout: 5000 });
  s = await state(page);
  assert.equal(s.frame, 20, "played from Login flow to the next scene");
  assert.equal(s.scene, "Done");
  assert.equal(await shown(page, "Auth"), "hover", "still under the pointer after the frames changed");
  await page.mouse.move(0, 0);
  assert.equal(await shown(page, "Auth"), "normal");
  // A page can take the click over.
  await page.evaluate(() => document.querySelector("dottie-player").addEventListener("action", (e) => { window.__action = e.detail; e.preventDefault(); }));
  await page.click(button("Back"));
  assert.equal((await state(page)).frame, 20, "cancelled");
  assert.equal(await page.evaluate(() => window.__action.scene), 0);
  assert.deepEqual(errors, []);
  await close();
});

test("clickable elements work from the keyboard", async () => {
  const { page, close } = await open(`<dottie-player src="/fixtures/edge/clicks.dottie"></dottie-player>`);
  await ready(page);
  await page.focus(button("Back"));
  assert.equal(await page.evaluate(() => document.querySelector("dottie-player").shadowRoot.activeElement?.getAttribute("aria-label")), "Back");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => { const p = document.querySelector("dottie-player"); return p.paused && p.playback.frame === 10; }, null, { timeout: 5000 });
  assert.equal(await page.evaluate(() => document.querySelector("dottie-player").shadowRoot.activeElement?.getAttribute("aria-label")), "Back",
    "focus stays on the element as frames change");
  await page.focus(button("Auth"));
  await page.keyboard.press(" ");
  assert.equal((await state(page)).paused, false, "space runs the click rather than pausing");
  await page.waitForFunction(() => { const p = document.querySelector("dottie-player"); return p.paused && p.playback.frame === 20; }, null, { timeout: 5000 });
  const labels = await page.evaluate(() => [...document.querySelector("dottie-player").shadowRoot.querySelectorAll(".dottie-a")]
    .map((g) => `${g.getAttribute("role")}:${g.getAttribute("tabindex")}:${g.getAttribute("aria-label")}`));
  assert.deepEqual(labels, ["button:0:Auth", "button:0:Docs", "button:0:Back", "button:0:Details"]);
  await close();
});

test("a click opens a safe link in a new tab, or another page of the drawing", async () => {
  const { page, close } = await open(`<dottie-player src="/fixtures/edge/clicks.dottie"></dottie-player>`);
  await ready(page);
  await page.evaluate(() => { window.__opened = []; window.open = (...a) => { window.__opened.push(a); return null; }; });
  await page.click(button("Docs"));
  assert.deepEqual(await page.evaluate(() => window.__opened), [["https://example.com/docs", "_blank", "noopener"]]);
  await page.click(button("Details"));
  await page.waitForFunction(() => document.querySelector("dottie-player").playback.page.name === "Details");
  assert.equal(await page.evaluate(() => document.querySelector("dottie-player").getAttribute("page")), "2");
  await close();
});

test("with reduced motion a click goes straight to where its scene stops", async () => {
  const { page, close } = await open(`<dottie-player src="/fixtures/edge/clicks.dottie"></dottie-player>`, { reducedMotion: "reduce" });
  await ready(page);
  await page.click(button("Auth"));
  const s = await state(page);
  assert.equal(s.frame, 20);
  assert.equal(s.paused, true);
  await close();
});

test("clicks from a hostile file never run script", async () => {
  const { page, close } = await open(`<dottie-player src="/fixtures/js-only/hostile-clicks.dottie"></dottie-player>`);
  await ready(page);
  await page.evaluate(() => { window.open = () => { window.__pwned = 1; }; });
  for (const text of ["mixed case", "data"]) await page.click(`dottie-player >> text=${text}`, { force: true });
  const found = await page.evaluate(() => {
    const root = document.querySelector("dottie-player").shadowRoot;
    return { pwned: window.__pwned === 1, clickable: root.querySelectorAll(".dottie-a").length,
      handlers: [...root.querySelectorAll("*")].flatMap((el) => [...el.attributes].filter((a) => /^on/i.test(a.name)).map((a) => a.name)) };
  });
  assert.deepEqual(found, { pwned: false, clickable: 0, handlers: [] });
  await close();
});

// The HTML export (Exporter.player) is its own player, drawn ahead of time; its golden is made by `just goldens`.
async function exported(options = {}) {
  const context = await browser.newContext({ reducedMotion: options.reducedMotion ?? "no-preference" });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await serve(page);
  await page.goto("http://dottie.test/fixtures/goldens/html/clicks.html");
  const frame = () => page.evaluate(() => [...document.querySelectorAll(".f")].findIndex((f) => f.classList.contains("on")));
  const inFrame = (label) => `.f.on .dottie-a[aria-label="${label}"]`;
  return { page, errors, frame, inFrame, close: () => context.close() };
}

test("the HTML export plays a clicked element's scene, with hover and keyboard", async () => {
  const { page, errors, frame, inFrame, close } = await exported();
  assert.equal(await frame(), 0);
  await page.hover(inFrame("Auth"));
  assert.equal(await page.evaluate((s) => getComputedStyle(document.querySelector(s + " .dottie-h")).display, inFrame("Auth")), "inline");
  await page.click(inFrame("Auth"));
  await page.waitForFunction(() => document.querySelector("#play").textContent === "▶" && document.querySelectorAll(".f")[20].classList.contains("on"), null, { timeout: 5000 });
  assert.equal(await page.evaluate(() => document.querySelector("#scene").textContent), "Done");
  await page.focus(inFrame("Back"));
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => document.querySelector("#play").textContent === "▶" && document.querySelectorAll(".f")[10].classList.contains("on"), null, { timeout: 5000 });
  assert.equal(await page.evaluate(() => document.activeElement?.getAttribute("aria-label")), "Back", "focus follows to the frame shown");
  await page.evaluate(() => { window.__opened = []; window.open = (...a) => { window.__opened.push(a); return null; }; });
  await page.click(inFrame("Docs"));
  assert.deepEqual(await page.evaluate(() => window.__opened), [["https://example.com/docs", "_blank", "noopener"]]);
  assert.equal(await page.locator('.dottie-a[aria-label="Details"]').count(), 0, "one page: no page links");
  assert.equal(await page.locator('.dottie-a[aria-label="Script"]').count(), 0);
  assert.equal(await page.locator("defs .dottie-a").count(), 0, "never inside shared <use> markup");
  assert.deepEqual(errors, []);
  await close();
});

test("the HTML export with reduced motion jumps straight to the stop", async () => {
  const { page, frame, inFrame, close } = await exported({ reducedMotion: "reduce" });
  await page.click(inFrame("Auth"));
  assert.equal(await frame(), 20);
  await close();
});

test("symbols play, and a hostile nest of them doesn't hang the player", async () => {
  const { page, errors, close } = await open(`<dottie-player id="a" src="/fixtures/edge/symbols.dottie"></dottie-player>
    <dottie-player id="b" src="/fixtures/js-only/hostile-symbols.dottie"></dottie-player>`);
  await ready(page, "#a");
  await ready(page, "#b");
  await page.waitForFunction(() => document.querySelector("#a").playback.frame > 3);
  assert.ok((await state(page, "#a")).paths > 10);
  assert.deepEqual(errors, []);
  await close();
});

test("the HTML export draws symbols", async () => {
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await serve(page);
  await page.goto("http://dottie.test/fixtures/goldens/html/symbols.html");
  // Frame 15 (1.5 s): every placed copy of Gear shows its labelled box.
  const labels = await page.evaluate(() => {
    const f = document.querySelectorAll(".f")[15];
    const own = [...f.querySelectorAll("tspan")].map((t) => t.textContent);
    const shared = [...f.querySelectorAll("use")].flatMap((u) => [...document.querySelectorAll(u.getAttribute("href") + " tspan")].map((t) => t.textContent));
    return [...own, ...shared].filter((t) => t === "g").length;
  });
  assert.ok(labels >= 4, `${labels} copies of the symbol's label`);
  assert.deepEqual(errors, []);
  await context.close();
});

// MARK: Buttons

const shows = (page, root, label) => page.evaluate(([root, label]) => {
  const base = root ? document.querySelector(root).shadowRoot : document;
  const g = base.querySelector(`${root ? "" : ".f.on "}.dottie-a[aria-label="${label}"]`);
  const on = (c) => { const x = g.querySelector(`:scope > .${c}`); return !!x && getComputedStyle(x).display !== "none"; };
  return ["dottie-n", "dottie-h", "dottie-d"].filter(on).join(" ");
}, [root, label]);

async function buttonChecks(page, root, sel, frame) {
  const go = `${sel}[aria-label="Go"]`;
  assert.equal(await shows(page, root, "Go"), "dottie-n");
  const hit = await page.locator(`${go} .dottie-hit`).boundingBox();
  const frameBox = await page.locator(`${go} .dottie-n`).boundingBox();
  // Inside the button's frame but outside its hit spot: nothing happens.
  await page.mouse.click(frameBox.x + 4, frameBox.y + 4);
  assert.equal(await frame(), 0, "a click outside the hit area does nothing");
  await page.mouse.move(hit.x + hit.width / 2, hit.y + hit.height / 2);
  assert.equal(await shows(page, root, "Go"), "dottie-h", "over");
  await page.mouse.down();
  assert.equal(await shows(page, root, "Go"), "dottie-d", "down");
  await page.mouse.up();
  await page.waitForFunction(([root]) => {
    if (root) { const p = document.querySelector(root); return p.paused && p.playback.frame === 20; }
    return document.querySelector("#play").textContent === "▶" && document.querySelectorAll(".f")[20].classList.contains("on");
  }, [root], { timeout: 5000 });
  assert.equal(await page.locator(`${sel}[aria-label="Go button"], ${sel}[aria-label="Go"]`).count(), 1, "the button with no action isn't one");
}

test("a button symbol in <dottie-player>: up, over, down, hit area, click", async () => {
  const { page, errors, close } = await open(`<dottie-player src="/fixtures/edge/buttons.dottie"></dottie-player>`);
  await ready(page);
  await buttonChecks(page, "dottie-player", "dottie-player .dottie-a", async () => (await state(page)).frame);
  assert.deepEqual(errors, []);
  await close();
});

test("a clip set to play on click replays in <dottie-player>, and jumps to its end with reduced motion", async () => {
  for (const reducedMotion of ["no-preference", "reduce"]) {
    const { page, close } = await open(`<dottie-player src="/fixtures/edge/buttons.dottie"></dottie-player>`, { reducedMotion });
    await ready(page);
    const spinner = "dottie-player .dottie-a[aria-label=\"spinner\"]";
    const before = await page.locator(`${spinner} .dottie-n`).innerHTML();
    await page.evaluate(() => document.querySelector("dottie-player").addEventListener("action", (e) => { window.__action = e.detail; }));
    await page.click(spinner);
    assert.equal(await page.evaluate(() => window.__action.replay), true);
    const at = (await state(page)).frame;
    assert.equal(at, reducedMotion === "reduce" ? 20 : 0, "the page itself stays put (on its poster with reduced motion)");
    if (reducedMotion === "reduce") {
      assert.equal(await page.evaluate(() => document.querySelector("dottie-player").playback.replaying()), false);
    } else {
      assert.equal(await page.evaluate(() => document.querySelector("dottie-player").playback.replaying()), true);
      await page.waitForFunction(() => !document.querySelector("dottie-player").playback.replaying(), null, { timeout: 3000 });
    }
    assert.notEqual(await page.locator(`${spinner} .dottie-n`).innerHTML(), before, "it turned");
    await close();
  }
});

test("a button symbol in the HTML export: up, over, down, hit area, click; no play-on-click there", async () => {
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await serve(page);
  await page.goto("http://dottie.test/fixtures/goldens/html/buttons.html");
  const frame = () => page.evaluate(() => [...document.querySelectorAll(".f")].findIndex((f) => f.classList.contains("on")));
  await buttonChecks(page, null, ".f.on .dottie-a", frame);
  assert.equal(await page.locator('.dottie-a[aria-label="spinner"]').count(), 0, "can't replay here, so it isn't a button");
  assert.equal(await page.locator("defs .dottie-a, defs .dottie-hit").count(), 0);
  await page.focus('.f.on .dottie-a[aria-label="Docs button"]');
  await page.evaluate(() => { window.__opened = []; window.open = (...a) => { window.__opened.push(a); return null; }; });
  await page.keyboard.press("Enter");
  assert.deepEqual(await page.evaluate(() => window.__opened), [["https://example.com/docs", "_blank", "noopener"]]);
  assert.deepEqual(errors, []);
  await context.close();
});

test("a press held across frames while playing still clicks, in both players; Enter works on a button", async () => {
  // The export swaps whole frames, so the press and the release land on different copies of the button.
  const context = await browser.newContext();
  const page = await context.newPage();
  await serve(page);
  await page.goto("http://dottie.test/fixtures/goldens/html/buttons.html");
  await page.evaluate(() => { window.__opened = []; window.open = (...a) => { window.__opened.push(a); return null; }; });
  await page.click("#play");
  const docs = await page.locator('.f.on .dottie-a[aria-label="Docs button"]').boundingBox();
  await page.mouse.move(docs.x + docs.width / 2, docs.y + docs.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(250);
  await page.mouse.up();
  assert.equal((await page.evaluate(() => window.__opened)).length, 1, "the export");
  await context.close();

  const { page: p2, close } = await open(`<dottie-player src="/fixtures/edge/buttons.dottie"></dottie-player>`);
  await ready(p2);
  await p2.evaluate(() => { window.__opened = []; window.open = (...a) => { window.__opened.push(a); return null; }; document.querySelector("dottie-player").play(); });
  const box = await p2.locator('dottie-player .dottie-a[aria-label="Docs button"]').boundingBox();
  await p2.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await p2.mouse.down();
  await p2.waitForTimeout(250);
  await p2.mouse.up();
  assert.equal((await p2.evaluate(() => window.__opened)).length, 1, "<dottie-player>");
  await p2.evaluate(() => document.querySelector("dottie-player").pause());
  await p2.focus('dottie-player .dottie-a[aria-label="Go"]');
  await p2.keyboard.press("Enter");
  await p2.waitForFunction(() => { const p = document.querySelector("dottie-player"); return p.paused && p.playback.frame === 20; }, null, { timeout: 5000 });
  await close();
});

test("the HTML export keeps a hovered button's look steady while it plays", async () => {
  const context = await browser.newContext();
  const page = await context.newPage();
  await serve(page);
  await page.goto("http://dottie.test/fixtures/goldens/html/clicks.html");
  const box = await page.locator('.f.on .dottie-a[aria-label="Auth"]').boundingBox();
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);   // plays on, the pointer still over it
  const seen = [];
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(40);
    seen.push(await page.evaluate(() => {
      const h = document.querySelector('.f.on .dottie-a[aria-label="Auth"] > .dottie-h');
      return h && getComputedStyle(h).display !== "none" ? "H" : "n";
    }));
  }
  assert.equal(seen.join(""), "H".repeat(20));
  await context.close();
});
