// A starting point for a Dottie extension. Build it with ./build.sh, which writes main.js beside manifest.json.
/// <reference path="../dottie-extension.d.ts" />

interface BoxParams {
  inset: number;
  round: boolean;
}

// A square whose corners are pulled in by `inset` (a fraction of its size). Its lower-right corner is a handle.
extension.shape<BoxParams>({
  id: "box",
  name: "Inset box",
  parameters: {
    inset: { type: "number", label: "Inset", min: 0, max: 0.5, default: 0.1 },
    round: { type: "boolean", label: "Round", default: false },
  },
  generate(p) {
    const i = p.inset;
    // A straight edge is a cubic whose control points sit a third and two thirds along it.
    const corners: [number, number][] = [[i, i], [1 - i, i], [1 - i, 1 - i], [i, 1 - i]];
    const coords: number[] = [corners[0][0], corners[0][1]];
    corners.forEach((a, k) => {
      const b = corners[(k + 1) % corners.length];
      coords.push(
        a[0] + (b[0] - a[0]) / 3, a[1] + (b[1] - a[1]) / 3,
        a[0] + (2 * (b[0] - a[0])) / 3, a[1] + (2 * (b[1] - a[1])) / 3,
        b[0], b[1],
      );
    });
    return {
      subpaths: [{ closed: true, coords }],
      ports: [{ x: 0.5, y: 0 }, { x: 0.5, y: 1 }],
      labelRect: { x: i, y: i, width: 1 - 2 * i, height: 1 - 2 * i },
    };
  },
  handles: [
    {
      id: "corner",
      position: (p, f) => ({ x: p.inset * f.width, y: p.inset * f.height }),
      drag: (p, f, pt) => ({ ...p, inset: Math.min(0.5, Math.max(0, pt.x / f.width)) }),
    },
  ],
});

// A command that draws a row of boxes on the selected page. It runs with the `dottie` object.
extension.command<{ count: number; gap: number }>({
  id: "row",
  name: "Row of boxes",
  category: "Layout",
  parameters: {
    count: { type: "integer", label: "Boxes", min: 1, max: 20, default: 3 },
    gap: { type: "number", label: "Gap", min: 0, max: 200, default: 20 },
  },
  run(p) {
    for (let k = 0; k < p.count; k++) {
      dottie.shape({ extension: { id: "com.example.template", shape: "box" }, params: { inset: 0.1 }, x: k * (100 + p.gap), y: 0, width: 100, height: 100 });
    }
    return p.count;
  },
});

// A drawing tool: a calligraphy pen. Dragging draws a ribbon whose width follows the stroke's direction against a
// slanted nib, tapered at both ends. It draws one filled path, a plain element, so the drawing opens and renders
// without this extension.
const NIB = 14; // the ribbon at its widest, in points
const SLANT = -Math.PI / 4; // the nib's angle: strokes along it are thinnest
const TAPER = 24; // how far from each end the ribbon reaches full width, in points
const INK = "#2f4fd8"; // fountain-pen blue, which reads on a light canvas and a dark one

extension.tool({
  id: "ribbon",
  name: "Ribbon",
  icon: "scribble.variable",
  draw(g) {
    const look = { fill: INK, stroke: "none", fillStyle: "solid", roughness: 0 } as const;
    const pts = thinned(g.points, 3);
    if (pts.length < 2) { // a click leaves a dot of ink
      const p = pts[0], r = NIB / 4;
      return { elements: [{ kind: "ellipse", x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r, ...look }] };
    }
    // How far along the stroke each point is, for the taper.
    const along = [0];
    for (let i = 1; i < pts.length; i++) along.push(along[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
    const total = along[along.length - 1];
    const left: Point[] = [], right: Point[] = [];
    pts.forEach((p, i) => {
      const a = pts[Math.max(0, i - 1)], b = pts[Math.min(pts.length - 1, i + 1)];
      const len = Math.hypot(b.x - a.x, b.y - a.y) || 1;
      const dx = (b.x - a.x) / len, dy = (b.y - a.y) / len;
      const across = Math.abs(Math.sin(Math.atan2(dy, dx) - SLANT));
      const taper = Math.min(1, along[i] / TAPER, (total - along[i]) / TAPER);
      const half = (NIB / 2) * (0.15 + 0.85 * across) * (0.2 + 0.8 * taper);
      left.push({ x: p.x - dy * half, y: p.y + dx * half });
      right.push({ x: p.x + dy * half, y: p.y - dx * half });
    });
    return { elements: [{ kind: "path", subpaths: [{ closed: true, coords: smoothLoop(left.concat(right.reverse())) }], ...look }] };
  },
});

/** The points with any closer than `gap` to the last one kept dropped, so a slow drag doesn't wrinkle the ribbon.
 * The last point always stays, so the ribbon ends under the pointer. */
function thinned(points: Point[], gap: number): Point[] {
  const out: Point[] = [points[0]];
  for (const p of points.slice(1)) {
    const q = out[out.length - 1];
    if (Math.hypot(p.x - q.x, p.y - q.y) >= gap) out.push(p);
  }
  const last = points[points.length - 1];
  if (out.length > 1 && out[out.length - 1] !== last) out[out.length - 1] = last;
  return out;
}

/** A closed loop through `pts` as Bézier coordinates (Catmull-Rom), the form a subpath takes. */
function smoothLoop(pts: Point[]): number[] {
  const n = pts.length, at = (i: number) => pts[(i + n) % n];
  const coords = [pts[0].x, pts[0].y];
  for (let i = 0; i < n; i++) {
    const p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
    coords.push(p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6, p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6, p2.x, p2.y);
  }
  return coords;
}
