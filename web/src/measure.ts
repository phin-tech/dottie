// Capacity, metrics and gauges (Metrics.swift, ADR 0003; font metrics are metrics.ts). Each frame, the page's flows are assigned to routes in
// page order, as much as each route has room for; the packets drawn and the metrics shown both come from that
// assignment, so a frame stays a pure function of the page, the time and the variables.

import type { Element, Flow, Gauge, Page, PathSubpath, RGBA, Style } from "./model.ts";
import { clamp, DEFAULT_COLOR, DEFAULT_EVERY, DEFAULT_SIZE, DEFAULT_SPEED, flowTree, packetID, type FlowTree } from "./flows.ts";
import { Polyline, type Point } from "./path.ts";
import { applyOverride, holds, looksOnly, mentionsMetric, type MetricTerm } from "./state.ts";
import { tracing } from "./timeline.ts";

/** A connector's or shape's metrics in one frame (ElementMetrics). */
export interface ElementMetrics { throughput: number; load: number | null; delay: number; backlog: number; inFlight: number; depth: number }
/** A flow's metrics in one frame (FlowMetrics). */
export interface FlowMetrics { volume: number; placed: number; backlog: number; backup: number; transit: number | null }
/** Every metric of one frame (FrameMetrics). */
export interface FrameMetrics { elements: Map<string, ElementMetrics>; flows: Map<string, FlowMetrics> }

export const emptyMetrics = (): FrameMetrics => ({ elements: new Map(), flows: new Map() });

/** `metric` of the element or flow `id`, or null when it has none. */
export function metricValue(m: FrameMetrics, metric: string, id: string): number | null {
  const f = m.flows.get(id);
  if (f) {
    switch (metric) {
      case "throughput": return f.placed;
      case "backlog": return f.backlog;
      case "backup": return f.backup;
      case "transit": return f.transit;
      default: return null;
    }
  }
  const e = m.elements.get(id);
  if (!e) return null;
  switch (metric) {
    case "throughput": return e.throughput;
    case "load": return e.load;
    case "delay": return e.delay;
    case "backlog": return e.backlog;
    case "inFlight": return e.inFlight;
    case "depth": return e.depth;
    default: return null;
  }
}

const TINY = 1e-9;

const amount = (f: Flow): number => clamp(f.volume, 1, 0, 1e12);

/** A shape's delay as traffic feels it: 0...3600 seconds. */
export function delayOf(e: Element): number {
  const d = e.delay ?? null;
  if (e.kind === "connector" || d === null || !Number.isFinite(d)) return 0;
  return Math.min(Math.max(d, 0), 3600);
}

interface Placement { hops: [string, boolean][]; shapes: string[]; goal: string; amount: number }

/** The packets the page's flows draw in `frame` (the page posed at `t`), with these values (null: every flow runs),
 * and the frame's metrics (DottieDocument.flowFrame). `since` is the seconds since the page's state last changed
 * (null: `t`), which backlog has been piling up for. */
