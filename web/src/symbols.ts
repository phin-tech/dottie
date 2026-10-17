// Symbols (Symbols.swift): instances expanded into their symbol's elements as they are at a moment, placed in the
// instance's frame. Ids, seeds and geometry match DottieKit's exactly.

import { endpoints, indexOf } from "./connector.ts";
import { angle } from "./element.ts";
import { type Element, type Endpoint, type Page, type Symbol, type SymbolPlayback, clampTime, cloneElement, orderedElements } from "./model.ts";
import { rotate } from "./path.ts";
import { boiled } from "./rng.ts";
import { posed } from "./timeline.ts";

/** The deepest instances nest, and the most elements expanding one page may make (Symbol.maxDepth, .maxElements). */
export const MAX_DEPTH = 8;
export const MAX_ELEMENTS = 20_000;
const EPSILON = 1e-9;

export type ButtonState = "up" | "over" | "down" | "hit";

/** The moment of the symbol's scene named `state`, any case, within its timeline (Symbol.sceneTime). */
export function sceneTime(s: Symbol, state: ButtonState): number | null {
  const m = (s.timeline?.markers ?? []).find((x) => x.name.toLowerCase() === state);
  return m ? Math.min(Math.max(m.t, 0), clampTime(s.timeline?.duration ?? 0)) : null;
}

/** Where a button is in each state (Symbol.buttonTime): over falls back to up, down to over; hit to nothing. */
export function buttonTime(s: Symbol, state: ButtonState): number | null {
  switch (state) {
    case "up": return sceneTime(s, "up") ?? 0;
    case "over": return sceneTime(s, "over") ?? buttonTime(s, "up");
    case "down": return sceneTime(s, "down") ?? buttonTime(s, "over");
    default: return sceneTime(s, "hit");
  }
}

/** Where an instance is in its symbol's timeline at page time `t` (Symbol.localTime). */
export function symbolTime(s: Symbol, t: number, playback: SymbolPlayback | null, offset: number | null): number {
  const d = clampTime(s.timeline?.duration ?? 0);
  if (s.button === true) return buttonTime(s, "up") ?? 0;
  const o = offset !== null && Number.isFinite(offset) ? offset : 0;
  switch (playback ?? "loop") {
    case "still": return Math.min(s.timeline?.poster ?? d, d);
    case "click": return Math.min(Math.max(o, 0), d);
    case "once": return Math.min(Math.max(t + o, 0), d);
    default: {
      if (d <= 0) return 0;
      const x = t + o;
      let r = x % d;
      if (r < 0) r += d;
      if (x > EPSILON && (r < EPSILON || d - r < EPSILON)) return d;
      return r;
    }
  }
}

/** The symbol as a page of its own (Symbol.page). */
export function symbolPage(s: Symbol): Page {
  return { id: s.id, name: s.name, layers: s.layers, elements: s.elements, theme: null, timeline: s.timeline, symbols: null };
}

export function hasInstances(page: Page): boolean {
  return page.elements.some((e) => e.kind === "symbol");
}

/** The page with every instance replaced by what it shows at page time `t` (DottieDocument.expandingSymbols). `times`
 * puts instances on the page at a moment of their symbol's own: a button's other states, or a clip replaying. */
export function expandingSymbols(page: Page, t: number, posing = true, times: Map<string, number> = new Map()): Page {
  if (!hasInstances(page)) return page;
  const budget = { left: MAX_ELEMENTS };
  return { ...page, elements: expand(page.elements, page, t, symbolTable(page), [], posing, budget, times) };
}

export function symbolTable(page: Page): Map<string, Symbol> {
  const table = new Map<string, Symbol>();
  for (const s of page.symbols ?? []) if (!table.has(s.id)) table.set(s.id, s);
  return table;
}

