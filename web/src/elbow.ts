// Elbow connectors that go round shapes (ElbowRouter.swift, point for point). A connector keeps its plain Z or L when
// that crosses no other shape; when it would cut through one, it is routed over a grid made from the edges of the
// shapes in the way, padded by MARGIN: the shortest way with the fewest bends that crosses none of them, leaving and
// arriving along the same axes as the plain route.

import { rotatedBounds } from "./element.ts";
import type { Element } from "./model.ts";
import type { Point, Rect } from "./path.ts";

/** How far a route keeps from the shapes it goes round. */
export const MARGIN = 16;
/** What a bend costs, in points of length. */
export const BEND = 24;
/** Shapes smaller than this either way (packets, dots, small icons) aren't in the way. */
export const SMALLEST = 24;
/** More shapes in the way than this, and the plain route is kept. */
export const MOST = 48;

/** The box of `e` if a route goes round it: not a connector, text, freehand line or plain path, not invisible, and
 * not small. */
export function obstacle(e: Element): Rect | null {
  if (e.kind === "connector" || e.kind === "text" || e.kind === "freehand") return null;
  if (e.kind === "path" && !e.extension) return null;
  if (e.style.opacity !== null && e.style.opacity <= 0) return null;
  const r = rotatedBounds(e);
  return r.width < SMALLEST || r.height < SMALLEST ? null : r;
}

/** Whether the right-angled line through `points` passes through the inside of `r` (not just along its edge). */
export function crosses(points: Point[], r: Rect): boolean {
  const x1 = r.x + r.width, y1 = r.y + r.height;
  for (let k = 1; k < points.length; k++) {
    const p = points[k - 1], q = points[k];
    if (p.y === q.y) {
      if (r.y < p.y && p.y < y1 && Math.min(p.x, q.x) < x1 && Math.max(p.x, q.x) > r.x) return true;
    } else if (p.x === q.x) {
      if (r.x < p.x && p.x < x1 && Math.min(p.y, q.y) < y1 && Math.max(p.y, q.y) > r.y) return true;
    }
  }
  return false;
}

const padded = (r: Rect): Rect => ({ x: r.x - MARGIN, y: r.y - MARGIN, width: r.width + 2 * MARGIN, height: r.height + 2 * MARGIN });
const inside = (p: Point, r: Rect): boolean => r.x < p.x && p.x < r.x + r.width && r.y < p.y && p.y < r.y + r.height;

// Every frame draws, measures and hops each connector, each asking for its route: the routes worked out lately.
const memo = new Map<string, Point[]>();

/** `plain` (the Z or L from `a` to `b`), or a way round the shapes among `elements` it crosses, leaving out `except`
 * (the connector's own ends). */
export function avoiding(plain: Point[], a: Point, b: Point, startVertical: boolean, endVertical: boolean,
  elements: Iterable<Element>, except: Set<string>): Point[] {
  // A shape either end sits inside (a frame round both, say) can't be gone round.
  const usable = (r: Rect) => !inside(a, padded(r)) && !inside(b, padded(r));
  const all: Rect[] = [];
  let crossed = false;
  for (const e of elements) {
    if (except.has(e.id)) continue;
    const r = obstacle(e);
    if (!r || !usable(r)) continue;
    all.push(r);
    if (!crossed && crosses(plain, r)) crossed = true;
  }
  // Most elbows cross nothing.
  if (!crossed) return plain;
  const key = JSON.stringify([a.x, a.y, b.x, b.y, startVertical, endVertical, all.map((r) => [r.x, r.y, r.width, r.height])]);
  const hit = memo.get(key);
  if (hit) return hit;
  const out = route(plain, a, b, startVertical, endVertical, all);
  if (memo.size >= 512) memo.clear();
  memo.set(key, out);
  return out;
}

function route(plain: Point[], a: Point, b: Point, startVertical: boolean, endVertical: boolean, usable: Rect[]): Point[] {
  let chosen = usable.map((_, i) => i).filter((i) => crosses(plain, usable[i]));
  if (chosen.length === 0) return plain;
  for (let round = 0; round < 4; round++) {
    if (chosen.length > MOST) return plain;
    const path = grid(a, b, startVertical, endVertical, chosen.map((i) => padded(usable[i])));
    if (!path) return plain;
    // Going round one shape can lead through another: add those, and route again.
    const more = usable.map((_, i) => i).filter((i) => !chosen.includes(i) && crosses(path, usable[i]));
    if (more.length === 0) return path;
    chosen = [...chosen, ...more].sort((p, q) => p - q);
  }
  return plain;
}

