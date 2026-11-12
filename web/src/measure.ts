// Capacity, metrics and gauges (ADR 0003; font metrics are metrics.ts). The only implementation: Dottie runs this in
// JavaScriptCore (sim-entry.ts, SimulationEngine.swift, ADR 0004). Each frame, the page's flows are assigned to routes in
// page order, as much as each route has room for; the packets drawn and the metrics shown both come from that
// assignment, so a frame stays a pure function of the page, the time and the variables.

import type { Element, Flow, Gauge, Page, PathSubpath, RGBA, Style } from "./model.ts";
import { clamp, DEFAULT_COLOR, DEFAULT_EVERY, DEFAULT_SIZE, DEFAULT_SPEED, flowTree, packetID, routeCost, type FlowTree } from "./flows.ts";
import { Polyline, type Point } from "./path.ts";
import { applyOverride, conditionNames, holds, looksOnly, mentionsMetric, TIME, type MetricTerm } from "./state.ts";
import { tracing } from "./timeline.ts";
import { indexOf } from "./connector.ts";
import { evaluate, exprMetrics, num, parseExpr, type Var } from "./expression.ts";

/** A connector's or shape's metrics in one frame (ElementMetrics). */
export interface ElementMetrics { throughput: number; load: number | null; delay: number; backlog: number; inFlight: number; depth: number }
/** A flow's metrics in one frame (FlowMetrics). */
export interface FlowMetrics { volume: number; placed: number; backlog: number; backup: number; transit: number | null }
/** Every metric of one frame (FrameMetrics). */
export interface FrameMetrics {
  elements: Map<string, ElementMetrics>; flows: Map<string, FlowMetrics>; carry: Record<string, number>;
  /** Per element, the volume each flow delivers through it (not counting what waits), for a slots gauge's colors. */
  byFlow: Map<string, Map<string, number>>;
}

export const emptyMetrics = (): FrameMetrics => ({ elements: new Map(), flows: new Map(), carry: {}, byFlow: new Map() });

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

/** A volume worked out (ADR 0008): a number as it is, 0...1e12 (null or not finite: 1); an expression of the
 * variables and `time` with these values, 0...1e12 (one that can't be read, reads a metric, or isn't a number: 0). */
function volumeIn(v: number | string | null, values: Record<string, Var> | null): number {
  if (typeof v !== "string") return clamp(v, 1, 0, 1e12);
  const e = parseExpr(v);
  if (!e || exprMetrics(e).length > 0) return 0;
  const x = num(evaluate(e, values ?? {}));
  return Number.isFinite(x) ? Math.min(Math.max(x, 0), 1e12) : 0;
}

/** The volume a flow carries with these values (null: its own): the last override that holds, else its own. */
function amountIn(f: Flow, values: Record<string, Var> | null): number {
  let v = f.volume;
  if (values !== null && f.overrides) {
    for (const o of f.overrides) if (o.volume !== null && !mentionsMetric(o.when) && holds(o.when, values)) v = o.volume;
  }
  return volumeIn(v, values);
}

/** Where a flow goes with these values: the destinations of the last override that holds and sets some, else its own. */
function targetsIn(f: Flow, values: Record<string, Var> | null): string[] {
  let to = f.to;
  if (values !== null && f.overrides) {
    for (const o of f.overrides) if (o.to && o.to.length > 0 && !mentionsMetric(o.when) && holds(o.when, values)) to = o.to;
  }
  return to;
}

/** Whether a flow's volume can change as `time` passes: an expression, or an override whose condition reads it. */
function timeVarying(f: Flow): boolean {
  if (typeof f.volume === "string") return true;
  return (f.overrides ?? []).some((o) => o.volume !== null && (typeof o.volume === "string" || (conditionNames(o.when) ?? []).includes(TIME)));
}

/** Seconds between the points at which a time-varying flow's packet count is summed. */
const STEP = 0.05;
/** Per flow and values (but `time`), the packets sent by each STEP: `sums[n]` by `n × STEP` seconds. */
const sent = new Map<string, number[]>();

/** How many packets a flow whose volume changes with `time` has sent by each STEP up to `t`, at `rate(τ)` packets a
 * second: summed once and kept, so its packets keep their places however its volume changes. */
