// Page variables and conditions (state.ts), as State.swift reads them; looping scenes in the player's stepping.

import assert from "node:assert/strict";
import { test } from "node:test";
import { clickTargets } from "../src/clicks.ts";
import { parseDottie } from "../src/model.ts";
import { applyClick, conditionNames, holds } from "../src/state.ts";
import { flowRoute } from "../src/flows.ts";
import { posed, still } from "../src/timeline.ts";
import { read } from "./helpers.ts";

test("conditions read as DottieKit reads them", () => {
  const s = { down: true, east: false };
  assert.equal(holds("down", s), true);
  assert.equal(holds("!down", s), false);
  assert.equal(holds(" ! east ", s), true);
  assert.equal(holds("east || down && !east", s), true);
  assert.equal(holds("east && down", s), false);
  assert.equal(holds("!nobody", s), true);
  assert.equal(holds("down |", s), false);
  assert.equal(holds("", s), false);
  assert.equal(holds("1st", s), false);
  assert.deepEqual(conditionNames("a && !b || c"), ["a", "b", "c"]);
});

test("the state fixture: starting values, other values, and every element", () => {
  const file = parseDottie(read("edge", "state.dottie"));
  const [regions, plain] = file.pages;
  const texts = (p: { elements: { text: string | null; kind: string }[] }) => p.elements.map((e) => e.text ?? e.kind);
  assert.deepEqual(texts(posed(regions, 0)), ["east", "west", "maint", "unknown", "live", "ellipse"]);
  // Down: west and its connector go, backup and its packet come, the keyed connector to backup stays gone.
  assert.deepEqual(texts(posed(regions, 1.5, { down: true })), ["east", "backup", "maint", "unknown", "standby", "ellipse"]);
  assert.equal(posed(regions, 0, "all").elements.length, regions.elements.length);
  // A page with no timeline still follows its state.
  assert.deepEqual(texts(still(plain)), ["on", "flip", "overridden"]);
  assert.deepEqual(file.warnings, []);
});

test("overrides restyle under their condition, and reroute the same packet", () => {
  const page = parseDottie(read("edge", "state.dottie")).pages[2];
  const east = page.elements.find((e) => e.text === "east")!;
  // A bad dash and a reroute target that isn't an id are dropped, as DottieKit drops them; a bad key is skipped.
  assert.equal(east.overrides?.[2].dash, null);
  const [rerouted, stays] = page.elements.filter((e) => e.kind === "ellipse");
  assert.equal(Object.keys(rerouted.overrides![0].reroute!).length, 1);
  assert.equal(stays.overrides![0].reroute, null);
  const down = posed(page, 1).elements.find((e) => e.id === east.id)!;
  assert.equal(down.text, "east (down)");
  assert.equal(down.style.dash, "dashed");
  assert.ok(Math.abs((down.style.opacity ?? 1) - 0.4) < 1e-9);   // 0.8 times 0.5
  assert.equal(posed(page, 1, { down: false }).elements.find((e) => e.id === east.id)!.text, "east");
  assert.equal(posed(page, 1, { down: true, calm: true }).elements.find((e) => e.id === east.id)!.text, "calm");
  assert.equal(posed(page, 1, "all").elements.find((e) => e.id === east.id)!.text, "east");
  // The rerouted dot ends near west (below), the other near east.
  const at = (s: Record<string, boolean>) => posed(page, 2.9, s).elements.find((e) => e.id === rerouted.id)!.y;
  assert.ok(at({ down: true }) > 200 && at({ down: false }) < 120);
});

