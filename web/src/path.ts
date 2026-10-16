// A small stand-in for CGPath: the segments DottieKit builds, flattened and trimmed the way it does, and written
// out as SVG path data with Dottie's number formatting.

export interface Point { x: number; y: number }
export interface Rect { x: number; y: number; width: number; height: number }

export type Segment =
  | { op: "M"; p: Point }
  | { op: "L"; p: Point }
  | { op: "Q"; c: Point; p: Point }
  | { op: "C"; c1: Point; c2: Point; p: Point }
  | { op: "Z" };

/** CoreGraphics' ellipse control-point factor. */
const KAPPA = 0.5522847498307936;

export class Path {
  segments: Segment[] = [];

  get isEmpty(): boolean { return this.segments.length === 0; }

  moveTo(p: Point): this { this.segments.push({ op: "M", p }); return this; }
  lineTo(p: Point): this { this.segments.push({ op: "L", p }); return this; }
  quadTo(p: Point, c: Point): this { this.segments.push({ op: "Q", c, p }); return this; }
  curveTo(p: Point, c1: Point, c2: Point): this { this.segments.push({ op: "C", c1, c2, p }); return this; }
  close(): this { this.segments.push({ op: "Z" }); return this; }
  addPath(other: Path): this { this.segments.push(...other.segments); return this; }

  /** move, then a line to each point (CGMutablePath.addLines). */
  addLines(pts: Point[]): this {
    pts.forEach((p, i) => (i === 0 ? this.moveTo(p) : this.lineTo(p)));
    return this;
  }

  /** CGPath(rect:): clockwise (on screen) from the top-left corner. */
  static rect(r: Rect): Path {
    return new Path().addLines([
      { x: r.x, y: r.y }, { x: r.x + r.width, y: r.y }, { x: r.x + r.width, y: r.y + r.height }, { x: r.x, y: r.y + r.height },
    ]).close();
  }

  /** CGPath(ellipseIn:): four cubics clockwise (on screen) from the right-hand point. */
  addEllipse(r: Rect): this {
    const cx = r.x + r.width / 2, cy = r.y + r.height / 2, rx = r.width / 2, ry = r.height / 2;
    const kx = rx * KAPPA, ky = ry * KAPPA;
    this.moveTo({ x: cx + rx, y: cy });
    this.curveTo({ x: cx, y: cy + ry }, { x: cx + rx, y: cy + ky }, { x: cx + kx, y: cy + ry });
    this.curveTo({ x: cx - rx, y: cy }, { x: cx - kx, y: cy + ry }, { x: cx - rx, y: cy + ky });
    this.curveTo({ x: cx, y: cy - ry }, { x: cx - rx, y: cy - ky }, { x: cx - kx, y: cy - ry });
    this.curveTo({ x: cx + rx, y: cy }, { x: cx + kx, y: cy - ry }, { x: cx + rx, y: cy - ky });
    return this.close();
  }

  static ellipse(r: Rect): Path { return new Path().addEllipse(r); }

  translated(dx: number, dy: number): Path {
    const t = (p: Point): Point => ({ x: p.x + dx, y: p.y + dy });
    const out = new Path();
    out.segments = this.segments.map((s): Segment => {
      switch (s.op) {
        case "M": case "L": return { op: s.op, p: t(s.p) };
        case "Q": return { op: "Q", c: t(s.c), p: t(s.p) };
        case "C": return { op: "C", c1: t(s.c1), c2: t(s.c2), p: t(s.p) };
        case "Z": return s;
      }
    });
    return out;
  }

  /** Every contour as points, curves flattened into short segments (CGPath.contours). */
  contours(): Point[][] {
    const out: Point[][] = [];
    let current: Point[] = [];
    let start: Point = { x: 0, y: 0 };
    for (const s of this.segments) {
      const last = current.length ? current[current.length - 1] : start;
      switch (s.op) {
        case "M":
          if (current.length > 1) out.push(current);
          start = s.p; current = [s.p];
          break;
        case "L": current.push(s.p); break;
        case "Q":
          for (let i = 1; i <= 12; i++) {
            const t = i / 12, u = 1 - t;
            current.push({ x: u * u * last.x + 2 * u * t * s.c.x + t * t * s.p.x, y: u * u * last.y + 2 * u * t * s.c.y + t * t * s.p.y });
          }
          break;
        case "C":
          for (let i = 1; i <= 16; i++) {
            const t = i / 16, u = 1 - t;
            current.push({
              x: u * u * u * last.x + 3 * u * u * t * s.c1.x + 3 * u * t * t * s.c2.x + t * t * t * s.p.x,
              y: u * u * u * last.y + 3 * u * u * t * s.c1.y + 3 * u * t * t * s.c2.y + t * t * t * s.p.y,
            });
          }
          break;
        case "Z":
          current.push(start);
          if (current.length > 1) out.push(current);
          current = [start];
          break;
      }
    }
    if (current.length > 1) out.push(current);
    return out;
  }

