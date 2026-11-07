// The fast paths give exactly what the plain ones did: wrapping long tokens, routing flows with a heap, the
// shared page index, memoized plans, and drawing only some parts of a page.

import assert from "node:assert/strict";
import { test } from "node:test";
import { indexOf } from "../src/connector.ts";
import { flowTree } from "../src/flows.ts";
import { type Page, parseDottie } from "../src/model.ts";
import { plan, svgParts } from "../src/svg.ts";
import { measure, wrap } from "../src/text.ts";
import { read } from "./helpers.ts";

/** The character-breaking wrap as it was, measuring every shrinking prefix. */
function plainWrap(s: string, fontSize: number, maxWidth: number): string[] {
  const width = (t: string): number => measure(t, fontSize);
  const out: string[] = [];
  let line = "";
  for (const piece of [s]) {
    line = piece;
    while (width(line.trimEnd()) > maxWidth && [...line.trimEnd()].length > 1) {
      const chars = [...line];
      let n = chars.length - 1;
      while (n > 1 && width(chars.slice(0, n).join("")) > maxWidth) n--;
      out.push(chars.slice(0, n).join(""));
      line = chars.slice(n).join("");
    }
  }
  out.push(line);
  return out;
}

test("an unbroken token wraps where measuring each prefix would break it, kerning and all", () => {
  // Kerned pairs (AV, To, LT), letters outside the font (é, 😀, 漢), and a trailing space.
  const tokens = ["AVAVAVAVTo".repeat(9), "LTWAVoTy".repeat(13) + " ", "é😀漢x".repeat(30), "W", "iiiiiiiiiiiiiiiiiiiiiiiiiiiii"];
  for (const t of tokens) for (const w of [1, 9, 23.5, 40, 117]) {
    assert.deepEqual(wrap(t, 14, w), plainWrap(t, 14, w), `${JSON.stringify(t.slice(0, 12))} at ${w}`);
  }
});

test("a 5,000-character token wraps in seconds, not minutes", () => {
  const t0 = performance.now();
  const lines = wrap("ab".repeat(2500), 14, 40);
  assert.ok(performance.now() - t0 < 5000);
  assert.equal(lines.join(""), "ab".repeat(2500));
});

// MARK: Routing

type Tree = { settled: string[]; came: [string, { from: string; via: string; back: boolean }][] };

/** Dijkstra as it was: a linear scan for the cheapest open shape, ties to the one reached first. */
function plainTree(from: string, frame: Page, offline: Set<string>): Tree | null {
  const shapes = new Set(frame.elements.filter((e) => e.kind !== "connector" && !offline.has(e.id)).map((e) => e.id));
  if (!shapes.has(from)) return null;
  const next = new Map<string, { to: string; via: string; back: boolean; cost: number }[]>();
  const add = (a: string, edge: { to: string; via: string; back: boolean; cost: number }) => next.set(a, [...(next.get(a) ?? []), edge]);
  for (const e of frame.elements) {
    const c = e.connector;
    const a = c?.start.elementID ?? null, b = c?.end.elementID ?? null;
    if (!c || offline.has(e.id) || a === null || b === null || a === b || !shapes.has(a) || !shapes.has(b)) continue;
    const cost = c.cost === null || !Number.isFinite(c.cost) ? 1 : Math.min(Math.max(c.cost, 0), 1_000_000);
    add(a, { to: b, via: e.id, back: false, cost });
    if (c.startHead !== "none") add(b, { to: a, via: e.id, back: true, cost });
  }
  const dist = new Map([[from, 0]]), order = new Map([[from, 0]]);
  let counter = 1;
  const settled: string[] = [], came = new Map<string, { from: string; via: string; back: boolean }>();
  const open = [from];
  while (open.length > 0) {
    let best = 0;
    for (let i = 1; i < open.length; i++) {
      const da = dist.get(open[i])!, db = dist.get(open[best])!;
      if (da < db || (da === db && order.get(open[i])! < order.get(open[best])!)) best = i;
    }
    const n = open.splice(best, 1)[0];
    settled.push(n);
    for (const edge of next.get(n) ?? []) {
      if (settled.includes(edge.to)) continue;
      const d = dist.get(n)! + edge.cost;
      const old = dist.get(edge.to);
      if (old !== undefined && old <= d) continue;
      if (old === undefined) open.push(edge.to);
      dist.set(edge.to, d); order.set(edge.to, counter++);
      came.set(edge.to, { from: n, via: edge.via, back: edge.back });
    }
  }
  return { settled, came: [...came].sort(([a], [b]) => (a < b ? -1 : 1)) };
}