function sentBy(key: string, t: number, rate: (tau: number) => number): number[] {
  let sums = sent.get(key);
  if (!sums) {
    if (sent.size > 64) sent.clear();
    sums = [0];
    sent.set(key, sums);
  }
  const need = Math.ceil(t / STEP) + 1;
  for (let n = sums.length; n <= need && n < 200000; n++) {
    // Trapezoids: the rate at both ends of each step.
    sums.push(sums[n - 1] + (rate((n - 1) * STEP) + rate(n * STEP)) / 2 * STEP);
  }
  return sums;
}

/** A shape's delay as traffic feels it: 0...3600 seconds. */
export function delayOf(e: Element): number {
  const d = e.delay ?? null;
  if (e.kind === "connector" || d === null || !Number.isFinite(d)) return 0;
  return Math.min(Math.max(d, 0), 3600);
}

interface Placement { hops: [string, boolean][]; shapes: string[]; goal: string; amount: number; waits?: boolean }
/** One way a flow's traffic takes in a frame (`flowFrame`'s routes): to `goal` over the connectors `hops`
 * ([connector, backwards]), carrying `amount` of its volume at a cost of `cost`; `waits` when it goes only as far as
 * the queue it waits in. */
export interface FlowRoute { goal: string; hops: [string, boolean][]; amount: number; waits: boolean; cost: number }
interface Way { line: Polyline; length: number; inside: [number, number, number][]; stretches: [string, number, number][] }

/** The key of a flow's queue at a shape in `FrameMetrics.carry` and `carried` (DottieDocument.queueKey). */
export const queueKey = (shape: string, flow: string): string => shape + "|" + flow;

/** The packets the page's flows draw in `frame` (the page posed at `t`), with these values (null: every flow runs),
 * and the frame's metrics. `since` is the seconds since the page's state last changed
 * (null: `t`), and `carried` how much each flow's queue held at that moment: since then a queue grows by its
 * backlog, or drains at the room its way on has left. */