export function flowFrame(flows: Flow[] | null, frame: Page, t: number, values: Record<string, boolean> | null,
  offline: Set<string> = new Set(), sinceChange: number | null = null): { packets: Element[]; metrics: FrameMetrics } {
  const since = Math.max(0, Math.min(sinceChange ?? t, 1e6));
  const byID = new Map<string, Element>();
  for (const e of frame.elements) if (!byID.has(e.id)) byID.set(e.id, e);
  const metrics = emptyMetrics();
  for (const e of frame.elements) {
    if (e.kind === "connector" && !e.connector) continue;
    metrics.elements.set(e.id, { throughput: 0, load: null, delay: e.kind !== "connector" ? delayOf(e) : 0, backlog: 0, inFlight: 0, depth: 0 });
  }
  const list = flows ?? [];
  // Room left on everything with a capacity.
  const room = new Map<string, number>();
  for (const e of frame.elements) {
    const c = e.capacity ?? null;
    if (c !== null && Number.isFinite(c)) room.set(e.id, Math.max(c, 0));
  }
  const full = (): Set<string> => new Set([...room].filter(([, v]) => v <= TINY).map(([id]) => id));
  const route = (tree: FlowTree, goal: string): { hops: [string, boolean][]; shapes: string[] } => {
    const hops: [string, boolean][] = [], shapes: string[] = [];
    let at = goal;
    for (let step = tree.came.get(at); step; step = tree.came.get(at)) { hops.push([step.via, step.back]); shapes.push(at); at = step.from; }
    shapes.push(at);
    return { hops: hops.reverse(), shapes: shapes.reverse() };
  };
  const union = (a: Set<string>, b: Set<string>) => new Set([...a, ...b]);
  const bump = (id: string, f: (m: ElementMetrics) => void) => { const m = metrics.elements.get(id); if (m) f(m); };

  // Flows leaving the same shape take turns; the page's biggest flow draws a packet every `every` seconds.
  const leaving = new Map<string, number>(), turn: number[] = [];
  for (const flow of list) { const n = leaving.get(flow.from) ?? 0; turn.push(n); leaving.set(flow.from, n + 1); }
  const biggest = list.length > 0 ? Math.max(...list.map(amount)) : 1;
  const packets: Element[] = [];
  const piles = new Map<string, number>();

  for (const [i, flow] of list.entries()) {
    if (flow.when !== null && values !== null && !holds(flow.when, values)) continue;
    const source = byID.get(flow.from);
    const base = source ? flowTree(flow.from, frame, offline) : null;
    if (!source || !base) continue;
    const volume = amount(flow);
    const fm: FlowMetrics = { volume, placed: 0, backlog: 0, backup: 0, transit: null };
    const placements: Placement[] = [];
    const waiting: [string, number][] = [];
    // Spread: while the first destination is down, the volume is shared equally by the rest.
    const goals = base.goals(flow.to, flow.spread === true);
    const shares: [string[], number][] = goals.length > 1 ? goals.map((g) => [[g], volume / goals.length]) : [[flow.to, volume]];
    for (const [candidates, share] of shares) {
      if (!(share > TINY)) continue;
      let left = share;
      for (let n = 0; n < 32 && left > TINY; n++) {
        const tree = flowTree(flow.from, frame, union(offline, full()));
        const goal = tree?.goals(candidates, false)[0];
        if (!tree || goal === undefined) break;
        const r = route(tree, goal);
        const ids = [...r.shapes, ...r.hops.map(([id]) => id)];
        const rooms = ids.filter((id) => room.has(id)).map((id) => room.get(id)!);
        const fits = Math.min(left, rooms.length > 0 ? Math.min(...rooms) : Infinity);
        if (!(fits > TINY)) break;
        for (const id of ids) if (room.has(id)) room.set(id, room.get(id)! - fits);
        placements.push({ hops: r.hops, shapes: r.shapes, goal, amount: fits });
        left -= fits;
      }
      if (!(left > TINY)) continue;
      // What doesn't fit waits in front of the first full thing on its cheapest way (ignoring capacity).
      let at = flow.from;
      const goal = base.goals(candidates, false)[0];
      if (goal !== undefined) {
        const r = route(base, goal), done = full();
        const sequence: [string, string][] = [[r.shapes[0], r.shapes[0]]];
        r.hops.forEach(([id], k) => { sequence.push([id, r.shapes[k]], [r.shapes[k + 1], r.shapes[k]]); });
        const first = sequence.find(([id]) => done.has(id));
        if (first) at = first[1];
      }
      waiting.push([at, left]);
    }

    // Metrics.
    for (const p of placements) {
      for (const id of [...p.shapes, ...p.hops.map(([h]) => h)]) bump(id, (m) => { m.throughput += p.amount; });
      fm.placed += p.amount;
    }
    for (const [at, a] of waiting) { bump(at, (m) => { m.backlog += a; }); fm.backlog += a; }
    const reachedFirst = placements.filter((p) => p.goal === flow.to[0]).reduce((s, p) => s + p.amount, 0);
    fm.backup = volume > TINY ? Math.max(0, (volume - reachedFirst) / volume) : 0;

    // Packets: dealt across the placements by their share of the volume.
    const every = Math.min(Math.max(clamp(flow.every, DEFAULT_EVERY, 0.05, 60) * biggest / Math.max(volume, TINY), 0.05), 60);
    const speed = clamp(flow.speed, DEFAULT_SPEED, 1, 10000), size = clamp(flow.size, DEFAULT_SIZE, 2, 200);
    const phase = (turn[i] / leaving.get(flow.from)!) * every;
    const color = flow.color ?? DEFAULT_COLOR;
    const cumulative: number[] = [];
    let sum = 0;
    for (const p of placements) { sum += p.amount / Math.max(volume, TINY); cumulative.push(sum); }
    if (cumulative.length > 0 && Math.abs(cumulative[cumulative.length - 1] - 1) < 1e-9) cumulative[cumulative.length - 1] = 1;
    let transitSum = 0;
    placements.forEach((p, r) => {
      // The route, the stretches inside the shapes it passes (with their delays), and each hop's stretch.
      const points: Point[] = [], inside: [number, number, number][] = [], stretches: [string, number, number][] = [];
      let length = 0;
      p.hops.forEach(([id, back], k) => {
        const c = byID.get(id);
        if (!c) return;
        const line = back ? [...tracing(c, frame).points].reverse() : tracing(c, frame).points;
        if (line.length === 0) return;
        const last = points[points.length - 1];
        if (last) {
          const gap = Math.hypot(line[0].x - last.x, line[0].y - last.y);
          const shape = byID.get(p.shapes[k]);
          inside.push([length, length + gap, shape ? delayOf(shape) : 0]);
          length += gap;
        }
        const start = length;
        for (let q = 1; q < line.length; q++) length += Math.hypot(line[q].x - line[q - 1].x, line[q].y - line[q - 1].y);
        stretches.push([id, start, length]);
        points.push(...line);
      });
      if (!(length > 0)) return;
      const travel = length / speed + inside.reduce((s, x) => s + x[2], 0);
      transitSum += travel * p.amount;
      const polyline = new Polyline(points);
      const lo = Math.ceil((t - phase - travel) / every);
      const hi = Math.floor((t - phase) / every);
      const below = r === 0 ? 0 : cumulative[r - 1], upTo = cumulative[r];
      const dealt = (c: number, k: number) => Math.floor((k + 1) * c) - Math.floor(k * c);
      for (let k = Math.max(lo, hi - 3999); k <= hi; k++) {
        if (dealt(upTo, k) - dealt(below, k) !== 1) continue;
        // Where packet k is, `elapsed` seconds after it left: hidden inside a shape, or `d` along.
        let elapsed = t - k * every - phase, d = 0, hidden = false;
        for (const [a, b, delay] of inside) {
          const reach = (a - d) / speed;
          if (elapsed <= reach) break;
          elapsed -= reach; d = a;
          const stay = (b - a) / speed + delay;
          if (elapsed < stay) { hidden = true; break; }
          elapsed -= stay; d = b;
        }
        if (hidden) continue;
        d += elapsed * speed;
        if (!(d >= 0 && d <= length)) continue;
        const s = stretches.find(([, a, b]) => d >= a && d <= b);
        if (s) bump(s[0], (m) => { m.inFlight += 1; });
        const pt = polyline.point(d / length);
        packets.push(packet(packetID(flow.id, k), pt.x - size / 2, pt.y - size / 2, size, color, source.layerID));
      }
    });
    fm.transit = fm.placed > TINY ? transitSum / fm.placed : null;
    // Backlog piles up above the shape it waits at: the packets that couldn't leave since the state last changed,
    // so the pile grows (up to 30 a flow, in rows of 10, each flow's rows above the last's).
    waiting.forEach(([at, a], j) => {
      bump(at, (m) => { m.depth += a * since; });
      const shape = byID.get(at);
      if (!shape) return;
      const share = a / Math.max(volume, TINY);
      const n = Math.min(Math.max(Math.ceil(share * since / every - 1e-9), 1), 30);
      const rows = Math.trunc((n + 9) / 10);
      const base = piles.get(at) ?? 0;
      piles.set(at, base + rows);
      for (let q = 0; q < n; q++) {
        packets.push(packet(packetID(flow.id, 2 ** 39 + j * 64 + q), shape.x + 2 + (q % 10) * (size + 3),
          shape.y - 4 - size - (base + Math.trunc(q / 10)) * (size + 3), size, color, source.layerID));
      }
    });
    metrics.flows.set(flow.id, fm);
  }
  for (const e of frame.elements) {
    const c = e.capacity ?? null;
    const m = metrics.elements.get(e.id);
    if (c === null || !Number.isFinite(c) || !m) continue;
    m.load = c > 0 ? m.throughput / c : 1;
  }
  return { packets, metrics };
}

