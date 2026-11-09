// Traffic flows (ADR 0002; the model is Flows.swift, and Dottie runs this routing in JavaScriptCore, ADR 0004): packets aren't stored; each frame routes every flow over the connectors still
// drawn, from the time and the page's variables, so when a click takes a region down the traffic goes round it.

import type { Element, Flow, Page, RGBA } from "./model.ts";
import { Polyline, type Point } from "./path.ts";
import { holds } from "./state.ts";
import { tracing } from "./timeline.ts";

export const DEFAULT_EVERY = 0.5, DEFAULT_SPEED = 160, DEFAULT_SIZE = 12;
export const DEFAULT_COLOR: RGBA = { r: 0.95, g: 0.36, b: 0.33, a: 1 };

export const clamp = (v: number | null, fallback: number, lo: number, hi: number): number =>
  v === null || !Number.isFinite(v) ? fallback : Math.min(Math.max(v, lo), hi);

/** The id of a flow's packet `k`: the flow's id with its last twelve digits standing for `k` (Flow.packetID). */
export function packetID(flow: string, k: number): string {
  const n = (k + 2 ** 40) % 2 ** 48;
  return flow.slice(0, 24) + (n < 0 ? n + 2 ** 48 : n).toString(16).toUpperCase().padStart(12, "0");
}

/** `cost` as routing uses it: 1 for null, kept within 0...1,000,000 (ConnectorData.routeCost). */
export const routeCost = (cost: number | null): number =>
  cost === null || !Number.isFinite(cost) ? 1 : Math.min(Math.max(cost, 0), 1_000_000);

type Edge = { to: string; via: string; back: boolean; cost: number };
/** A network: its shapes, the connectors leaving each in page order, and the trees already grown over it. */
type Graph = { shapes: Set<string>; next: Map<string, Edge[]>; trees: Map<string, FlowTree | null> };
const graphs = new WeakMap<readonly Element[], { members: Element[]; graph: Graph }>();
/** Networks by their shape: frame after frame of an animation usually has the same one, and shares its trees. */
const networks = new Map<string, Graph>();

/** The network traffic in `frame` moves over. Looked up once per frame (checked against the frame's members, so a
 * page changed in place is read anew), and shared by every frame whose shapes and connectors are the same. */
function graphOf(frame: Page): Graph {
  const els = frame.elements;
  const hit = graphs.get(els);
  if (hit && hit.members.length === els.length && hit.members.every((e, i) => e === els[i])) return hit.graph;
  const shapes = new Set(els.filter((e) => e.kind !== "connector").map((e) => e.id));
  // Everything the network is made from: the shapes, and each connector's ends, cost and direction.
  const lines: (string | null)[][] = [];
  for (const e of els) {
    const c = e.connector;
    if (c) lines.push([e.id, c.start.elementID, c.end.elementID, String(routeCost(c.cost)), c.startHead !== "none" ? "both" : "one"]);
  }
  const key = JSON.stringify([[...shapes], lines]);
  let graph = networks.get(key);
  if (!graph) {
    const next = new Map<string, Edge[]>();
    const add = (a: string, edge: Edge) => {
      const list = next.get(a);
      if (list) list.push(edge); else next.set(a, [edge]);
    };
    for (const e of els) {
      const c = e.connector;
      const a = c?.start.elementID ?? null, b = c?.end.elementID ?? null;
      if (!c || a === null || b === null || a === b || !shapes.has(a) || !shapes.has(b)) continue;
      const cost = routeCost(c.cost);
      add(a, { to: b, via: e.id, back: false, cost });
      if (c.startHead !== "none") add(b, { to: a, via: e.id, back: true, cost });
    }
    graph = { shapes, next, trees: new Map() };
    if (networks.size >= 16) networks.clear();
    networks.set(key, graph);
  }
  graphs.set(els, { members: [...els], graph });
  return graph;
}