test("clicks that set and toggle, alone or with a scene", () => {
  const page = parseDottie(read("edge", "state.dottie")).pages[0];
  const clicks = clickTargets(page);
  const byText = (t: string) => clicks.get(page.elements.find((e) => e.text === t)!.id);
  assert.deepEqual(byText("east"), { state: true, toggle: ["down"] });
  assert.deepEqual(byText("backup"), { scene: 1, set: { maint: false } });
  assert.deepEqual(byText("maint"), { state: true, toggle: ["down", "maint"] });
  assert.deepEqual(applyClick({ scene: null, url: null, set: { a: true }, toggle: ["a", "b"] }, { a: false }), { a: false, b: true });
  assert.equal(page.timeline!.markers![0].loop, true);
  assert.equal(page.timeline!.markers![1].loop, null);
});

test("flows: routed over what is drawn, round what is offline, nothing where they can't go", () => {
  const page = parseDottie(read("edge", "flows.dottie")).pages[0];
  const flows = page.flows!;
  const colors = (s: Record<string, boolean>) => posed(page, 1, s).elements.filter((e) => e.text === null && e.kind === "ellipse")
    .map((e) => `${e.style.fill.r},${e.style.fill.g}`);
  // East down (the starting value): no traffic to spare, which is offline; east up: some.
  assert.ok(!colors({}).includes("0.3,0.7"));
  assert.ok(colors({ eastDown: false }).includes("0.3,0.7"));
  // The damaged flow loads, sending nothing.
  assert.equal(flows[flows.length - 1].from, "00000000-0000-0000-0000-000000000000");
});

test("flows take the cheapest route by connector cost, as Flows.swift does", () => {
  const page = parseDottie(read("edge", "flows.dottie")).pages.find((p) => p.name === "Cost")!;
  const [red, blue] = page.flows!;
  const text = (id: string) => page.elements.find((e) => e.id === id)?.text ?? null;
  const ends = (route: [string, boolean][]) => route.map(([id]) => page.elements.find((e) => e.id === id)!.connector!);
  // The direct line costs 5: red goes round by hub, free back along the cost-0 line, then on to dst.
  const r = flowRoute(red.from, red.to, page)!;
  assert.equal(r.length, 2);
  assert.ok(!ends(r).some((c) => text(c.start.elementID!) === "src" && text(c.end.elementID!) === "dst"));
  // Blue goes alt → hub (free) → dst, not through src (a million).
  const b = flowRoute(blue.from, blue.to, page)!;
  assert.deepEqual(ends(b).map((c) => text(c.end.elementID!)), ["hub", "dst"]);
});

test("spread deals a downed destination's packets across the rest; a jam override changes a connector's cost", () => {
  const pages = parseDottie(read("edge", "flows.dottie")).pages;
  const spread = pages.find((p) => p.name === "Spread")!;
  const frame = posed(spread, 1.9, { r1Down: true });
  // Where each packet past x 200 is headed, by color (fill g): orange 0.5, blue 0.5 with r 0.2, green 0.7.
  const ends = (r: number, g: number) => new Set(frame.elements
    .filter((e) => e.text === null && e.kind === "ellipse" && e.style.fill.r === r && e.style.fill.g === g && e.x > 200)
    .map((e) => (e.y < 250 ? "r2" : "r3")));
  // Orange spreads over r2 and r3 while r1 is down; blue goes on to r2; green's first choice, r3, is up.
  assert.deepEqual([...ends(0.9, 0.5)].sort(), ["r2", "r3"]);
  assert.deepEqual([...ends(0.2, 0.5)], ["r2"]);
  assert.deepEqual([...ends(0.2, 0.7)], ["r3"]);
  const cost = pages.find((p) => p.name === "Cost")!;
  const red = cost.flows![0];
  const direct = cost.elements.find((e) => e.connector?.cost === 5)!;
  const route = (jam: boolean) => flowRoute(red.from, red.to, posed(cost, 1, { jam }))!.map(([id]) => id);
  assert.notDeepEqual(route(false), [direct.id]);
  assert.deepEqual(route(true), [direct.id]);
  // A cost that isn't a number loads as none.
  assert.equal(cost.elements.filter((e) => e.connector && e.connector.cost === null).length, 3);
});