export function flowFrame(flows: Flow[] | null, frame: Page, t: number, values: Record<string, Var> | null,
  offline: Set<string> = new Set(), sinceChange: number | null = null,
  carried: Record<string, number> = {}): { packets: Element[]; metrics: FrameMetrics; routes: Map<string, FlowRoute[]> } {
  const since = Math.max(0, Math.min(sinceChange ?? t, 1e6));
  const byID = indexOf(frame);
  // Each connector's line, traced once however many ways go along it.
  const traced = new Map<string, Point[]>();
  const traceOf = (c: Element): Point[] => {
    let pts = traced.get(c.id);
    if (!pts) { pts = tracing(c, frame, byID).points; traced.set(c.id, pts); }
    return pts;
  };
  const metrics = emptyMetrics();
  // The ways each flow that runs takes, for inspecting them (none when it reaches nothing).
  const routes = new Map<string, FlowRoute[]>();
  for (const e of frame.elements) {
    if (e.kind === "connector" && !e.connector) continue;
    metrics.elements.set(e.id, { throughput: 0, load: null, delay: e.kind !== "connector" ? delayOf(e) : 0, backlog: 0, inFlight: 0, depth: 0 });
  }
  // Each flow's destinations as its overrides set them now.
  const list = (flows ?? []).map((f) => { const to = targetsIn(f, values); return to === f.to ? f : { ...f, to }; });
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
  // A route as drawn: its line, length, the stretches inside the shapes it passes, and each hop's stretch.
  const way = (hops: [string, boolean][], shapes: string[]): Way | null => {
    const points: Point[] = [], inside: [number, number, number][] = [], stretches: [string, number, number][] = [];
    let length = 0;
    hops.forEach(([id, back], k) => {
      const c = byID.get(id);
      if (!c) return;
      const line = back ? [...traceOf(c)].reverse() : traceOf(c);
      if (line.length === 0) return;
      const last = points[points.length - 1];
      if (last) {
        const gap = Math.hypot(line[0].x - last.x, line[0].y - last.y);
        const shape = byID.get(shapes[k]);
        inside.push([length, length + gap, shape ? delayOf(shape) : 0]);
        length += gap;
      }
      const start = length;
      for (let q = 1; q < line.length; q++) length += Math.hypot(line[q].x - line[q - 1].x, line[q].y - line[q - 1].y);
      stretches.push([id, start, length]);
      points.push(...line);
    });
    return length > 0 ? { line: new Polyline(points), length, inside, stretches } : null;
  };
  // Where a packet is `elapsed` seconds after leaving along `w`: null while hidden inside a shape or off the end.
  const along = (w: Way, elapsedAt: number, speed: number): number | null => {
    let elapsed = elapsedAt, d = 0;
    for (const [a, b, delay] of w.inside) {
      const reach = (a - d) / speed;
      if (elapsed <= reach) break;
      elapsed -= reach; d = a;
      const stay = (b - a) / speed + delay;
      if (elapsed < stay) return null;
      elapsed -= stay; d = b;
    }
    d += elapsed * speed;
    return d >= 0 && d <= w.length ? d : null;
  };
  const union = (a: Set<string>, b: Set<string>) => new Set([...a, ...b]);
  const bump = (id: string, f: (m: ElementMetrics) => void) => { const m = metrics.elements.get(id); if (m) f(m); };
  const deliver = (id: string, flow: string, a: number) => {
    let m = metrics.byFlow.get(id);
    if (!m) { m = new Map(); metrics.byFlow.set(id, m); }
    m.set(flow, (m.get(flow) ?? 0) + a);
  };

  // Flows leaving the same shape take turns; the page's biggest flow draws a packet every `every` seconds.
  const leaving = new Map<string, number>(), turn: number[] = [];
  for (const flow of list) { const n = leaving.get(flow.from) ?? 0; turn.push(n); leaving.set(flow.from, n + 1); }
  // A volume that changes with time is measured at its start, so the page's packets don't change spacing as it plays.
  const atStart = values !== null && values[TIME] !== undefined ? { ...values, [TIME]: 0 } : values;
  const biggest = list.length > 0 ? Math.max(...list.map((f) => volumeIn(f.volume, atStart)), TINY) : 1;
  const packets: Element[] = [];
  const waitingBy = new Map<string, [string, number][]>();
  const everyOf = (flow: Flow) =>
    Math.min(Math.max(clamp(flow.every, DEFAULT_EVERY, 0.05, 60) * biggest / Math.max(amountIn(flow, values), TINY), 0.05), 60);

  // The cheapest ways from a source, ignoring capacity, are the same for every flow leaving it.
  const bases = new Map<string, FlowTree | null>();
  const baseTree = (from: string): FlowTree | null => {
    if (!bases.has(from)) bases.set(from, flowTree(from, frame, offline));
    return bases.get(from)!;
  };
  for (const [i, flow] of list.entries()) {
    if (flow.when !== null && values !== null && !holds(flow.when, values)) continue;
    const source = byID.get(flow.from);
    const base = source ? baseTree(flow.from) : null;
    routes.set(flow.id, []);
    if (!source || !base) continue;
    const volume = amountIn(flow, values);
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
        const tree = flowTree(flow.from, frame, union(offline, full()), candidates[0]);
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
        if (first) {
          at = first[1];
          // Or the nearest queue before that, on the way from the source.
          const upTo = r.shapes.indexOf(at);
          for (let q = upTo; q >= 0; q--) {
            const s = byID.get(r.shapes[q]);
            if (s && s.queue === true && s.kind !== "connector") { at = r.shapes[q]; break; }
          }
        }
        // It still travels as far as the queue it waits in.
        const n = r.shapes.indexOf(at);
        if (at !== flow.from && n >= 0) {
          const shapes = r.shapes.slice(0, n + 1), hops = r.hops.slice(0, n);
          for (const id of [...shapes, ...hops.map(([h]) => h)]) if (room.has(id)) room.set(id, Math.max(0, room.get(id)! - left));
          placements.push({ hops, shapes, goal: at, amount: left, waits: true });
        }
      }
      const existing = waiting.find(([s]) => s === at);
      if (existing) existing[1] += left; else waiting.push([at, left]);
    }
    waitingBy.set(flow.id, waiting);
    routes.set(flow.id, placements.map((p) => ({ goal: p.goal, hops: p.hops, amount: p.amount, waits: p.waits === true,
      cost: p.hops.reduce((s, [id]) => s + routeCost(byID.get(id)?.connector?.cost ?? null), 0) })));

    // Metrics.
    for (const p of placements) {
      for (const id of [...p.shapes, ...p.hops.map(([h]) => h)]) {
        bump(id, (m) => { m.throughput += p.amount; });
        if (!p.waits) deliver(id, flow.id, p.amount);
      }
      if (!p.waits) fm.placed += p.amount;
    }
    for (const [at, a] of waiting) { bump(at, (m) => { m.backlog += a; }); fm.backlog += a; }
    const reachedFirst = placements.filter((p) => !p.waits && p.goal === flow.to[0]).reduce((s, p) => s + p.amount, 0);
    fm.backup = volume > TINY ? Math.max(0, (volume - reachedFirst) / volume) : 0;

    // Packets: dealt across the placements by their share of the volume.
    const every = everyOf(flow);
    const speed = clamp(flow.speed, DEFAULT_SPEED, 1, 10000), size = clamp(flow.size, DEFAULT_SIZE, 2, 200);
    const phase = (turn[i] / leaving.get(flow.from)!) * every;
    const color = flow.color ?? DEFAULT_COLOR;
    const cumulative: number[] = [];
    let sum = 0;
    for (const p of placements) { sum += p.amount / Math.max(volume, TINY); cumulative.push(sum); }
    if (cumulative.length > 0 && Math.abs(cumulative[cumulative.length - 1] - 1) < 1e-9) cumulative[cumulative.length - 1] = 1;
    let transitSum = 0;
    // A flow whose volume changes as the page plays sends its packets at the rate of the moment (ADR 0008): packet k
    // leaves when the packets sent since the start reach k, so the ones on their way stay put as the rate changes.
    let leftAt: ((k: number) => number) | null = null, sentNow = 0;
    if (values !== null && values[TIME] !== undefined && timeVarying(flow)) {
      const base = clamp(flow.every, DEFAULT_EVERY, 0.05, 60) * biggest;
      const rate = (tau: number) => {
        const v = amountIn(flow, { ...values, [TIME]: tau });
        return v > TINY ? Math.min(v / base, 20) : 0;
      };
      const others = Object.fromEntries(Object.entries(values).filter(([k]) => k !== TIME));
      const sums = sentBy(JSON.stringify([flow.id, flow.volume, flow.overrides ?? null, base, others]), t, rate);
      const shift = turn[i] / leaving.get(flow.from)!;
      const sentAt = (tau: number) => {
        const n = Math.min(Math.floor(tau / STEP), sums.length - 2), u = (tau - n * STEP) / STEP;
        return sums[n] + (sums[n + 1] - sums[n]) * u + shift;
      };
      sentNow = sentAt(t);
      // The moment packet k left: found by halving, the count only growing with time.
      leftAt = (k: number) => {
        let a = 0, b = t;
        if (sentAt(0) >= k) return 0;
        for (let q = 0; q < 40; q++) { const m = (a + b) / 2; if (sentAt(m) >= k) b = m; else a = m; }
        return b;
      };
    }
    placements.forEach((p, r) => {
      const w = way(p.hops, p.shapes);
      if (!w) return;
      const travel = w.length / speed + w.inside.reduce((s, x) => s + x[2], 0);
      if (!p.waits) transitSum += travel * p.amount;
      let lo = Math.ceil((t - phase - travel) / every);
      let hi = Math.floor((t - phase) / every);
      if (leftAt) {
        hi = Math.floor(sentNow);
        // Back from now until a packet left longer ago than the way takes.
        lo = hi + 1;
        while (lo > 0 && hi - lo < 3999 && t - leftAt(lo - 1) <= travel) lo--;
      }
      const below = r === 0 ? 0 : cumulative[r - 1], upTo = cumulative[r];
      const dealt = (c: number, k: number) => Math.floor((k + 1) * c) - Math.floor(k * c);
      for (let k = Math.max(lo, hi - 3999); k <= hi; k++) {
        if (dealt(upTo, k) - dealt(below, k) !== 1) continue;
        const d = along(w, leftAt ? t - leftAt(k) : t - k * every - phase, speed);
        if (d === null) continue;
        const s = w.stretches.find(([, a, b]) => d >= a && d <= b);
        if (s) bump(s[0], (m) => { m.inFlight += 1; });
        const pt = w.line.point(d / w.length);
        packets.push(packet(packetID(flow.id, k), pt.x - size / 2, pt.y - size / 2, size, color, source.layerID));
      }
    });
    fm.transit = fm.placed > TINY ? transitSum / fm.placed : null;
    metrics.flows.set(flow.id, fm);
  }

  // Queues: each flow's at each shape, its own or carried over from before the state changed. One with backlog
  // grows by it; one without drains at the room left on its way on, and the drained traffic leaves as packets.
  const piles = new Map<string, number>();
  // The queues carried over, so a flow without one doesn't look for it at every element.
  const carriedKeys = Object.keys(carried).filter((k) => carried[k] > TINY);
  for (const flow of list) {
    const waiting = waitingBy.get(flow.id) ?? [];
    const shapes = waiting.map(([s]) => s);
    const suffix = "|" + flow.id;
    if (carriedKeys.some((k) => k.endsWith(suffix))) for (const e of frame.elements) {
      const c = carried[queueKey(e.id, flow.id)];
      if (c !== undefined && c > TINY && !shapes.includes(e.id)) shapes.push(e.id);
    }
    if (shapes.length === 0) continue;
    const volume = amountIn(flow, values);
    const every = everyOf(flow);
    const unit = every * Math.max(volume, TINY);
    const speed = clamp(flow.speed, DEFAULT_SPEED, 1, 10000), size = clamp(flow.size, DEFAULT_SIZE, 2, 200);
    const color = flow.color ?? DEFAULT_COLOR;
    shapes.forEach((at, j) => {
      const shape = byID.get(at);
      if (!shape) return;
      const layer = byID.get(flow.from)?.layerID ?? shape.layerID;
      const backlog = waiting.find(([s]) => s === at)?.[1] ?? 0;
      const before = Math.max(0, carried[queueKey(at, flow.id)] ?? 0);
      let depth = before + backlog * since;
      // Drain: at the room left on the ways on to the flow's destinations, the cheapest first, then the next.
      if (backlog <= TINY && before > TINY) {
        const trial = new Map(room);
        const outlets: { hops: [string, boolean][]; shapes: string[]; rate: number }[] = [];
        let total = 0;
        for (let n = 0; n < 32; n++) {
          const blocked = new Set([...trial].filter(([, v]) => v <= TINY).map(([id]) => id));
          const tree = flowTree(at, frame, union(offline, blocked), flow.to[0]);
          const goal = tree?.goals(flow.to, false)[0];
          if (!tree || goal === undefined) break;
          const r = route(tree, goal);
          const ids = [...r.shapes.slice(1), ...r.hops.map(([id]) => id)];
          const rooms = ids.filter((id) => trial.has(id)).map((id) => trial.get(id)!);
          const spare = rooms.length > 0 ? Math.min(...rooms) : Infinity;
          const rate = Number.isFinite(spare) ? spare : Math.max(before / 0.5 - total, TINY * 2);
          if (!(rate > TINY)) break;
          for (const id of ids) if (trial.has(id)) trial.set(id, trial.get(id)! - rate);
          outlets.push({ hops: r.hops, shapes: r.shapes, rate });
          total += rate;
          if (!Number.isFinite(spare)) break;
        }
        if (total > TINY) {
          depth = Math.max(0, before - total * since);
          if (depth > TINY) {
            for (const [id, v] of trial) room.set(id, v);
            for (const o of outlets) for (const id of [...o.shapes, ...o.hops.map(([h]) => h)]) {
              bump(id, (m) => { m.throughput += o.rate; });
              deliver(id, flow.id, o.rate);
            }
          }
          // The drained traffic: packets leaving the queue along each way while it empties.
          const lasts = before / total;
          outlets.forEach((o, i) => {
            const w = way(o.hops, o.shapes);
            if (!w) return;
            const spacing = Math.max(unit / o.rate, 0.05);
            for (let k = 0; k * spacing < lasts && k * spacing <= since && k < 2048; k++) {
              const d = along(w, since - k * spacing, speed);
              if (d === null) continue;
              const pt = w.line.point(d / w.length);
              packets.push(packet(packetID(flow.id, 2 ** 39 + 2 ** 20 + j * 2 ** 14 + i * 2 ** 11 + k), pt.x - size / 2, pt.y - size / 2, size, color, layer));
            }
          });
        }
      }
      if (!(depth > TINY || backlog > TINY)) return;
      bump(at, (m) => { m.depth += depth; });
      if (depth > TINY) metrics.carry[queueKey(at, flow.id)] = depth;
      const n = Math.min(Math.max(Math.ceil(depth / unit - 1e-9), 1), 30);
      const rows = Math.trunc((n + 9) / 10);
      const base = piles.get(at) ?? 0;
      piles.set(at, base + rows);
      for (let q = 0; q < n; q++) {
        const cx = shape.x + 2 + size / 2 + (q % 10) * (size + 3);
        const cy = shape.y - 4 - size / 2 - (base + Math.trunc(q / 10)) * (size + 3);
        packets.push(packet(packetID(flow.id, 2 ** 39 + j * 64 + q), cx - size / 2, cy - size / 2, size, color, layer));
      }
    });
  }
  for (const e of frame.elements) {
    const c = e.capacity ?? null;
    const m = metrics.elements.get(e.id);
    if (c === null || !Number.isFinite(c) || !m) continue;
    m.load = c > 0 ? m.throughput / c : 1;
  }
  return { packets, metrics, routes };
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
export function metricLookup(m: FrameMetrics, frame: Page): (t: MetricTerm, own: string | null) => number | null {
  const anchors = new Map<string, string>();
  for (const e of frame.elements) if (e.anchor !== null && !anchors.has(e.anchor)) anchors.set(e.anchor, e.id);
  const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
  return (term, own) => {
    // No target: the element the condition is on.
    const id = term.target === "" ? own : anchors.get(term.target) ?? (UUID.test(term.target) ? term.target.toUpperCase() : null);
    return id === null ? null : metricValue(m, term.metric, id);
  };
}

