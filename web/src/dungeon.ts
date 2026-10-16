// The `.grid` fill: dungeon floors ruled into cells on a page-wide lattice, and Dyson-style hatching in the rock
// around them (DungeonGrid.swift).

import { frame, rotated } from "./element.ts";
import type { Element, RGBA } from "./model.ts";
import { Path, type Point, type Rect, inset } from "./path.ts";
import { SeededRNG } from "./rng.ts";
import * as Rough from "./rough.ts";
import { cellSize, fillPolygons } from "./shapes.ts";

const SUB = 2;
export const BAND = 0.75;
const GROW = 0.8;
const JITTER = 0.6;

/** Grid lines inside the polygons (even-odd) at world multiples of `cell`, leaving out lines on the edge. */
export function gridLines(polygons: Point[][], cell: number): [Point, Point][] {
  return [...scan(polygons, cell, false), ...scan(polygons, cell, true)];
}

function scan(polygons: Point[][], cell: number, transposed: boolean): [Point, Point][] {
  if (!(cell > 0)) return [];
  const flip = (p: Point): Point => (transposed ? { x: p.y, y: p.x } : p);
  const polys = polygons.filter((p) => p.length >= 3).map((p) => p.map(flip));
  const ys = polys.flat().map((p) => p.y);
  if (ys.length === 0) return [];
  const minY = Math.min(...ys), maxY = Math.max(...ys);
  const out: [Point, Point][] = [];
  for (let y = Math.floor(minY / cell) * cell; y < maxY - 0.5; y += cell) {
    if (!(y > minY + 0.5)) continue;
    const xs: number[] = [];
    for (const poly of polys) {
      for (let i = 0; i < poly.length; i++) {
        const a = poly[i], b = poly[(i + 1) % poly.length];
        if ((a.y <= y && y < b.y) || (b.y <= y && y < a.y)) xs.push(a.x + ((y - a.y) / (b.y - a.y)) * (b.x - a.x));
      }
    }
    xs.sort((p, q) => p - q);
    for (let k = 0; k + 1 < xs.length; k += 2) {
      if (xs[k + 1] - xs[k] > 0.5) out.push([flip({ x: xs[k], y }), flip({ x: xs[k + 1], y })]);
    }
  }
  return out;
}

/** The faint pencil the grid is ruled in. */
export function lineColor(floor: RGBA): RGBA {
  if (0.2126 * floor.r + 0.7152 * floor.g + 0.0722 * floor.b > 0.5) {
    return { r: floor.r * 0.84, g: floor.g * 0.84, b: floor.b * 0.8, a: floor.a };
  }
  return { r: floor.r + (1 - floor.r) * 0.25, g: floor.g + (1 - floor.g) * 0.25, b: floor.b + (1 - floor.b) * 0.25, a: floor.a };
}

export function isFloor(e: Element): boolean {
  return e.style.fillStyle === "grid" && e.style.fill.a > 0 && ["rectangle", "ellipse", "diamond", "path"].includes(e.kind);
}

export interface Rock { ink: RGBA; width: number; path: Path }

interface Floor { contours: Point[][]; box: Rect; cell: number; element: Element }

/** A well-mixed value in [0, 1) from two integers and a salt (Guildhall's 32-bit hash). */
export function hash01(i: number, j: number, salt: number): number {
  let h = (Math.imul(i, 0x27d4eb2d) ^ Math.imul(j, 0x165667b1) ^ Math.imul(salt, 0x9e3779b1)) >>> 0;
  h = Math.imul(h ^ (h >>> 15), 0x85ebca6b) >>> 0;
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35) >>> 0;
  h = (h ^ (h >>> 16)) >>> 0;
  return h / 4294967296;
}

function spot(i: number, j: number, cell: number): Point {
  const s = cell / SUB;
  return { x: (i + 0.5 + (hash01(i, j, 1) - 0.5) * JITTER) * s, y: (j + 0.5 + (hash01(i, j, 2) - 0.5) * JITTER) * s };
}

function clusterSize(i: number, j: number, at: Point, cell: number): number {
  let nearest = Infinity;
  for (let di = -1; di <= 1; di++) {
    for (let dj = -1; dj <= 1; dj++) {
      if (di === 0 && dj === 0) continue;
      const o = spot(i + di, j + dj, cell);
      nearest = Math.min(nearest, Math.hypot(o.x - at.x, o.y - at.y));
    }
  }
  return nearest * GROW;
}

function clusterStrokes(c: Point, angle: number, size: number): [Point, Point][] {
  const dx = Math.cos(angle), dy = Math.sin(angle);
  const half = size * 0.8, gap = size * 0.5;
  return [-1.0, 0, 1].map((k) => {
    const cx = c.x - dy * gap * k, cy = c.y + dx * gap * k;
    return [{ x: cx - dx * half, y: cy - dy * half }, { x: cx + dx * half, y: cy + dy * half }];
  });
}

