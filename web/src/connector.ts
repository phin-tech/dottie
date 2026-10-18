// Connector geometry (Connector.swift): endpoints from bindings, routes, arrowhead wings.

import { angle, center, frame, rotated, shapeContours, unrotated } from "./element.ts";
import type { Element, Endpoint, Page, Port } from "./model.ts";
import { type Point, type Rect, bezierPoint, maxX, maxY, midX, midY } from "./path.ts";

export type Index = Map<string, Element>;

export function portPoint(shape: Element, port: Port): Point {
  const r = frame(shape);
  const p = port === "top" ? { x: midX(r), y: r.y }
    : port === "right" ? { x: maxX(r), y: midY(r) }
    : port === "bottom" ? { x: midX(r), y: maxY(r) }
    : { x: r.x, y: midY(r) };
  return rotated(shape, p);
}

/** A contour's vertices: 16 steps along each cubic segment, then the end point. */
function flattenContour(cp: Point[]): Point[] {
  const out: Point[] = [];
  for (let s = 0; s + 3 < cp.length; s += 3) {
    const seg = cp.slice(s, s + 4);
    for (let k = 0; k < 16; k++) out.push(bezierPoint(seg, k / 16));
  }
  out.push(cp[cp.length - 1]);
  return out;
}

/**
 * Where a line coming in from `c + d` toward the center `c` first meets a path's drawing, both in the unrotated frame,
 * or null: the crossing farthest from `c` that is not past `c + d`, so lines inside the shape (a cylinder's rims, a
 * hole) never catch the connector. With no crossing before the far end, the nearest one ahead of `c`.
 */
function outlineCrossing(shape: Element, c: Point, d: Point): Point | null {
  let nearest: number | null = null, farthest: number | null = null;
  for (const contour of shapeContours(shape)) {
    const pts = flattenContour(contour.points);
    const n = pts.length;
    const edges = contour.closed ? n : n - 1;
    for (let i = 0; i < edges; i++) {
      const a = pts[i], b = pts[(i + 1) % n];
      const e = { x: b.x - a.x, y: b.y - a.y }, w = { x: a.x - c.x, y: a.y - c.y };
      const det = e.x * d.y - d.x * e.y;
      if (det === 0) continue;
      // Solves c + t·d = a + s·e.
      const t = (e.x * w.y - e.y * w.x) / det, s = (d.x * w.y - d.y * w.x) / det;
      if (!(t > 0 && s >= 0 && s <= 1)) continue;
      if (nearest === null || t < nearest) nearest = t;
      if (t <= 1 && (farthest === null || t > farthest)) farthest = t;
    }
  }
  const best = farthest ?? nearest;
  return best === null ? null : { x: c.x + d.x * best, y: c.y + d.y * best };
}

/** Where the line from the shape's center toward `target` crosses its outline. */
export function edgePoint(shape: Element, toward: Point): Point {
  const r = frame(shape);
  const c = center(shape);
  const target = unrotated(shape, toward);
  const dx = target.x - c.x, dy = target.y - c.y;
  if (!((dx !== 0 || dy !== 0) && r.width > 0 && r.height > 0)) return c;
  if (shape.kind === "path") {
    const hit = outlineCrossing(shape, c, { x: dx, y: dy });
    if (hit) return rotated(shape, hit);
  }
  const hw = r.width / 2, hh = r.height / 2;
  let t: number;
  if (shape.kind === "ellipse") t = 1 / Math.sqrt((dx * dx) / (hw * hw) + (dy * dy) / (hh * hh));
  else if (shape.kind === "diamond") t = 1 / (Math.abs(dx) / hw + Math.abs(dy) / hh);
  else t = Math.min(dx !== 0 ? hw / Math.abs(dx) : Infinity, dy !== 0 ? hh / Math.abs(dy) : Infinity);
  return rotated(shape, { x: c.x + dx * t, y: c.y + dy * t });
}

function reference(ep: Endpoint, index: Index): Point {
  const s = ep.elementID ? index.get(ep.elementID) : undefined;
  return s ? center(s) : { x: ep.x, y: ep.y };
}

/** A point given in the element's normalized `ports`, rotated with it. */
function normalizedPoint(shape: Element, p: { x: number; y: number }): Point {
  const r = frame(shape);
  return rotated(shape, { x: r.x + p.x * r.width, y: r.y + p.y * r.height });
}

function resolve(ep: Endpoint, other: Point, index: Index): Point {
  const s = ep.elementID ? index.get(ep.elementID) : undefined;
  if (!s) return { x: ep.x, y: ep.y };
  const i = ep.portIndex, ports = s.ports ?? [];
  if (typeof i === "number" && Number.isInteger(i) && i >= 0 && i < ports.length) return normalizedPoint(s, ports[i]);
  return ep.port ? portPoint(s, ep.port) : edgePoint(s, other);
}