function expand(elements: Element[], page: Page, t: number, table: Map<string, Symbol>, stack: string[], posing: boolean,
  budget: { left: number }, times: Map<string, number> = new Map()): Element[] {
  const instances = new Set(elements.filter((e) => e.kind === "symbol").map((e) => e.id));
  if (instances.size === 0) { budget.left -= elements.length; return elements; }
  const index = indexOf(page);
  const out: Element[] = [];
  for (const e of elements) {
    if (budget.left <= 0) break;
    const c = e.connector;
    if (e.kind === "connector" && c && [c.start.elementID, c.end.elementID].some((id) => id !== null && instances.has(id))) {
      const [a, b] = endpoints(e, index);
      const pinned = cloneElement(e);
      if (c.start.elementID !== null && instances.has(c.start.elementID)) pinned.connector!.start = { elementID: null, port: c.start.port, x: a.x, y: a.y };
      if (c.end.elementID !== null && instances.has(c.end.elementID)) pinned.connector!.end = { elementID: null, port: c.end.port, x: b.x, y: b.y };
      out.push(pinned);
      budget.left -= 1;
      continue;
    }
    if (e.kind !== "symbol") { out.push(e); budget.left -= 1; continue; }
    budget.left -= 1;
    const id = e.symbol;
    const symbol = id === null ? undefined : table.get(id);
    if (id === null || !symbol || stack.includes(id) || stack.length >= MAX_DEPTH) continue;
    const override = stack.length === 0 ? times.get(e.id) : undefined;
    const u = override !== undefined ? Math.min(Math.max(override, 0), clampTime(symbol.timeline?.duration ?? 0))
      : symbolTime(symbol, t, e.playback, e.offset);
    const inner = posing ? posed(symbolPage(symbol), u) : symbolPage(symbol);
    const visible = new Set(inner.layers.filter((l) => l.visible).map((l) => l.id));
    const drawn: Page = { ...inner, elements: orderedElements(inner).filter((x) => visible.has(x.layerID)),
      layers: [{ id: e.layerID, name: "", visible: true, locked: false }] };
    for (const x of expand(drawn.elements, drawn, u, table, [...stack, id], posing, budget)) out.push(placed(x, e, symbol));
  }
  return out;
}

/** An element of `symbol` as it appears in `instance`: scaled into its frame, then turned with it. */
function placed(inner: Element, instance: Element, symbol: Symbol): Element {
  const f = { x: instance.x, y: instance.y, width: instance.width, height: instance.height };
  const sx = f.width / symbol.width, sy = f.height / symbol.height;
  const s = Math.sqrt(Math.abs(sx * sy));
  const center = { x: f.x + f.width / 2, y: f.y + f.height / 2 };
  const a = angle(instance);
  const point = (p: { x: number; y: number }) => rotate({ x: f.x + p.x * sx, y: f.y + p.y * sy }, center, a);
  const e = cloneElement(inner);
  e.id = derivedID(instance.id, inner.id);
  e.layerID = instance.layerID;
  e.groupID = null;
  e.link = inner.link === null ? null : derivedID(instance.id, inner.link);
  e.seed = boiled(inner.seed, instance.seed);
  e.click = null; e.hover = null;
  const scaled = { x: f.x + inner.x * sx, y: f.y + inner.y * sy, width: inner.width * sx, height: inner.height * sy };
  const moved = rotate({ x: scaled.x + scaled.width / 2, y: scaled.y + scaled.height / 2 }, center, a);
  e.x = moved.x - scaled.width / 2; e.y = moved.y - scaled.height / 2;
  e.width = scaled.width; e.height = scaled.height;
  if (a !== 0 || inner.rotation !== null) e.rotation = angle(inner) + a;
  e.style.strokeWidth = inner.style.strokeWidth * s;
  e.style.fontSize = inner.style.fontSize * s;
  if (inner.style.gridSize !== null) e.style.gridSize = inner.style.gridSize * s;
  if (instance.style.opacity !== null) e.style.opacity = (inner.style.opacity ?? 1) * instance.style.opacity;
  if (inner.connector) {
    const end = (p: Endpoint): Endpoint => {
      if (p.elementID !== null) return { elementID: derivedID(instance.id, p.elementID), port: p.port, x: p.x, y: p.y };
      const q = point(p);
      return { elementID: null, port: p.port, x: q.x, y: q.y };
    };
    e.connector = { ...inner.connector, start: end(inner.connector.start), end: end(inner.connector.end) };
  }
  return e;
}

const MASK = (1n << 64n) - 1n;

function mix(x: bigint): bigint {
  let z = (x + 0x9e3779b97f4a7c15n) & MASK;
  z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK;
  z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK;
  return z ^ (z >> 31n);
}

function halves(id: string): [bigint, bigint] {
  const hex = id.replace(/-/g, "").padStart(32, "0").slice(-32);
  return [BigInt(`0x${hex.slice(0, 16)}`), BigInt(`0x${hex.slice(16)}`)];
}

/** The id an element of a symbol has inside instance `instance` (DottieDocument.derivedID). */
export function derivedID(instance: string, inner: string): string {
  const [a, b] = halves(instance), [c, d] = halves(inner);
  const hi = mix(mix(mix(mix(a) ^ b) ^ c) ^ d);
  const lo = mix(hi ^ 0x6a09e667f3bcc909n);
  const h = hi.toString(16).padStart(16, "0") + lo.toString(16).padStart(16, "0");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`.toUpperCase();
}
