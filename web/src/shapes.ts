// The paths an element draws (Renderer.swift): outlines, fills, hatching and connectors, sketchy or clean.
// Pure functions of the element, cached by what they depend on, as Dottie does.

import { type Index, type Route, arrowhead, endpoints, route, routePoints } from "./connector.ts";
import { type Contour, frame, shapeContours, shapePath } from "./element.ts";
import { gridLines } from "./dungeon.ts";
import { type DashStyle, type Element, type Page, orderedElements } from "./model.ts";
import { Path, type Point, type Rect, flatten, maxX, maxY, midX, midY } from "./path.ts";
import { SeededRNG } from "./rng.ts";
import * as Rough from "./rough.ts";

class Cache<V> {
  private map = new Map<string, V>();
  private limit: number;
  constructor(limit = 6000) { this.limit = limit; }
  get(key: string, make: () => V): V {
    const hit = this.map.get(key);
    if (hit !== undefined) return hit;
    const v = make();
    if (this.map.size >= this.limit) this.map.clear();
    this.map.set(key, v);
    return v;
  }
}

const shapes = new Cache<Path>();
const connectors = new Cache<[Path, Path]>();

function shapeKey(e: Element, tag: number): string {
  const s = e.style;
  return [tag, e.kind, e.x, e.y, e.width, e.height, e.seed, s.roughness, s.bowing, s.strokeWidth, s.fillStyle,
    s.fillStyle === "grid" ? cellSize(e) : 0, e.path ? e.path.join(",") : e.subpaths ? JSON.stringify(e.subpaths) : ""].join("|");
}

/** The `.grid` cell size actually drawn. */
export const cellSize = (e: Element): number => Math.max(8, e.style.gridSize ?? 50);

/** Outline path for an element; roughness 0 gives exact geometry. */
export function outline(e: Element): Path {
  if (e.kind === "freehand" && e.path === null) return computeOutline(e);
  return shapes.get(shapeKey(e, 0), () => computeOutline(e));
}

function corners(r: Rect): Point[] {
  return [{ x: r.x, y: r.y }, { x: maxX(r), y: r.y }, { x: maxX(r), y: maxY(r) }, { x: r.x, y: maxY(r) }];
}

function diamondPoints(r: Rect): Point[] {
  return [{ x: midX(r), y: r.y }, { x: maxX(r), y: midY(r) }, { x: midX(r), y: maxY(r) }, { x: r.x, y: midY(r) }];
}

function computeOutline(e: Element): Path {
  const r = frame(e);
  const rng = new SeededRNG(e.seed);
  const rough = e.style.roughness;
  switch (e.kind) {
    case "ellipse":
      return rough <= 0 ? Path.ellipse(r) : Rough.ellipse(r, rng, rough);
    case "diamond":
      if (rough <= 0) return new Path().addLines(diamondPoints(r)).close();
      return Rough.polygon(diamondPoints(r), rng, rough, e.style.bowing);
    case "text": case "connector":
      return Path.rect(r);
    case "freehand":
      return freehandPath(e);
    case "path":
      return rough <= 0 ? shapePath(e) : sketchyShape(e, rng);
    default:   // rectangle, note, image, and kinds this version doesn't know
      return rough <= 0 ? Path.rect(r) : Rough.polygon(corners(r), rng, rough, e.style.bowing);
  }
}

/** A `.path` drawn by hand: straight segments get the doubled line, curves are retraced with nudged controls. */
function sketchyShape(e: Element, rng: SeededRNG): Path {
  const rough = e.style.roughness;
  const out = new Path();
  for (const sub of shapeContours(e)) {
    const p = sub.points;
    for (let k = 0; k < (p.length - 1) / 3; k++) {
      const a = p[3 * k], c1 = p[3 * k + 1], c2 = p[3 * k + 2], b = p[3 * k + 3];
      if (c1.x === a.x && c1.y === a.y && c2.x === b.x && c2.y === b.y) {
        Rough.line(a, b, rng, rough, e.style.bowing, true, out);
        continue;
      }
      const hull = Math.hypot(c1.x - a.x, c1.y - a.y) + Math.hypot(c2.x - c1.x, c2.y - c1.y) + Math.hypot(b.x - c2.x, b.y - c2.y);
      const wobble = Math.min(2.5, hull / 30) * rough;
      for (let pass = 0; pass < 2; pass++) {
        const spread = pass === 0 ? 1.0 : 0.5;
        const j = (): number => rng.signed() * wobble * spread;
        out.moveTo(a);
        const c1x = c1.x + j(), c1y = c1.y + j(), c2x = c2.x + j(), c2y = c2.y + j();
        out.curveTo(b, { x: c1x, y: c1y }, { x: c2x, y: c2y });
      }
    }
  }
  return out;
}