export function endpoints(e: Element, index: Index): [Point, Point] {
  const c = e.connector;
  if (!c) return [{ x: 0, y: 0 }, { x: 0, y: 0 }];
  return [resolve(c.start, reference(c.end, index), index), resolve(c.end, reference(c.start, index), index)];
}

export type Route = { kind: "polyline"; points: Point[] } | { kind: "cubic"; a: Point; b: Point; c: Point; d: Point };

/** A route's centerline as points; a cubic is sampled at 25 points. */
export function routePoints(r: Route): Point[] {
  if (r.kind === "polyline") return r.points;
  const out: Point[] = [];
  for (let i = 0; i <= 24; i++) {
    const t = i / 24, u = 1 - t;
    out.push({
      x: u * u * u * r.a.x + 3 * u * u * t * r.b.x + 3 * u * t * t * r.c.x + t * t * t * r.d.x,
      y: u * u * u * r.a.y + 3 * u * u * t * r.b.y + 3 * u * t * t * r.c.y + t * t * t * r.d.y,
    });
  }
  return out;
}

export function route(e: Element, index: Index): Route {
  const c = e.connector;
  if (!c) return { kind: "polyline", points: [] };
  const [a, b] = endpoints(e, index);
  const dx = b.x - a.x, dy = b.y - a.y;
  const horizontal = Math.abs(dx) >= Math.abs(dy);
  switch (c.routing) {
    case "straight":
      return { kind: "polyline", points: [a, b] };
    case "curved":
      if (horizontal) return { kind: "cubic", a, b: { x: a.x + dx / 2, y: a.y }, c: { x: b.x - dx / 2, y: b.y }, d: b };
      return { kind: "cubic", a, b: { x: a.x, y: a.y + dy / 2 }, c: { x: b.x, y: b.y - dy / 2 }, d: b };
    case "elbow": {
      const vertical = (p: Port | null): boolean | null => (p === null ? null : p === "top" || p === "bottom");
      const startV = vertical(c.start.port) ?? !horizontal;
      const endV = vertical(c.end.port) ?? !horizontal;
      if (startV && endV) {
        const my = a.y + dy / 2;
        return { kind: "polyline", points: [a, { x: a.x, y: my }, { x: b.x, y: my }, b] };
      }
      if (!startV && !endV) {
        const mx = a.x + dx / 2;
        return { kind: "polyline", points: [a, { x: mx, y: a.y }, { x: mx, y: b.y }, b] };
      }
      if (startV) return { kind: "polyline", points: [a, { x: a.x, y: b.y }, b] };
      return { kind: "polyline", points: [a, { x: b.x, y: a.y }, b] };
    }
  }
}

/** Arrowhead wing points for a tip at `tip` arriving from `from`. */
export function arrowhead(tip: Point, from: Point, size: number): [Point, Point] {
  const a = Math.atan2(tip.y - from.y, tip.x - from.x);
  const spread = Math.PI / 7;
  const wing = (s: number): Point => ({ x: tip.x - size * Math.cos(a + s), y: tip.y - size * Math.sin(a + s) });
  return [wing(spread), wing(-spread)];
}

export function connectorBounds(e: Element, index: Index): Rect {
  const pts = routePoints(route(e, index));
  if (pts.length === 0) return { x: 0, y: 0, width: 0, height: 0 };
  let x0 = pts[0].x, y0 = pts[0].y, x1 = x0, y1 = y0;
  for (const p of pts) { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x); y1 = Math.max(y1, p.y); }
  return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
}

/** Point halfway along the route, where a label sits. */
export function midpoint(e: Element, index: Index): Point {
  const pts = routePoints(route(e, index));
  if (pts.length <= 1) return pts[0] ?? { x: 0, y: 0 };
  const lengths: number[] = [];
  let total = 0;
  for (let i = 0; i < pts.length - 1; i++) {
    const l = Math.hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y);
    lengths.push(l); total += l;
  }
  let remaining = total / 2;
  for (let i = 0; i < lengths.length; i++) {
    const l = lengths[i];
    if (remaining <= l || i === lengths.length - 1) {
      const t = l === 0 ? 0 : remaining / l;
      return { x: pts[i].x + (pts[i + 1].x - pts[i].x) * t, y: pts[i].y + (pts[i + 1].y - pts[i].y) * t };
    }
    remaining -= l;
  }
  return pts[0];
}

export function indexOf(page: Page): Index {
  const m: Index = new Map();
  for (const e of page.elements) if (!m.has(e.id)) m.set(e.id, e);
  return m;
}

export { angle };