function contains(contours: Point[][], p: Point): boolean {
  let inside = false;
  for (const poly of contours) {
    if (poly.length < 3) continue;
    let k = poly.length - 1;
    for (let i = 0; i < poly.length; i++) {
      const a = poly[i], b = poly[k];
      if ((a.y > p.y) !== (b.y > p.y) && p.x < ((b.x - a.x) * (p.y - a.y)) / (b.y - a.y) + a.x) inside = !inside;
      k = i;
    }
  }
  return inside;
}

function distance(p: Point, contours: Point[][]): number {
  let best = Infinity;
  for (const poly of contours) {
    if (poly.length < 2) continue;
    for (let i = 0; i < poly.length; i++) {
      const a = poly[i], b = poly[(i + 1) % poly.length];
      const dx = b.x - a.x, dy = b.y - a.y;
      const len2 = dx * dx + dy * dy;
      const t = len2 > 0 ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0;
      best = Math.min(best, Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)));
    }
  }
  return best;
}

const containsPoint = (r: Rect, p: Point): boolean => p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + r.height;

const rockCache = new Map<string, Rock[]>();

/** Hatching for every floor (already filtered by `isFloor`), in page coordinates. */
export function rock(floors: Element[]): Rock[] {
  if (floors.length === 0) return [];
  const key = floors.map((e) => [e.kind, e.x, e.y, e.width, e.height, e.rotation ?? 0, cellSize(e), JSON.stringify(e.subpaths ?? null),
    e.style.stroke.r, e.style.stroke.g, e.style.stroke.b, e.style.stroke.a, e.style.roughness, e.style.strokeWidth].join(",")).join(";");
  const hit = rockCache.get(key);
  if (hit) return hit;
  const v = computeRock(floors);
  if (rockCache.size >= 16) rockCache.clear();
  rockCache.set(key, v);
  return v;
}

function computeRock(elements: Element[]): Rock[] {
  const floors: Floor[] = elements.map((e) => {
    const contours = fillPolygons(e).map((c) => c.map((p) => rotated(e, p)));
    const pts = contours.flat();
    const xs = pts.map((p) => p.x), ys = pts.map((p) => p.y);
    const x0 = xs.length ? Math.min(...xs) : 0, y0 = ys.length ? Math.min(...ys) : 0;
    const box = { x: x0, y: y0, width: (xs.length ? Math.max(...xs) : 0) - x0, height: (ys.length ? Math.max(...ys) : 0) - y0 };
    return { contours, box, cell: cellSize(e), element: e };
  });
  const strokes: [Point, Point, number][][] = floors.map(() => []);
  const seen = new Set<string>();
  for (const f of floors) {
    const subSize = f.cell / SUB;
    const around = inset(f.box, -f.cell, -f.cell);
    const i0 = Math.floor(around.x / subSize), i1 = Math.ceil((around.x + around.width) / subSize);
    const j0 = Math.floor(around.y / subSize), j1 = Math.ceil((around.y + around.height) / subSize);
    const reach = BAND * f.cell;
    for (let i = i0; i < i1; i++) {
      for (let j = j0; j < j1; j++) {
        const k = `${f.cell}|${i}|${j}`;
        if (seen.has(k)) continue;
        seen.add(k);
        const at = spot(i, j, f.cell);
        let nearest = Infinity, owner = -1;
        for (let n = 0; n < floors.length; n++) {
          const g = floors[n];
          if (!containsPoint(inset(g.box, -reach, -reach), at)) continue;
          if (contains(g.contours, at)) { nearest = 0; break; }
          const d = distance(at, g.contours);
          if (d < nearest) { nearest = d; owner = n; }
        }
        if (!(nearest > 0 && nearest <= reach && owner >= 0)) continue;
        const angle = hash01(i, j, 3) * Math.PI;
        const size = clusterSize(i, j, at, f.cell);
        const seed = Math.trunc(hash01(i, j, 4) * 4294967296) >>> 0;
        for (const [a, b] of clusterStrokes(at, angle, size)) strokes[owner].push([a, b, seed]);
      }
    }
  }
  const out: Rock[] = [];
  floors.forEach((f, n) => {
    if (strokes[n].length === 0) return;
    const e = f.element;
    const path = new Path();
    for (const [a, b, seed] of strokes[n]) {
      if (e.style.roughness <= 0) path.moveTo(a).lineTo(b);
      else Rough.line(a, b, new SeededRNG(seed), e.style.roughness * 0.35, 0.2, false, path);
    }
    out.push({ ink: { ...e.style.stroke, a: e.style.stroke.a * 0.6 }, width: Math.max(0.8, e.style.strokeWidth * 0.45), path });
  });
  return out;
}

export { frame };