/** What finishing does to one element: which of its overrides that compare metrics hold (their looks apply, in
 * order), and, for a gauge, the reading it shows. */
export interface Finish { applied: number[]; gauge: Reading | null }
/** What a gauge shows: its reading (eased), the reading it is easing to, and what each flow brings to its target. */
export interface Reading { value: number | null; settled?: number | null; shares?: [string, number][] }

/** For each of `elements`, the overrides that compare metrics that hold and the reading a gauge shows (easing, over
 * `GAUGE_EASE` seconds since the state changed, from its reading then, `carried`); with no values ("all", the
 * editor), nothing. The readings come back to carry over. */
export function finishPlan(elements: Element[], metrics: FrameMetrics, values: Record<string, Var> | null,
  frame: Page, since = Infinity, carried: Record<string, number> = {}): { plan: Finish[]; readings: Record<string, number> } {
  const lookup = metricLookup(metrics, frame);
  const plan: Finish[] = [], readings: Record<string, number> = {};
  for (const e of elements) {
    const applied: number[] = [];
    if (values !== null && e.overrides) {
      e.overrides.forEach((o, k) => {
        if (mentionsMetric(o.when) && holds(o.when, values, (m) => lookup(m, e.id))) applied.push(k);
      });
    }
    // The editor ("all", no values) edits the gauge itself, a rectangle.
    const g = values === null ? null : e.gauge;
    if (!g) { plan.push({ applied, gauge: null }); continue; }
    const settled = metricValue(metrics, g.metric, g.of);
    let shown = settled;
    const then = carried[gaugeKey(e.id)];
    if (shown !== null && then !== undefined && g.metric !== "depth" && g.metric !== "inFlight" && since < GAUGE_EASE) {
      const f = Math.max(0, since / GAUGE_EASE), smooth = f * f * (3 - 2 * f);
      shown = then + (shown - then) * smooth;
    }
    if (shown !== null) readings[gaugeKey(e.id)] = shown;
    const shares = g.style === "slots" ? [...(metrics.byFlow.get(g.of) ?? new Map<string, number>())] : undefined;
    plan.push({ applied, gauge: { value: shown, settled, shares } });
  }
  return { plan, readings };
}