  /** The first `fraction` of the path by length, contours in drawing order: a stroke being drawn on. */
  trimmed(fraction: number): Path {
    const lines = this.contours().map((c) => new Polyline(c));
    let left = Math.min(Math.max(fraction, 0), 1) * lines.reduce((s, l) => s + l.length, 0);
    const out = new Path();
    for (const line of lines) {
      if (!(left > 0)) break;
      out.moveTo(line.points[0]);
      for (let i = 1; i < line.points.length; i++) {
        const seg = line.lengths[i] - line.lengths[i - 1];
        if (seg <= left) { out.lineTo(line.points[i]); left -= seg; continue; }
        const a = line.points[i - 1], b = line.points[i], f = left / seg;
        out.lineTo({ x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f });
        left = 0;
        break;
      }
    }
    return out;
  }

  /** SVG path data, as Dottie's SVG export writes it. */
  data(): string {
    const d: string[] = [];
    for (const s of this.segments) {
      switch (s.op) {
        case "M": d.push(`M${fmt(s.p.x)} ${fmt(s.p.y)}`); break;
        case "L": d.push(`L${fmt(s.p.x)} ${fmt(s.p.y)}`); break;
        case "Q": d.push(`Q${fmt(s.c.x)} ${fmt(s.c.y)} ${fmt(s.p.x)} ${fmt(s.p.y)}`); break;
        case "C": d.push(`C${fmt(s.c1.x)} ${fmt(s.c1.y)} ${fmt(s.c2.x)} ${fmt(s.c2.y)} ${fmt(s.p.x)} ${fmt(s.p.y)}`); break;
        case "Z": d.push("Z"); break;
      }
    }
    return d.join(" ");
  }
}

/** Swift's `.rounded()`: half away from zero. */
export function roundHalfAway(v: number): number {
  return v < 0 ? -Math.round(-v) : Math.round(v);
}

/** Dottie's SVG number: two decimals, integers without a point. */
export function fmt(v: number): string {
  const r = roundHalfAway(v * 100) / 100;
  if (Number.isInteger(r)) return String(r === 0 ? 0 : r);
  return String(r);
}

/** Points along a path with their running length (Motion.swift's Polyline). */
export class Polyline {
  points: Point[];
  lengths: number[];
  constructor(points: Point[]) {
    this.points = points;
    let run = 0;
    this.lengths = points.map((p, i) => {
      if (i > 0) run += Math.hypot(p.x - points[i - 1].x, p.y - points[i - 1].y);
      return run;
    });
  }
  get length(): number { return this.lengths.length ? this.lengths[this.lengths.length - 1] : 0; }

  /** The point `u` (0...1) of the way along, by distance. */
  point(u: number): Point {
    if (this.points.length <= 1 || !(this.length > 0)) return this.points[0] ?? { x: 0, y: 0 };
    const d = Math.min(Math.max(u, 0), 1) * this.length;
    let i = 1;
    while (i < this.lengths.length - 1 && this.lengths[i] < d) i++;
    const seg = this.lengths[i] - this.lengths[i - 1];
    const f = seg > 0 ? (d - this.lengths[i - 1]) / seg : 0;
    const a = this.points[i - 1], b = this.points[i];
    return { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f };
  }
}

// MARK: Rects

export const midX = (r: Rect): number => r.x + r.width / 2;
export const midY = (r: Rect): number => r.y + r.height / 2;
export const maxX = (r: Rect): number => r.x + r.width;
export const maxY = (r: Rect): number => r.y + r.height;

export function union(a: Rect | null, b: Rect): Rect {
  if (!a) return { ...b };
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  return { x, y, width: Math.max(maxX(a), maxX(b)) - x, height: Math.max(maxY(a), maxY(b)) - y };
}

export function inset(r: Rect, dx: number, dy: number): Rect {
  return { x: r.x + dx, y: r.y + dy, width: r.width - 2 * dx, height: r.height - 2 * dy };
}

export function rotate(p: Point, c: Point, a: number): Point {
  if (a === 0) return p;
  const dx = p.x - c.x, dy = p.y - c.y;
  return { x: c.x + dx * Math.cos(a) - dy * Math.sin(a), y: c.y + dx * Math.sin(a) + dy * Math.cos(a) };
}

/** A point on a cubic Bézier (StrokeFit.point). */
export function bezierPoint(b: Point[], t: number): Point {
  const s = 1 - t;
  return {
    x: b[0].x * (s * s * s) + b[1].x * (3 * t * s * s) + b[2].x * (3 * t * t * s) + b[3].x * (t * t * t),
    y: b[0].y * (s * s * s) + b[1].y * (3 * t * s * s) + b[2].y * (3 * t * t * s) + b[3].y * (t * t * t),
  };
}

/** A cubic Bézier chain (1 + 3n points) as a polyline of short steps (Element.flatten). */
export function flatten(cp: Point[], maxStep: number): Point[] {
  const out: Point[] = [cp[0]];
  for (let s = 0; s < Math.floor((cp.length - 1) / 3); s++) {
    const seg = cp.slice(3 * s, 3 * s + 4);
    let hull = 0;
    for (let i = 1; i < seg.length; i++) hull += Math.hypot(seg[i].x - seg[i - 1].x, seg[i].y - seg[i - 1].y);
    const n = Math.min(400, Math.max(4, Math.ceil(hull / Math.max(maxStep, 0.5))));
    for (let k = 1; k <= n; k++) out.push(bezierPoint(seg, k / n));
  }
  return out;
}
