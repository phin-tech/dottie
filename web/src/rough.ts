// Sketchy strokes and hatching (Rough.swift): a port, not rough.js, so the same seed draws the same lines Dottie does.

import { Path, type Point } from "./path.ts";
import type { SeededRNG } from "./rng.ts";

const offset = (rng: SeededRNG, amount: number, roughness: number): number => rng.signed() * amount * roughness;

/** A hand-drawn line from `a` to `b`, traced twice. With `preserveEnds` both end points stay exact. */
export function line(a: Point, b: Point, rng: SeededRNG, roughness: number, bowing: number, preserveEnds: boolean, into: Path): void {
  const length = Math.hypot(b.x - a.x, b.y - a.y);
  if (!(length > 0.5)) return;
  const gain = length < 200 ? 1 : length > 500 ? 0.4 : -0.0016668 * length + 1.233334;
  const maxOff = length < 20 ? length / 10 : 2.0;
  for (let pass = 0; pass < 2; pass++) {
    const spread = (pass === 0 ? 1.0 : 0.5) * gain;
    const j = (): number => offset(rng, maxOff, roughness) * spread;
    const mid = rng.unit() * 0.4 + 0.3;
    const bow = offset(rng, length / 60, roughness) * bowing * gain;
    const dx = b.x - a.x, dy = b.y - a.y;
    const nx = -dy / length, ny = dx / length;
    // Swift evaluates the arguments left to right: x before y.
    const start = preserveEnds ? a : (() => { const x = a.x + j(); return { x, y: a.y + j() }; })();
    const end = preserveEnds ? b : (() => { const x = b.x + j(); return { x, y: b.y + j() }; })();
    const c1x = a.x + dx * mid * 0.66 + nx * bow + j() * 0.5;
    const c1y = a.y + dy * mid * 0.66 + ny * bow + j() * 0.5;
    const c2x = a.x + dx * (0.5 + mid * 0.5) + nx * bow + j() * 0.5;
    const c2y = a.y + dy * (0.5 + mid * 0.5) + ny * bow + j() * 0.5;
    into.moveTo(start);
    into.curveTo(end, { x: c1x, y: c1y }, { x: c2x, y: c2y });
  }
}

export function polygon(pts: Point[], rng: SeededRNG, roughness: number, bowing: number): Path {
  const path = new Path();
  for (let i = 0; i < pts.length; i++) line(pts[i], pts[(i + 1) % pts.length], rng, roughness, bowing, false, path);
  return path;
}

export function ellipse(r: { x: number; y: number; width: number; height: number }, rng: SeededRNG, roughness: number): Path {
  const path = new Path();
  const cx = r.x + r.width / 2, cy = r.y + r.height / 2;
  const rx = r.width / 2, ry = r.height / 2;
  if (!(rx > 0.5 && ry > 0.5)) return path;
  const n = Math.max(8, Math.min(24, Math.trunc((rx + ry) / 6)));
  const wobble = Math.min(2.5, (rx + ry) / 25) * roughness;
  for (let pass = 0; pass < 2; pass++) {
    const phase = rng.unit() * 2 * Math.PI;
    const sweep = 2 * Math.PI * (pass === 0 ? 1.0 : 1.04);
    const count = Math.trunc((n * sweep) / (2 * Math.PI)) + 1;
    const pts: Point[] = [];
    for (let i = 0; i < count; i++) {
      const t = phase + (sweep * i) / n;
      const wx = rng.signed() * wobble, wy = rng.signed() * wobble;
      pts.push({ x: cx + rx * Math.cos(t) + wx, y: cy + ry * Math.sin(t) + wy });
    }
    catmullRom(pts, path);
  }
  return path;
}

export function catmullRom(p: Point[], path: Path): void {
  if (p.length <= 2) return;
  path.moveTo(p[0]);
  for (let i = 0; i < p.length - 1; i++) {
    const p0 = p[Math.max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[Math.min(i + 2, p.length - 1)];
    path.curveTo(p2, { x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6 }, { x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6 });
  }
}

/** rough.js's default hachure angle. */
export const HACHURE_ANGLE = (-41.0 * Math.PI) / 180;

/** Parallel lines `gap` apart at `angle` inside the polygons (even-odd), aligned to the shape. */
export function hachureLines(polygons: Point[][], angle: number, gap: number): [Point, Point][] {
  if (!(gap > 0)) return [];
  const c = Math.cos(angle), s = Math.sin(angle);
  const rots = polygons.filter((p) => p.length >= 3).map((poly) => poly.map((p) => ({ x: p.x * c + p.y * s, y: -p.x * s + p.y * c })));
  const all = rots.flat();
  if (all.length === 0) return [];
  let minY = Infinity, maxY = -Infinity;
  for (const p of all) { minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y); }
  const back = (x: number, y: number): Point => ({ x: x * c - y * s, y: x * s + y * c });
  const out: [Point, Point][] = [];
  let y = minY + gap / 2;
  while (y < maxY) {
    const xs: number[] = [];
    for (const rot of rots) {
      for (let i = 0; i < rot.length; i++) {
        const a = rot[i], b = rot[(i + 1) % rot.length];
        if ((a.y <= y && y < b.y) || (b.y <= y && y < a.y)) xs.push(a.x + ((y - a.y) / (b.y - a.y)) * (b.x - a.x));
      }
    }
    xs.sort((p, q) => p - q);
    for (let k = 0; k + 1 < xs.length; k += 2) {
      if (xs[k + 1] - xs[k] > 0.5) out.push([back(xs[k], y), back(xs[k + 1], y)]);
    }
    y += gap;
  }
  return out;
}
