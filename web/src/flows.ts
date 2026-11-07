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

/** The connectors traffic takes from `from` to the first of `to` it reaches in `frame`, as [connector, backwards]
 * hops; null when none can be reached. Breadth first by hop count, earlier connectors first. */
export function flowRoute(from: string, to: string[], frame: Page, offline: Set<string> = new Set()): [string, boolean][] | null {
  const shapes = new Set(frame.elements.filter((e) => e.kind !== "connector" && !offline.has(e.id)).map((e) => e.id));
  if (!shapes.has(from)) return null;
  const next = new Map<string, { to: string; via: string; back: boolean }[]>();
  const add = (a: string, edge: { to: string; via: string; back: boolean }) => {
    const list = next.get(a);
    if (list) list.push(edge); else next.set(a, [edge]);
  };
  for (const e of frame.elements) {
    const c = e.connector;
    const a = c?.start.elementID ?? null, b = c?.end.elementID ?? null;
    if (!c || offline.has(e.id) || a === null || b === null || a === b || !shapes.has(a) || !shapes.has(b)) continue;
    add(a, { to: b, via: e.id, back: false });
    if (c.startHead !== "none") add(b, { to: a, via: e.id, back: true });
  }
  const came = new Map<string, { from: string; via: string; back: boolean }>();
  const seen = new Set([from]);
  const queue = [from];
  for (let head = 0; head < queue.length; head++) {
    const n = queue[head];
    for (const edge of next.get(n) ?? []) {
      if (seen.has(edge.to)) continue;
      seen.add(edge.to);
      came.set(edge.to, { from: n, via: edge.via, back: edge.back });
      queue.push(edge.to);
    }
  }
  const goal = to.find((x) => x !== from && seen.has(x));
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
  for (const flow of flows) {
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
    // Packet k left at k × every; it's on the route while 0 <= (t − k × every) × speed <= length.
    const lo = Math.ceil((t - length / speed) / every);
    const hi = Math.floor(t / every);
    if (hi < lo) continue;
    const color = flow.color ?? DEFAULT_COLOR;
    for (let k = Math.max(lo, hi - MAX_PACKETS + 1); k <= hi; k++) {
      const d = (t - k * every) * speed;
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
