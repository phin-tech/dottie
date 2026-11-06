// Page variables and conditions (state.ts), as State.swift reads them; looping scenes in the player's stepping.

import assert from "node:assert/strict";
import { test } from "node:test";
import { clickTargets } from "../src/clicks.ts";
import { parseDottie } from "../src/model.ts";
import { applyClick, conditionNames, holds } from "../src/state.ts";
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
  assert.deepEqual(texts(still(plain)), ["on", "flip"]);
  assert.deepEqual(file.warnings, []);
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
