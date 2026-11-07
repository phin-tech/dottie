// Traffic flows (Flows.swift, ADR 0002): packets aren't stored; each frame routes every flow over the connectors still
// drawn, from the time and the page's variables, so when a click takes a region down the traffic goes round it.

import type { Element, Flow, Page, RGBA } from "./model.ts";
import { Polyline, type Point } from "./path.ts";
import { holds } from "./state.ts";
import { tracing } from "./timeline.ts";

const DEFAULT_EVERY = 0.5, DEFAULT_SPEED = 160, DEFAULT_SIZE = 12;
const DEFAULT_COLOR: RGBA = { r: 0.95, g: 0.36, b: 0.33, a: 1 };
const MAX_PACKETS = 400;

const clamp = (v: number | null, fallback: number, lo: number, hi: number): number =>
  v === null || !Number.isFinite(v) ? fallback : Math.min(Math.max(v, lo), hi);

/** The id of a flow's packet `k`: the flow's id with its last twelve digits standing for `k` (Flow.packetID). */
export function packetID(flow: string, k: number): string {
  const n = (k + 2 ** 40) % 2 ** 48;
  return flow.slice(0, 24) + (n < 0 ? n + 2 ** 48 : n).toString(16).toUpperCase().padStart(12, "0");
}

/** `cost` as routing uses it: 1 for null, kept within 0...1,000,000 (ConnectorData.routeCost). */
const routeCost = (cost: number | null): number =>
  cost === null || !Number.isFinite(cost) ? 1 : Math.min(Math.max(cost, 0), 1_000_000);

/** The connectors traffic takes from `from` to the first of `to` it reaches in `frame`, as [connector, backwards]
 * hops; null when none can be reached. The cheapest route by the connectors' cost (1 each unless set), ties to the
 * route found first, earlier connectors first: with no costs set, the fewest hops. */
export function flowRoute(from: string, to: string[], frame: Page, offline: Set<string> = new Set()): [string, boolean][] | null {
  const shapes = new Set(frame.elements.filter((e) => e.kind !== "connector" && !offline.has(e.id)).map((e) => e.id));
  if (!shapes.has(from)) return null;
  type Edge = { to: string; via: string; back: boolean; cost: number };
  const next = new Map<string, Edge[]>();
  const add = (a: string, edge: Edge) => {
    const list = next.get(a);
    if (list) list.push(edge); else next.set(a, [edge]);
  };
  for (const e of frame.elements) {
    const c = e.connector;
    const a = c?.start.elementID ?? null, b = c?.end.elementID ?? null;
    if (!c || offline.has(e.id) || a === null || b === null || a === b || !shapes.has(a) || !shapes.has(b)) continue;
    const cost = routeCost(c.cost);
    add(a, { to: b, via: e.id, back: false, cost });
    if (c.startHead !== "none") add(b, { to: a, via: e.id, back: true, cost });
  }
  // Dijkstra, settling the cheapest shape next, ties to the one reached first, as Flows.swift does.
  const dist = new Map<string, number>([[from, 0]]), order = new Map<string, number>([[from, 0]]);
  let counter = 1;
  const came = new Map<string, { from: string; via: string; back: boolean }>();
  const open = [from], settled = new Set<string>();
  while (open.length > 0) {
    let best = 0;
    for (let i = 1; i < open.length; i++) {
      const da = dist.get(open[i])!, db = dist.get(open[best])!;
      if (da < db || (da === db && order.get(open[i])! < order.get(open[best])!)) best = i;
    }
    const n = open.splice(best, 1)[0];
    settled.add(n);
    for (const edge of next.get(n) ?? []) {
      if (settled.has(edge.to)) continue;
      const d = dist.get(n)! + edge.cost;
      const old = dist.get(edge.to);
      if (old !== undefined && old <= d) continue;
      if (old === undefined) open.push(edge.to);
      dist.set(edge.to, d); order.set(edge.to, counter++);
      came.set(edge.to, { from: n, via: edge.via, back: edge.back });
    }
  }
  const goal = to.find((x) => x !== from && settled.has(x));
  if (goal === undefined) return null;
  const hops: [string, boolean][] = [];
  for (let at = goal, step = came.get(at); step; at = step.from, step = came.get(at)) hops.push([step.via, step.back]);
  return hops.reverse();
}

/** The packets the page's flows draw in `frame` (the page posed at `t`), with these values (null: every flow runs). */
export function flowPackets(flows: Flow[] | null, frame: Page, t: number, values: Record<string, boolean> | null,
  offline: Set<string> = new Set()): Element[] {
  if (!flows || flows.length === 0) return [];
  const byID = new Map<string, Element>();
  for (const e of frame.elements) if (!byID.has(e.id)) byID.set(e.id, e);
  const out: Element[] = [];
  // Flows leaving the same shape take turns: the i-th of m starts i/m of its gap later, so they don't draw on top
  // of each other. Counted over the page's flows, whatever their conditions, so a flow switching on moves none.
  const leaving = new Map<string, number>(), turn: number[] = [];
  for (const flow of flows) { const n = leaving.get(flow.from) ?? 0; turn.push(n); leaving.set(flow.from, n + 1); }
  for (const [i, flow] of flows.entries()) {
    if (flow.when !== null && values !== null && !holds(flow.when, values)) continue;
    const source = byID.get(flow.from);
    const hops = source ? flowRoute(flow.from, flow.to, frame, offline) : null;
    if (!source || !hops) continue;
    const points: Point[] = [];
    for (const [id, back] of hops) {
      const c = byID.get(id);
      if (!c) continue;
      const p = tracing(c, frame).points;
      points.push(...(back ? [...p].reverse() : p));
    }
    const line = new Polyline(points);
    const length = line.length;
    if (!(length > 0)) continue;
    const every = clamp(flow.every, DEFAULT_EVERY, 0.05, 60);
    const speed = clamp(flow.speed, DEFAULT_SPEED, 1, 10000);
    const size = clamp(flow.size, DEFAULT_SIZE, 2, 200);
    // Packet k left at k × every + phase; it's on the route while 0 <= (t − k × every − phase) × speed <= length.
    const phase = (turn[i] / leaving.get(flow.from)!) * every;
    const lo = Math.ceil((t - phase - length / speed) / every);
    const hi = Math.floor((t - phase) / every);
    if (hi < lo) continue;
    const color = flow.color ?? DEFAULT_COLOR;
    for (let k = Math.max(lo, hi - MAX_PACKETS + 1); k <= hi; k++) {
      const d = (t - k * every - phase) * speed;
      const p = line.point(d / length);
      out.push({
        id: packetID(flow.id, k), kind: "ellipse", layerID: source.layerID,
        x: p.x - size / 2, y: p.y - size / 2, width: size, height: size,
        style: {
          stroke: { ...color }, fill: { ...color }, fillStyle: "solid", strokeWidth: 1.5, dash: "solid", roughness: 0,
          bowing: 1, fontSize: 18, font: null, gridSize: null, opacity: null, dashOffset: null, textColor: null,
        },
        seed: 1, text: null, connector: null, groupID: null, points: null, path: null, subpaths: null, evenOdd: null,
        rotation: null, link: null, url: null, anchor: null, click: null, hover: null, when: null, overrides: null,
        symbol: null, playback: null, offset: null, args: null, image: null, reveal: null,
      });
    }
  }
  return out;
}