/** Shapes waiting to be settled, cheapest first, ties to the one reached first (a binary heap). */
class Frontier {
  private heap: { id: string; dist: number; order: number }[] = [];
  get size(): number { return this.heap.length; }
  private less(i: number, j: number): boolean {
    const a = this.heap[i], b = this.heap[j];
    return a.dist < b.dist || (a.dist === b.dist && a.order < b.order);
  }
  private swap(i: number, j: number): void { [this.heap[i], this.heap[j]] = [this.heap[j], this.heap[i]]; }
  push(id: string, dist: number, order: number): void {
    this.heap.push({ id, dist, order });
    for (let i = this.heap.length - 1; i > 0;) {
      const up = (i - 1) >> 1;
      if (!this.less(i, up)) break;
      this.swap(i, up); i = up;
    }
  }
  pop(): { id: string; dist: number; order: number } {
    const top = this.heap[0], last = this.heap.pop()!;
    if (this.heap.length > 0) {
      this.heap[0] = last;
      for (let i = 0; ;) {
        const l = 2 * i + 1, r = l + 1;
        let m = i;
        if (l < this.heap.length && this.less(l, m)) m = l;
        if (r < this.heap.length && this.less(r, m)) m = r;
        if (m === i) break;
        this.swap(i, m); i = m;
      }
    }
    return top;
  }
}

/** Every shape traffic from `from` can reach in `frame`, with the cheapest way to each:
 * by the connectors' cost (1 each unless set), ties to the shape reached first, earlier connectors first.
 * With `until`, the search stops once that shape is settled: its way is final then, and it is the first goal of any
 * list it heads, but the tree holds only the shapes settled before it. */
export function flowTree(from: string, frame: Page, offline: Set<string> = new Set(), until?: string): FlowTree | null {
  const graph = graphOf(frame);
  // A tree depends only on the network, where it starts and stops, and what is offline.
  const key = JSON.stringify([from, until ?? null, [...offline].sort()]);
  if (graph.trees.has(key)) return graph.trees.get(key)!;
  const tree = grow(graph, from, offline, until);
  if (graph.trees.size >= 4096) graph.trees.clear();
  graph.trees.set(key, tree);
  return tree;
}

function grow({ shapes, next }: Graph, from: string, offline: Set<string>, until: string | undefined): FlowTree | null {
  if (!shapes.has(from) || offline.has(from)) return null;
  // Dijkstra, settling the cheapest shape next, ties to the one reached first. A shape reached again more cheaply
  // is queued again under its new order; the entry it leaves behind is passed over.
  const dist = new Map<string, number>([[from, 0]]), order = new Map<string, number>([[from, 0]]);
  let counter = 1;
  const tree = new FlowTree(from);
  const open = new Frontier();
  open.push(from, 0, 0);
  while (open.size > 0) {
    const { id: n, order: o } = open.pop();
    if (tree.settled.has(n) || order.get(n) !== o) continue;
    tree.settled.add(n);
    if (n === until && n !== from) break;
    for (const edge of next.get(n) ?? []) {
      if (offline.has(edge.via) || offline.has(edge.to)) continue;
      if (tree.settled.has(edge.to)) continue;
      const d = dist.get(n)! + edge.cost;
      const old = dist.get(edge.to);
      if (old !== undefined && old <= d) continue;
      dist.set(edge.to, d); order.set(edge.to, counter);
      open.push(edge.to, d, counter++);
      tree.came.set(edge.to, { from: n, via: edge.via, back: edge.back });
    }
  }
  return tree;
}

export class FlowTree {
  settled = new Set<string>();
  came = new Map<string, { from: string; via: string; back: boolean }>();
  readonly from: string;
  constructor(from: string) { this.from = from; }

  /** The first of `to` that can be reached; with `spread`, when the first can't be, every other one that can. */
  goals(to: string[], spread: boolean): string[] {
    const reachable = to.filter((x) => x !== this.from && this.settled.has(x));
    if (reachable.length === 0) return [];
    return spread && reachable[0] !== to[0] ? reachable : [reachable[0]];
  }

  /** The connectors to `goal`, as [connector, backwards] hops. */
  hops(goal: string): [string, boolean][] {
    const hops: [string, boolean][] = [];
    for (let at = goal, step = this.came.get(at); step; at = step.from, step = this.came.get(at)) hops.push([step.via, step.back]);
    return hops.reverse();
  }
}

/** The connectors traffic takes from `from` to the first of `to` it reaches in `frame`, as [connector, backwards]
 * hops; null when none can be reached. */
export function flowRoute(from: string, to: string[], frame: Page, offline: Set<string> = new Set()): [string, boolean][] | null {
  const tree = flowTree(from, frame, offline);
  const goal = tree?.goals(to, false)[0];
  return tree && goal !== undefined ? tree.hops(goal) : null;
}