/** `elements` with the looks of overrides that compare metrics applied, and gauges drawn as plain elements; with
 * no values ("all", the editor), both are left as they are (`finishPlan`). */
export function finishing(elements: Element[], metrics: FrameMetrics, values: Record<string, Var> | null,
  frame: Page, flows: Flow[], since = Infinity, carried: Record<string, number> = {}): { elements: Element[]; readings: Record<string, number> } {
  const { plan, readings } = finishPlan(elements, metrics, values, frame, since, carried);
  const out: Element[] = [];
  elements.forEach((e, i) => {
    for (const k of plan[i].applied) e = applyOverride(looksOnly(e.overrides![k]), e);
    const g = plan[i].gauge;
    if (g && e.gauge) out.push(...gauge(e, e.gauge, g.value, frame, flows, g)); else out.push(e);
  });
  return { elements: out, readings };
}

/** The key of a gauge's reading in `FrameMetrics.carry` and `carried` (DottieDocument.gaugeKey). */
export const gaugeKey = (id: string): string => "gauge|" + id;
/** Seconds a gauge takes to ease from its reading when the state changed to the new one. */
const GAUGE_EASE = 1;

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

/** A gauge drawn: its frame as a `.path` carrying the label, then the bar or dial. */
export function gauge(e: Element, g: Gauge, value: number | null, frame: Page, flows: Flow[], reading: Reading | null = null): Element[] {
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
  } else if (kind === "slots") {
    // Load is shown a square per unit of the target's capacity, the reading its share of them.
    const load = g.metric === "load";
    const cap = target?.capacity ?? null;
    const squares = load ? (cap !== null && Number.isFinite(cap) && cap > 0 ? cap : 100) : full;
    const scale = load ? squares / Math.max(full, TINY) : 1;
    const scaled = (v: number | null | undefined) => (v === null || v === undefined ? v ?? null : v * scale);
    slots(w, h, squares, scaled(value), reading && { ...reading, settled: scaled(reading.settled) }, color, flows, box, back, parts, part, g.metric);
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

/** Most squares a slots gauge draws; past that, each stands for more. */
const MAX_SLOTS = 2400;

/** A slots gauge: a grid of squares, one per unit of `full`, filled in the order of the page's flows with each flow's
 * color for what it delivers through the target, pale for what the reading is still easing toward, and the gauge's
 * color for the rest (a metric no flow makes up). The label sits above the grid. */
function slots(w: number, h: number, full: number, value: number | null, reading: Reading | null, color: RGBA,
  flows: Flow[], box: (x: number, y: number, bw: number, bh: number) => PathSubpath, back: Element, parts: Element[],
  part: (k: number, subpaths: PathSubpath[], stroke: RGBA, fill: RGBA | null, width: number) => Element, metric: string): void {
  // One line above the grid: the name, then the reading out of what the squares stand for (thousands grouped), and
  // what a square stands for when it's more than one.
  const [name, reading0] = (back.text ?? "").split("\n");
  const inset = Math.min(8, w * 0.04);
  const gw = w - 2 * inset;
  let unit = 1, n = Math.ceil(full - 1e-9);
  const band0 = Math.min(back.style.fontSize * 1.5 + 6, h * 0.4);
  const gh = h - band0 - inset;
  // One square per unit of `full`, or per as many units as keep the squares at least 3 points across.
  const fits = (k: number) => Math.min(MAX_SLOTS, Math.floor(gw / 3) * Math.floor(Math.max(gh, 0) / 3)) >= k;
  // Each step a round number: 2, 5, 10, 20, 50, ...
  while (full > 0 && !fits(n) && unit < 1e12) {
    const lead = unit / 10 ** Math.floor(Math.log10(unit) + 1e-9);
    unit = Math.round(unit * (lead < 1.5 ? 2 : lead < 3 ? 2.5 : 2));
    n = Math.ceil(full / unit - 1e-9);
  }
  n = Math.max(1, n);
  const shown = metric === "load" ? reading0 ?? "" : grouped(reading0 ?? "") + (value !== null ? " / " + grouped(formatted(metric, full)) : "");
  back.text = [name, shown].filter((x) => x).join(" · ") + (unit > 1 ? ` · 1 □ = ${grouped(formatNumber(unit, 0))}` : "");
  // Smaller type when the line wouldn't fit across (about 0.56 of the size a character, Helvetica's average).
  const across = back.text.length * 0.56 * back.style.fontSize;
  if (across > w - 12) back.style.fontSize = Math.max(8, Math.floor(((w - 12) / (back.text.length * 0.56)) * 10) / 10);
  const band = Math.min(back.style.fontSize * 1.5 + 6, h * 0.4);
  back.labelRect = { x: 0, y: 0, width: 1, height: band / h };
  if (!(gw > 2 && gh > 2) || !(full > 0)) return;
  // The largest pitch that fits n squares in the grid.
  let pitch = Math.sqrt((gw * gh) / n);
  for (let k = 0; k < 64; k++) {
    const cols = Math.max(1, Math.floor(gw / pitch));
    if (Math.ceil(n / cols) * pitch <= gh + 1e-9) break;
    pitch *= 0.97;
  }
  const cols = Math.max(1, Math.floor(gw / pitch));
  const side = Math.max(1, pitch * 0.78);
  // Squares fill in a scattered order that is the same every frame, as tasks land wherever a slot is free: the r-th
  // square filled is `order[r]`, so a growing flow takes new squares and the others keep theirs.
  const order = Array.from({ length: n }, (_, i) => i).sort((a, b) => scatter(a) - scatter(b) || a - b);
  const cell = (r: number): PathSubpath => {
    const i = order[r];
    return box(inset + (i % cols) * pitch, band0 + Math.trunc(i / cols) * pitch, side, side);
  };
  // How many squares each color takes: the flows' shares of the reading, largest remainders first.
  const fraction = (v: number | null) => (v === null || !Number.isFinite(v) ? 0 : Math.min(Math.max(v / full, 0), 1));
  const shownN = Math.round(fraction(value) * n), settledN = Math.max(shownN, Math.round(fraction(reading?.settled ?? value) * n));
  const byFlow = new Map(reading?.shares ?? []);
  const total = [...byFlow.values()].reduce((a, b) => a + b, 0);
  const colored: [RGBA, number][] = [];
  if (total > 0 && (metric === "throughput" || metric === "load")) {
    const order = flows.filter((f) => (byFlow.get(f.id) ?? 0) > 0);
    const exact = order.map((f) => (byFlow.get(f.id)! / total) * settledN);
    const counts = exact.map(Math.floor);
    let left = settledN - counts.reduce((a, b) => a + b, 0);
    for (const k of exact.map((x, k) => [x - Math.floor(x), k]).sort((a, b) => b[0] - a[0]).map(([, k]) => k)) {
      if (left <= 0) break;
      counts[k] += 1; left -= 1;
    }
    order.forEach((f, k) => colored.push([f.color ?? DEFAULT_COLOR, counts[k]]));
  } else {
    colored.push([color, settledN]);
  }
  // Squares in order: each color's, the last of them pale while the reading eases up to them.
  const groups = new Map<string, { stroke: RGBA; fill: RGBA; cells: PathSubpath[] }>();
  const add = (key: string, c: RGBA, i: number) => {
    let g = groups.get(key);
    if (!g) { g = { stroke: c, fill: c, cells: [] }; groups.set(key, g); }
    g.cells.push(cell(i));
  };
  let i = 0;
  // Pale squares are the newest: spread over the colors in proportion, at the end of each color's run.
  const pale = settledN - shownN;
  colored.forEach(([c, count], k) => {
    const paleHere = settledN > 0 ? Math.round((pale * count) / settledN) : 0;
    for (let q = 0; q < count && i < n; q++, i++) {
      if (q >= count - paleHere) add("p" + k, { ...c, a: c.a * 0.35 }, i); else add("s" + k, c, i);
    }
  });
  const empty: PathSubpath[] = [];
  for (; i < n; i++) empty.push(cell(i));
  let k = 1;
  if (empty.length > 0) parts.push(part(k++, empty, GAUGE_TRACK, GAUGE_TRACK, 0.5));
  for (const g of groups.values()) parts.push(part(k++, g.cells, g.stroke, g.fill, 0.5));
}

/** A square's place in a slots gauge's filling order: a fixed scramble of its index. */
function scatter(i: number): number {
  let x = Math.imul(i + 1, 0x9e3779b1);
  x = Math.imul(x ^ (x >>> 15), 0x85ebca6b);
  return (x ^ (x >>> 13)) >>> 0;
}

/** A number's text with its whole part in groups of three: 35200 is 35,200, 1234.5 is 1,234.5. */
function grouped(s: string): string {
  return s.replace(/^(-?)(\d+)/, (_, sign: string, whole: string) => sign + whole.replace(/\B(?=(\d{3})+(?!\d))/g, ","));
}