/** A seeded random page of `n` shapes and `m` connectors, costs drawn from a few values so ties are common. */
function network(seed: number, n: number, m: number): Page {
  let s = seed;
  const rand = () => { s = (s * 1103515245 + 12345) % 2 ** 31; return s / 2 ** 31; };
  const id = (k: number) => `00000000-0000-4000-8000-${k.toString(16).padStart(12, "0")}`;
  const style = { bowing: 1, dash: "solid", fill: { a: 0, r: 0, g: 0, b: 0 }, fillStyle: "solid", fontSize: 14, roughness: 0, stroke: { a: 1, r: 0, g: 0, b: 0 }, strokeWidth: 2 };
  const elements: unknown[] = [];
  for (let k = 0; k < n; k++) elements.push({ id: id(k), kind: "rectangle", layerID: id(9999), seed: k, x: k * 10, y: 0, width: 5, height: 5, style });
  for (let k = 0; k < m; k++) {
    const a = Math.floor(rand() * n), b = Math.floor(rand() * n), cost = [null, 1, 2, 0, 0.5][Math.floor(rand() * 5)];
    elements.push({ id: id(n + k), kind: "connector", layerID: id(9999), seed: k, x: 0, y: 0, width: 0, height: 0, style,
      connector: { start: { elementID: id(a), x: 0, y: 0 }, end: { elementID: id(b), x: 0, y: 0 }, routing: "straight",
        startHead: rand() < 0.5 ? "none" : "arrow", endHead: "arrow", ...(cost === null ? {} : { cost }) } });
  }
  const file = { version: 1, pages: [{ id: id(9998), name: "net", layers: [{ id: id(9999), name: "L", visible: true, locked: false }], elements }] };
  return parseDottie(JSON.stringify(file)).pages[0];
}

test("flows route over the same trees as the plain search, ties and offline shapes included", () => {
  let reached = 0;
  for (let seed = 1; seed <= 40; seed++) {
    const page = network(seed, 12 + (seed % 20), 30 + seed * 2);
    const ids = page.elements.map((e) => e.id);
    for (const offline of [new Set<string>(), new Set([ids[3], ids[ids.length - 1], ids[ids.length - 5]])]) {
      for (const from of [ids[0], ids[3], ids[7]]) {
        const tree = flowTree(from, page, offline);
        const got = tree && { settled: [...tree.settled], came: [...tree.came].sort(([a], [b]) => (a < b ? -1 : 1)) };
        assert.deepEqual(got, plainTree(from, page, offline), `seed ${seed} from ${from}`);
        reached += got?.came.length ?? 0;
      }
    }
  }
  assert.ok(reached > 1000, `the trees reach ${reached} shapes in all`);
});

// MARK: Caches

test("a page changed in place is indexed anew", () => {
  const page = parseDottie(read("design", "example.dottie")).pages[0];
  const before = indexOf(page);
  assert.equal(indexOf(page), before, "the same elements share one index");
  const moved = { ...page.elements[0], x: page.elements[0].x + 50 };
  page.elements[0] = moved;
  assert.equal(indexOf(page).get(moved.id), moved);
});

test("a plan is reused only while its page is unchanged", () => {
  const page = parseDottie(read("design", "zoom.dottie")).pages[0];
  const a = plan(page);
  assert.equal(plan(page), a);
  page.timeline = { ...page.timeline!, duration: page.timeline!.duration / 2 };
  const b = plan(page);
  assert.notEqual(b, a);
  assert.ok(b.times.length < a.times.length);
});

test("drawing only some parts draws them exactly as the whole page does", () => {
  for (const [group, name] of [["edge", "waypoints"], ["design", "board"], ["edge", "flows"]]) {
    const page = parseDottie(read(group, `${name}.dottie`)).pages[0];
    const all = svgParts(page, { r: 1, g: 1, b: 1, a: 1 });
    const keep = new Set(all.parts.filter((_, i) => i % 3 === 1).map((p) => p.key));
    const some = svgParts(page, { r: 1, g: 1, b: 1, a: 1 }, all.bounds, false, (k) => keep.has(k));
    assert.deepEqual(some.parts, all.parts.filter((p) => keep.has(p.key)), `${group}/${name}`);
  }
});