const BLANK: Omit<Element, "id" | "kind" | "layerID" | "x" | "y" | "width" | "height" | "style"> = {
  seed: 1, text: null, connector: null, groupID: null, points: null, path: null, subpaths: null, evenOdd: null,
  rotation: null, link: null, url: null, anchor: null, click: null, hover: null, when: null, overrides: null,
  symbol: null, playback: null, offset: null, args: null, image: null, reveal: null,
};

function style(stroke: RGBA, fill: RGBA, strokeWidth: number, fillStyle: Style["fillStyle"] = "solid", opacity: number | null = null): Style {
  return {
    stroke: { ...stroke }, fill: { ...fill }, fillStyle, strokeWidth, dash: "solid", roughness: 0,
    bowing: 1, fontSize: 18, font: null, gridSize: null, opacity, dashOffset: null, textColor: null,
  };
}

function packet(id: string, x: number, y: number, size: number, color: RGBA, layerID: string): Element {
  return { ...BLANK, id, kind: "ellipse", layerID, x, y, width: size, height: size, style: style(color, color, 1.5) };
}

// MARK: Overrides that compare metrics, and gauges

/** The frame's metric for a condition's comparison: its target an element's anchor, or an element's or flow's id. */
export function metricLookup(m: FrameMetrics, frame: Page): (t: MetricTerm) => number | null {
  const anchors = new Map<string, string>();
  for (const e of frame.elements) if (e.anchor !== null && !anchors.has(e.anchor)) anchors.set(e.anchor, e.id);
  const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
  return (term) => {
    const id = anchors.get(term.target) ?? (UUID.test(term.target) ? term.target.toUpperCase() : null);
    return id === null ? null : metricValue(m, term.metric, id);
  };
}

