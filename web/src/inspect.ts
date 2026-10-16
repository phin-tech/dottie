// The geometry contract (Inspect.swift): what a page resolves to at a moment, in the structure `dottie inspect`
// prints. The contract tests compare this with the goldens Dottie wrote.

import { endpoints, indexOf, route, routePoints } from "./connector.ts";
import { type DottieFile, type Page, type RGBA, orderedElements } from "./model.ts";
import { type Point, type Rect, roundHalfAway } from "./path.ts";
import { bounds, plan } from "./svg.ts";
import { cameraView, resolved } from "./timeline.ts";

const r4 = (v: number): number => { const r = roundHalfAway(v * 10_000) / 10_000; return r === 0 ? 0 : r; };
const pt = (p: Point): number[] => [r4(p.x), r4(p.y)];
const rect = (r: Rect): number[] => [r4(r.x), r4(r.y), r4(r.width), r4(r.height)];
const rgba = (c: RGBA): number[] => [r4(c.r), r4(c.g), r4(c.b), r4(c.a)];

/** Times worth checking on an animated page (Inspector.sampleTimes). */
export function sampleTimes(page: Page): number[] {
  const tl = page.timeline;
  if (!tl) return [0];
  const d = tl.duration;
  const times = [0, d];
  for (let i = 1; i < 16; i++) times.push((d * (i + 0.37)) / 16);
  for (const m of tl.markers ?? []) times.push(m.t);
  if (tl.poster !== null) times.push(tl.poster);
  return [...new Set(times.map(r4))].filter((t) => t >= 0 && t <= d).sort((a, b) => a - b);
}

export function inspectFrame(page: Page, t: number): Record<string, unknown> {
  const f = resolved(page, t);
  const index = indexOf(f);
  const visible = new Set(f.layers.filter((l) => l.visible).map((l) => l.id));
  const out: Record<string, unknown> = { t: r4(t) };
  const tl = page.timeline;
  if (tl) {
    const v = cameraView(tl, t);
    out.view = v ? rect(v) : null;
    let scene = -1;
    (tl.markers ?? []).forEach((m, i) => { if (m.t <= t) scene = i; });
    out.scene = scene;
  }
  if (!(tl?.camera?.length)) out.bounds = rect(bounds(f));
  out.elements = orderedElements(f).map((e, z) => {
    const d: Record<string, unknown> = { id: e.id, kind: e.kind, z, seed: e.seed, frame: rect({ x: e.x, y: e.y, width: e.width, height: e.height }) };
    if (!visible.has(e.layerID)) d.hiddenLayer = true;
    if (e.rotation !== null) d.rotation = r4(e.rotation);
    if (e.style.opacity !== null) d.opacity = r4(e.style.opacity);
    if (e.reveal !== null) d.reveal = r4(e.reveal);
    d.strokeWidth = r4(e.style.strokeWidth);
    d.stroke = rgba(e.style.stroke);
    d.fill = rgba(e.style.fill);
    if (e.kind === "connector") {
      const [a, b] = endpoints(e, index);
      d.start = pt(a);
      d.end = pt(b);
      d.route = routePoints(route(e, index)).map(pt);
    }
    return d;
  });
  return out;
}

export function inspectPage(page: Page, n: number, times: number[]): Record<string, unknown> {
  const out: Record<string, unknown> = { page: n + 1, name: page.name, id: page.id };
  const tl = page.timeline;
  if (tl) {
    const p = plan(page);
    out.duration = r4(tl.duration);
    out.fps = r4(tl.fps);
    out.frameCount = p.times.length;
    out.poster = r4(tl.poster ?? tl.duration);
    out.size = [r4(p.size.width), r4(p.size.height)];
    if (!(tl.camera?.length)) out.bounds = rect(p.rects[0]);
    out.markers = (tl.markers ?? []).map((m) => ({ t: r4(m.t), name: m.name }));
  } else {
    out.bounds = rect(bounds(page));
  }
  out.frames = times.map((t) => inspectFrame(page, t));
  return out;
}

/** A whole file: every page at its sample times (or `times`). */
export function inspect(file: DottieFile, times?: number[]): Record<string, unknown> {
  return { version: file.version, pages: file.pages.map((p, i) => inspectPage(p, i, times ?? sampleTimes(p))) };
}