function grid(a: Point, b: Point, startVertical: boolean, endVertical: boolean, boxes: Rect[]): Point[] | null {
  let xs = [a.x, b.x, (a.x + b.x) / 2], ys = [a.y, b.y, (a.y + b.y) / 2];
  for (const r of boxes) { xs.push(r.x, r.x + r.width); ys.push(r.y, r.y + r.height); }
  xs = [...new Set(xs)].sort((p, q) => p - q); ys = [...new Set(ys)].sort((p, q) => p - q);
  const nx = xs.length, ny = ys.length;
  const ia = xs.indexOf(a.x), ja = ys.indexOf(a.y), ib = xs.indexOf(b.x), jb = ys.indexOf(b.y);
  if (ia < 0 || ja < 0 || ib < 0 || jb < 0) return null;
  // What each box blocks, marked once: the grid points strictly inside it, and the steps through it. The grid has a
  // line on every box edge, so a step between neighbouring lines is wholly inside a box or outside.
  const at = new Map(xs.map((x, k) => [x, k])), bt = new Map(ys.map((y, k) => [y, k]));
  const inner = new Uint8Array(nx * ny), acrossBlocked = new Uint8Array(nx * ny), downBlocked = new Uint8Array(nx * ny);
  for (const r of boxes) {
    const i0 = at.get(r.x), i1 = at.get(r.x + r.width), j0 = bt.get(r.y), j1 = bt.get(r.y + r.height);
    if (i0 === undefined || i1 === undefined || j0 === undefined || j1 === undefined) continue;
    for (let i = i0; i < i1; i++) for (let j = j0; j < j1; j++) {
      if (j > j0) acrossBlocked[i * ny + j] = 1;
      if (i > i0) downBlocked[i * ny + j] = 1;
      if (i > i0 && j > j0) inner[i * ny + j] = 1;
    }
  }
  const blocked = (i: number, j: number) => inner[i * ny + j] === 1;
  const across = (i0: number, i1: number, j: number) => acrossBlocked[Math.min(i0, i1) * ny + j] === 1;
  const down = (j0: number, j1: number, i: number) => downBlocked[i * ny + Math.min(j0, j1)] === 1;
  // A state is a grid point and the axis it was reached along (0 across, 1 down).
  const count = nx * ny * 2;
  const dist = new Array<number>(count).fill(Infinity), prev = new Array<number>(count).fill(-1);
  const done = new Array<boolean>(count).fill(false);
  const heap = new Frontier();
  const first = (ia * ny + ja) * 2 + (startVertical ? 1 : 0);
  dist[first] = 0;
  heap.push(0, first);
  const want = (ib * ny + jb) * 2 + (endVertical ? 1 : 0);
  for (let top = heap.pop(); top; top = heap.pop()) {
    const [cost, s] = top;
    if (done[s]) continue;
    done[s] = true;
    if (s === want) break;
    const node = Math.floor(s / 2), axis = s % 2, i = Math.floor(node / ny), j = node % ny;
    for (const [di, dj] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const ni = i + di, nj = j + dj;
      if (ni < 0 || ni >= nx || nj < 0 || nj >= ny || blocked(ni, nj)) continue;
      const turn = di !== 0 ? 0 : 1;
      if (di !== 0 ? across(i, ni, j) : down(j, nj, i)) continue;
      const length = Math.abs(xs[ni] - xs[i]) + Math.abs(ys[nj] - ys[j]);
      const c = cost + length + (turn !== axis ? BEND : 0);
      const t = (ni * ny + nj) * 2 + turn;
      if (c < dist[t]) { dist[t] = c; prev[t] = s; heap.push(c, t); }
    }
  }
  if (!done[want]) return null;
  const points: Point[] = [];
  for (let s = want; s >= 0; s = prev[s]) { const node = Math.floor(s / 2); points.push({ x: xs[Math.floor(node / ny)], y: ys[node % ny] }); }
  return points.reverse();
}

/** States waiting to be settled, cheapest first, ties to the one queued first (a binary heap). */
class Frontier {
  private heap: [number, number, number][] = [];
  private next = 0;
  private less(i: number, j: number): boolean {
    const a = this.heap[i], b = this.heap[j];
    return a[0] < b[0] || (a[0] === b[0] && a[1] < b[1]);
  }
  push(cost: number, state: number): void {
    this.heap.push([cost, this.next++, state]);
    for (let i = this.heap.length - 1; i > 0;) {
      const up = (i - 1) >> 1;
      if (!this.less(i, up)) break;
      [this.heap[i], this.heap[up]] = [this.heap[up], this.heap[i]]; i = up;
    }
  }
  pop(): [number, number] | null {
    if (this.heap.length === 0) return null;
    const top = this.heap[0], last = this.heap.pop()!;
    if (this.heap.length > 0) {
      this.heap[0] = last;
      for (let i = 0; ;) {
        const l = 2 * i + 1, r = l + 1;
        let m = i;
        if (l < this.heap.length && this.less(l, m)) m = l;
        if (r < this.heap.length && this.less(r, m)) m = r;
        if (m === i) break;
        [this.heap[i], this.heap[m]] = [this.heap[m], this.heap[i]]; i = m;
      }
    }
    return [top[0], top[2]];
  }
}