/** `elements` with the looks of overrides that compare metrics applied, and gauges drawn as plain elements; with
 * no values ("all", the editor), both are left as they are (DottieDocument.finishing). */
export function finishing(elements: Element[], metrics: FrameMetrics, values: Record<string, boolean> | null,
  frame: Page, flows: Flow[]): Element[] {
  const lookup = metricLookup(metrics, frame);
  const out: Element[] = [];
  for (let e of elements) {
    if (values !== null && e.overrides) {
      for (const o of e.overrides) {
        if (mentionsMetric(o.when) && holds(o.when, values, lookup)) e = applyOverride(looksOnly(o), e);
      }
    }
    if (e.gauge && values !== null) out.push(...gauge(e, e.gauge, metrics, frame, flows)); else out.push(e);
  }
  return out;
}

const hex = (h: string): RGBA => {
  const v = parseInt(h.slice(1), 16);
  return { r: ((v >> 16) & 0xff) / 255, g: ((v >> 8) & 0xff) / 255, b: (v & 0xff) / 255, a: 1 };
};
export const GAUGE_GREEN = hex("#16a34a"), GAUGE_AMBER = hex("#d97706"), GAUGE_RED = hex("#dc2626");
export const GAUGE_BLUE = hex("#2f6fdf"), GAUGE_TRACK = hex("#e5e7eb"), GAUGE_GRAY = hex("#9ca3af");

/** A metric's value as a gauge shows it: a percentage for load and backup, seconds for transit and delay. */
export function formatted(metric: string, v: number | null): string {
  if (v === null || !Number.isFinite(v)) return "–";
  switch (metric) {
    case "load": case "backup": return formatNumber(v * 100, 0) + "%";
    case "transit": case "delay": return formatNumber(v, Math.abs(v) >= 10 ? 1 : 2) + "s";
    default: return formatNumber(v, Math.abs(v) >= 100 ? 0 : Math.abs(v) >= 10 ? 1 : 2);
  }
}

/** `v` to `places` decimals, halves away from zero, trailing zeros dropped (DottieDocument.number). */
export function formatNumber(v: number, places: number): string {
  const scale = places === 0 ? 1 : places === 1 ? 10 : 100;
  const n = Math.floor(Math.abs(v) * scale + 0.5);
  if (!(n < 1e15)) return v < 0 ? "-∞" : "∞";
  const whole = Math.trunc(n / scale), part = n - whole * scale;
  let s = String(whole);
  if (places > 0 && part > 0) {
    let digits = String(part);
    while (digits.length < places) digits = "0" + digits;
    while (digits.endsWith("0")) digits = digits.slice(0, -1);
    s += "." + digits;
  }
  return (v < 0 && n > 0 ? "-" : "") + s;
}

