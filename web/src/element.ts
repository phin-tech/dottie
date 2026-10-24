// Element geometry: frames, rotation, a path element's contours, and automatic ink (Model.swift, PathShape.swift).

import { type Element, type RGBA, black, cloneElement, isAutomaticInk, luminance } from "./model.ts";
import { Path, type Point, type Rect, maxX, maxY, midX, midY, rotate } from "./path.ts";

export const frame = (e: Element): Rect => ({ x: e.x, y: e.y, width: e.width, height: e.height });
export const angle = (e: Element): number => e.rotation ?? 0;
export const center = (e: Element): Point => ({ x: e.x + e.width / 2, y: e.y + e.height / 2 });

/** A point in the element's own (unrotated) frame, on the canvas. */
export const rotated = (e: Element, p: Point): Point => rotate(p, center(e), angle(e));
/** A canvas point in the element's own (unrotated) frame. */
export const unrotated = (e: Element, p: Point): Point => rotate(p, center(e), -angle(e));

/** Bounding box of the frame after rotation. */
export function rotatedBounds(e: Element): Rect {
  const r = frame(e);
  if (angle(e) === 0) return r;
  const corners = [
    { x: r.x, y: r.y }, { x: maxX(r), y: r.y }, { x: maxX(r), y: maxY(r) }, { x: r.x, y: maxY(r) },
  ].map((p) => rotated(e, p));
  const xs = corners.map((p) => p.x), ys = corners.map((p) => p.y);
  const x = Math.min(...xs), y = Math.min(...ys);
  return { x, y, width: Math.max(...xs) - x, height: Math.max(...ys) - y };
}

/** The element with automatic ink drawn as `ink`; a light ink is not used on a light, mostly opaque fill. */
export function resolvingInk(e: Element, ink: RGBA): Element {
  const text = e.style.textColor !== null && isAutomaticInk(e.style.textColor);
  if (!isAutomaticInk(e.style.stroke) && !text) return e;
  const copy = cloneElement(e);
  const covers = e.style.fillStyle === "solid" || e.style.fillStyle === "grid";
  const onLightFill = covers && e.style.fill.a >= 0.5 && luminance(e.style.fill) > 0.5;
  const resolved = luminance(ink) > 0.5 && onLightFill ? black : ink;
  if (isAutomaticInk(e.style.stroke)) copy.style.stroke = { ...resolved };
  if (text) copy.style.textColor = { ...resolved };
  return copy;
}

/** What the element's text is drawn in: a text box's and a note's stroke, any other label's `textColor` or,
 * without one, its stroke. */
export function labelColor(e: Element): RGBA {
  return e.kind === "text" || e.kind === "note" ? e.style.stroke : e.style.textColor ?? e.style.stroke;
}

export interface Contour { closed: boolean; points: Point[] }

/** A `.path` element's contours in canvas coordinates: `1 + 3n` Bézier points each. */
export function shapeContours(e: Element): Contour[] {
  if (e.kind !== "path" || !e.subpaths) return [];
  const out: Contour[] = [];
  for (const s of e.subpaths) {
    if (s.coords.length < 8 || (s.coords.length - 2) % 6 !== 0) continue;
    const pts: Point[] = [];
    for (let i = 0; i < s.coords.length; i += 2) pts.push({ x: e.x + s.coords[i] * e.width, y: e.y + s.coords[i + 1] * e.height });
    out.push({ closed: s.closed, points: pts });
  }
  return out;
}

/** The exact (not sketchy) geometry of a `.path`. */
export function shapePath(e: Element): Path {
  const path = new Path();
  for (const c of shapeContours(e)) {
    path.moveTo(c.points[0]);
    for (let k = 0; k < (c.points.length - 1) / 3; k++) {
      path.curveTo(c.points[3 * k + 3], c.points[3 * k + 1], c.points[3 * k + 2]);
    }
    if (c.closed) path.close();
  }
  return path;
}

export { midX, midY };