/** A committed stroke is its fitted Bézier chain; an older one is smoothed through its raw points. */
function freehandPath(e: Element): Path {
  const r = frame(e);
  const flat = e.path;
  if (flat && flat.length >= 8 && (flat.length - 2) % 6 === 0) {
    const pt = (i: number): Point => ({ x: r.x + flat[2 * i] * r.width, y: r.y + flat[2 * i + 1] * r.height });
    const path = new Path().moveTo(pt(0));
    for (let s = 0; s < Math.floor((flat.length / 2 - 1) / 3); s++) path.curveTo(pt(3 * s + 3), pt(3 * s + 1), pt(3 * s + 2));
    return path;
  }
  const pts = (e.points ?? []).map((p) => ({ x: r.x + p.x * r.width, y: r.y + p.y * r.height }));
  const path = new Path();
  if (pts.length === 0) return path;
  path.moveTo(pts[0]);
  if (pts.length === 1) return path.lineTo(pts[0]);
  if (pts.length === 2) return path.lineTo(pts[1]);
  for (let i = 1; i < pts.length - 1; i++) {
    path.quadTo({ x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2 }, pts[i]);
  }
  return path.lineTo(pts[pts.length - 1]);
}

/** Every contour of a filled shape as a polygon; only a `.path` has more than one. */
export function fillPolygons(e: Element): Point[][] {
  if (e.kind !== "path") return [fillPolygon(e)];
  return shapeContours(e).map((c: Contour) => flatten(c.points, 3));
}

function fillPolygon(e: Element): Point[] {
  const r = frame(e);
  if (e.kind === "ellipse") {
    const out: Point[] = [];
    for (let i = 0; i < 48; i++) {
      const t = (2 * Math.PI * i) / 48;
      out.push({ x: midX(r) + (r.width / 2) * Math.cos(t), y: midY(r) + (r.height / 2) * Math.sin(t) });
    }
    return out;
  }
  return e.kind === "diamond" ? diamondPoints(r) : corners(r);
}

/** Precise shape used for fills. */
export function fillPath(e: Element): Path {
  const r = frame(e);
  if (e.kind === "ellipse") return Path.ellipse(r);
  if (e.kind === "path") return shapePath(e);
  if (e.kind === "diamond") return new Path().addLines(diamondPoints(r)).close();
  return Path.rect(r);
}

/** Pen-shaded fill for hachure / crossHatch, or the cell lines of a grid fill; empty for solid fills. */
export function hachurePath(e: Element): Path {
  if (e.style.fillStyle === "solid" || ["freehand", "connector", "text", "image"].includes(e.kind)) return new Path();
  return shapes.get(shapeKey(e, 1), () => computeHachure(e));
}

function computeHachure(e: Element): Path {
  const polys = fillPolygons(e);
  const rng = new SeededRNG((e.seed ^ 0x5bd1e995) >>> 0);
  const path = new Path();
  if (e.style.fillStyle === "grid") {
    for (const [a, b] of gridLines(polys, cellSize(e))) {
      if (e.style.roughness <= 0) path.moveTo(a).lineTo(b);
      else Rough.line(a, b, rng, e.style.roughness * 0.3, 0.3, false, path);
    }
    return path;
  }
  const gap = Math.max(4, e.style.strokeWidth * 4);
  const angles = [Rough.HACHURE_ANGLE];
  if (e.style.fillStyle === "crossHatch") angles.push(Rough.HACHURE_ANGLE + Math.PI / 2);
  for (const angle of angles) {
    for (const [a, b] of Rough.hachureLines(polys, angle, gap)) {
      if (e.style.roughness <= 0) path.moveTo(a).lineTo(b);
      else Rough.line(a, b, rng, e.style.roughness * 0.6, 0.5, false, path);
    }
  }
  return path;
}