/** A gauge drawn: its frame as a `.path` carrying the label, then the bar or dial (DottieDocument.gauge). */
export function gauge(e: Element, g: Gauge, metrics: FrameMetrics, frame: Page, flows: Flow[]): Element[] {
  const value = metricValue(metrics, g.metric, g.of);
  const target = frame.elements.find((x) => x.id === g.of);
  const full = g.max ?? (g.metric === "load" ? 1 : target?.capacity ?? value ?? 1);
  const fraction = value === null ? 0 : full > 0 ? Math.min(Math.max(value / full, 0), 1) : 0;
  const warn = g.warn ?? (g.metric === "load" ? 0.7 : null), alarm = g.alarm ?? (g.metric === "load" ? 0.9 : null);
  let color = warn === null && alarm === null ? GAUGE_BLUE : GAUGE_GREEN;
  if (value !== null && warn !== null && value >= warn) color = GAUGE_AMBER;
  if (value !== null && alarm !== null && value >= alarm) color = GAUGE_RED;
  if (value === null) color = GAUGE_GRAY;
  let name = g.label;
  if (name === null) {
    const what = target ? (target.text !== null ? target.text.split("\n")[0] : target.anchor) : null;
    name = `${g.metric} ${what ?? (flows.some((f) => f.id === g.of) ? "flow" : "?")}`;
  }
  const kind = g.style ?? "number";
  const w = Math.max(e.width, 1), h = Math.max(e.height, 1);
  // Normalized cubic contours from points in the gauge's own coordinates.
  const line = (a: Point, b: Point): number[] => [a.x / w, a.y / h, (a.x + (b.x - a.x) / 3) / w, (a.y + (b.y - a.y) / 3) / h,
    (a.x + 2 * (b.x - a.x) / 3) / w, (a.y + 2 * (b.y - a.y) / 3) / h, b.x / w, b.y / h];
  const box = (x: number, y: number, bw: number, bh: number): PathSubpath => {
    const p = [{ x, y }, { x: x + bw, y }, { x: x + bw, y: y + bh }, { x, y: y + bh }];
    let coords = line(p[0], p[1]);
    for (let k = 1; k < 4; k++) coords = coords.concat(line(p[k], p[(k + 1) % 4]).slice(2));
    return { closed: true, coords };
  };
  const arc = (c: Point, radius: number, a0: number, a1: number): PathSubpath => {
    const pieces = Math.max(1, Math.ceil(Math.abs(a1 - a0) / (Math.PI / 2) - 1e-9));
    const step = (a1 - a0) / pieces, kappa = 4 / 3 * Math.tan(step / 4);
    const at = (a: number): Point => ({ x: c.x + radius * Math.cos(a), y: c.y + radius * Math.sin(a) });
    const s = at(a0);
    const coords = [s.x / w, s.y / h];
    for (let k = 0; k < pieces; k++) {
      const a = a0 + k * step, b = a + step;
      const p0 = at(a), p3 = at(b);
      const c1 = { x: p0.x - kappa * radius * Math.sin(a), y: p0.y + kappa * radius * Math.cos(a) };
      const c2 = { x: p3.x + kappa * radius * Math.sin(b), y: p3.y - kappa * radius * Math.cos(b) };
      coords.push(c1.x / w, c1.y / h, c2.x / w, c2.y / h, p3.x / w, p3.y / h);
    }
    return { closed: false, coords };
  };
  const part = (k: number, subpaths: PathSubpath[], stroke: RGBA, fill: RGBA | null, width: number): Element => ({
    ...BLANK, id: packetID(e.id, -(2 ** 38) - k), kind: "path", layerID: e.layerID, x: e.x, y: e.y, width: e.width, height: e.height,
    style: style(stroke, fill ?? { r: 0, g: 0, b: 0, a: 0 }, width, "solid", e.style.opacity), subpaths,
  });

  const back: Element = {
    ...e, gauge: null, kind: "path", subpaths: [box(0, 0, w, h)],
    text: name + "\n" + formatted(g.metric, value), style: { ...e.style },
  };
  const parts: Element[] = [];
  if (kind === "number") {
    back.labelRect = { x: 0, y: 0, width: 1, height: 1 };
    back.style.textColor = { ...color };
  } else if (kind === "bar") {
    back.labelRect = { x: 0, y: 0, width: 1, height: 0.66 };
    const inset = Math.min(10, w * 0.08), barH = Math.min(12, h * 0.18), top = h * 0.72;
    const trackW = w - 2 * inset;
    parts.push(part(1, [box(inset, top, trackW, barH)], GAUGE_TRACK, GAUGE_TRACK, 0.5));
    if (fraction > 0) parts.push(part(2, [box(inset, top, trackW * fraction, barH)], color, color, 0.5));
  } else {
    back.labelRect = { x: 0, y: 0.54, width: 1, height: 0.46 };
    const radius = Math.min(w * 0.38, h * 0.4), center = { x: w / 2, y: h * 0.5 };
    const thick = Math.max(2, radius * 0.16);
    parts.push(part(1, [arc(center, radius, Math.PI, 2 * Math.PI)], GAUGE_TRACK, null, thick));
    if (fraction > 0) parts.push(part(2, [arc(center, radius, Math.PI, Math.PI + Math.PI * fraction)], color, null, thick));
    const a = Math.PI + Math.PI * fraction;
    const tip = { x: center.x + radius * 0.85 * Math.cos(a), y: center.y + radius * 0.85 * Math.sin(a) };
    parts.push(part(3, [{ closed: false, coords: line(center, tip) }], { r: 0.2, g: 0.2, b: 0.2, a: 1 }, null, 2));
  }
  return [back, ...parts];
}