/** Dash lengths for a stroke width; null for a solid line. */
export function dashPattern(dash: DashStyle, width: number): number[] | null {
  switch (dash) {
    case "solid": return null;
    case "dashed": return [Math.max(8, width * 4), Math.max(6, width * 3)];
    case "dotted": return [0.01, Math.max(5, width * 2.6)];
  }
}

/**
 * A connector as the stroked line (with open arrowheads) and the closed heads filled in the stroke color. `page`
 * holds the connectors a hopping line hops over; without it a line draws no hops.
 */
export function connectorParts(e: Element, index: Index, page?: Page): [Path, Path] {
  const c = e.connector;
  if (!c) return [new Path(), new Path()];
  const [a, b] = endpoints(e, index);
  const r = route(e, index);
  const hops = c.hops === true && page ? hopCrossings(e, r, page, index) : [];
  const key = [e.seed, e.style.roughness, e.style.bowing, e.style.strokeWidth, c.routing, c.startHead, c.endHead,
    c.start.port, c.end.port, a.x, a.y, b.x, b.y, JSON.stringify(c.waypoints), JSON.stringify(hops)].join("|");
  return connectors.get(key, () => computeConnector(e, r, hops));
}

/** How big a hop is for a line `strokeWidth` wide: its radius. */
export function hopRadius(strokeWidth: number): number { return Math.max(6, strokeWidth * 3); }

/**
 * Where a hopping connector's straight segments cross the connectors drawn beneath it (earlier on a visible layer):
 * for each segment, the distances along it, ascending, leaving out crossings too close to its ends or the hop before.
 */
export function hopCrossings(e: Element, r: Route, page: Page, index: Index): number[][] {
  if (r.kind !== "polyline" || r.points.length < 2) return [];
  const pts = r.points;
  const visible = new Set(page.layers.filter((l) => l.visible).map((l) => l.id));
  const beneath: Point[][] = [];
  for (const o of orderedElements(page)) {
    if (o.id === e.id) break;
    if (o.kind !== "connector" || !visible.has(o.layerID)) continue;
    beneath.push(routePoints(route(o, index)));
  }
  const rad = hopRadius(e.style.strokeWidth);
  const out: number[][] = [];
  for (let i = 0; i < pts.length - 1; i++) {
    const p = pts[i], q = pts[i + 1];
    const dx = q.x - p.x, dy = q.y - p.y;
    const length = Math.hypot(dx, dy);
    const found: number[] = [];
    for (const line of beneath) {
      for (let k = 0; k < line.length - 1; k++) {
        const a = line[k], b = line[k + 1];
        const ex = b.x - a.x, ey = b.y - a.y;
        const det = dx * ey - dy * ex;
        if (Math.abs(det) < 1e-9) continue;
        const wx = a.x - p.x, wy = a.y - p.y;
        // Solves p + t·d = a + s·(b - a).
        const t = (wx * ey - wy * ex) / det, s = (wx * dy - wy * dx) / det;
        if (t > 0 && t < 1 && s >= 0 && s <= 1) found.push(t * length);
      }
    }
    const kept: number[] = [];
    for (const at of found.sort((x, y) => x - y)) {
      if (at < rad + 2 || at > length - rad - 2) continue;
      if (kept.length > 0 && at - kept[kept.length - 1] < 2 * rad + 2) continue;
      kept.push(at);
    }
    out.push(kept);
  }
  return out;
}

function computeConnector(e: Element, r: Route, hops: number[][]): [Path, Path] {
  const c = e.connector!;
  const rng = new SeededRNG(e.seed);
  const rough = e.style.roughness, bow = e.style.bowing;
  const path = new Path(), solid = new Path();
  const w = rough * 3;
  const j = (): number => rng.signed() * w;
  if (r.kind === "polyline") {
    const pts = r.points;
    const rad = hopRadius(e.style.strokeWidth);
    const straight = (p: Point, q: Point): void => {
      if (rough <= 0) path.moveTo(p).lineTo(q);
      else Rough.line(p, q, rng, rough, bow, true, path);
    };
    for (let i = 0; i < Math.max(pts.length - 1, 0); i++) {
      const p = pts[i], q = pts[i + 1];
      const length = Math.hypot(q.x - p.x, q.y - p.y);
      const u = length > 0 ? { x: (q.x - p.x) / length, y: (q.y - p.y) / length } : { x: 0, y: 0 };
      const at = (d: number): Point => ({ x: p.x + u.x * d, y: p.y + u.y * d });
      // A hop bulges up, or left on an upright segment.
      let n = { x: u.y, y: -u.x };
      if (n.y > 1e-9 || (Math.abs(n.y) <= 1e-9 && n.x > 0)) n = { x: -n.x, y: -n.y };
      let from = p;
      for (const d of i < hops.length ? hops[i] : []) {
        const s = at(d - rad), m = at(d), t = at(d + rad);
        straight(from, s);
        const k = rad * 0.5523;
        const top = { x: m.x + n.x * rad, y: m.y + n.y * rad };
        path.moveTo(s);
        const a1x = s.x + n.x * k + j(), a1y = s.y + n.y * k + j(), a2x = top.x - u.x * k + j(), a2y = top.y - u.y * k + j();
        path.curveTo(top, { x: a1x, y: a1y }, { x: a2x, y: a2y });
        const b1x = top.x + u.x * k + j(), b1y = top.y + u.y * k + j(), b2x = t.x + n.x * k + j(), b2y = t.y + n.y * k + j();
        path.curveTo(t, { x: b1x, y: b1y }, { x: b2x, y: b2y });
        from = t;
      }
      straight(from, q);
    }
  } else {
    const pts = r.points;
    path.moveTo(pts[0]);
    for (let s = 0; s < Math.floor((pts.length - 1) / 3); s++) {
      const b = pts[3 * s + 1], c2 = pts[3 * s + 2];
      const c1x = b.x + j(), c1y = b.y + j(), c2x = c2.x + j(), c2y = c2.y + j();
      path.curveTo(pts[3 * s + 3], { x: c1x, y: c1y }, { x: c2x, y: c2y });
    }
  }
  const pts = routePoints(r);
  const size = Math.max(10, e.style.strokeWidth * 5);
  const line = (p: Point, q: Point): void => {
    if (rough <= 0) path.moveTo(p).lineTo(q);
    else Rough.line(p, q, rng, rough * 0.5, 0, true, path);
  };
  const head = (kind: string, tip: Point, from: Point): void => {
    const [w1, w2] = arrowhead(tip, from, size);
    switch (kind) {
      case "arrow": line(w1, tip); line(w2, tip); break;
      case "triangle":
        line(w1, tip); line(w2, tip); line(w1, w2);
        solid.moveTo(tip).lineTo(w1).lineTo(w2).close();
        break;
      case "dot": {
        const rad = size * 0.32;
        const ang = Math.atan2(tip.y - from.y, tip.x - from.x);
        const cx = tip.x - rad * Math.cos(ang), cy = tip.y - rad * Math.sin(ang);
        solid.addEllipse({ x: cx - rad, y: cy - rad, width: 2 * rad, height: 2 * rad });
        break;
      }
      case "bar": {
        const ang = Math.atan2(tip.y - from.y, tip.x - from.x) + Math.PI / 2;
        const h = size * 0.5;
        line({ x: tip.x - h * Math.cos(ang), y: tip.y - h * Math.sin(ang) }, { x: tip.x + h * Math.cos(ang), y: tip.y + h * Math.sin(ang) });
        break;
      }
    }
  };
  if (pts.length > 1) {
    head(c.endHead, pts[pts.length - 1], pts[pts.length - 2]);
    head(c.startHead, pts[0], pts[1]);
  }
  return [path, solid];
}
