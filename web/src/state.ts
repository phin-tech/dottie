// Page state (State.swift): named true-or-false variables that clicks set and flip, and conditions (`when`) that
// pick which elements a page draws, so a looping diagram can change without its timeline stopping or jumping.

import { evaluate, exprMetrics, exprNames, parseExpr, truthy, type Var } from "./expression.ts";
import { cloneElement, type ClickAction, type ClickValue, type Element, type Page, type StateOverride } from "./model.ts";

const MAX_NAME = 64;

/** Whether `name` can name a variable: a letter or underscore, then letters, digits and underscores. */
export function isName(name: string): boolean {
  return name.length <= MAX_NAME && /^[A-Za-z_][A-Za-z0-9_]*$/.test(name);
}

export { METRIC_NAMES } from "./expression.ts";

/** A comparison of a metric in a condition (PageState.MetricTerm). */
export interface MetricTerm { metric: string; target: string; op: string; value: number }

/** `term` read as one metric comparison, `metric(target) op number`, or null. */
export function metricTerm(term: string): MetricTerm | null {
  const e = parseExpr(term);
  if (!e || e.k !== "bin" || e.l.k !== "metric" || !["<", "<=", ">", ">=", "==", "!="].includes(e.op)) return null;
  const r = e.r;
  const value = r.k === "lit" && typeof r.v === "number" ? r.v
    : r.k === "neg" && r.e.k === "lit" && typeof r.e.v === "number" ? -r.e.v : null;
  return value === null ? null : { metric: e.l.metric, target: e.l.target, op: e.op, value };
}

/** Whether `condition` reads a metric anywhere. */
export function mentionsMetric(condition: string): boolean {
  const e = parseExpr(condition);
  return e !== null && exprMetrics(e).length > 0;
}

/** The variable names `condition` reads, or null when it isn't one (ADR 0007's expressions). */
export function conditionNames(condition: string): string[] | null {
  const e = parseExpr(condition);
  return e ? exprNames(e) : null;
}

/** Whether `condition` holds with these values, and `metric` giving the frame's metrics. A missing variable is
 * false, and a comparison with a metric that can't be had fails; a condition that can't be read never holds. */
export function holds(condition: string, state: Record<string, Var>,
  metric: ((m: MetricTerm) => number | null) | null = null): boolean {
  const e = parseExpr(condition);
  if (!e) return false;
  return truthy(evaluate(e, state, metric ? (m, target) => metric({ metric: m, target, op: "", value: 0 }) : null));
}

/** Which elements a page shows as far as its variables go: their starting values ("initial"), these values (a
 * missing one takes its starting value), or every element ("all"). */
export type StateChoice = "initial" | "all" | Record<string, Var>;

/** The values `choice` gives each variable; null for "all". */
export function stateValues(page: Page, choice: StateChoice): Record<string, Var> | null {
  if (choice === "all") return null;
  if (choice === "initial") return { ...(page.variables ?? {}) };
  return { ...(page.variables ?? {}), ...choice };
}

/** The ids of the elements whose `when` doesn't hold under `choice`. */
export function stateHidden(page: Page, choice: StateChoice): Set<string> {
  const values = stateValues(page, choice);
  const out = new Set<string>();
  if (!values) return out;
  for (const e of page.elements) if (e.when !== null && !holds(e.when, values)) out.add(e.id);
  return out;
}

/** The overrides of `e` that hold under `values`, in order; none for null ("all", the editor). */
export function activeOverrides(e: Element, values: Record<string, Var> | null): StateOverride[] {
  if (!values || !e.overrides) return [];
  return e.overrides.filter((o) => !mentionsMetric(o.when) && holds(o.when, values));
}

/** Only what an override comparing metrics may change: its looks (ADR 0003). */
export function looksOnly(o: StateOverride): StateOverride {
  return { ...o, reroute: null, offline: null, cost: null, capacity: null, delay: null };
}

/** `e` with `o` applied (StateOverride.apply): opacity multiplies, the rest replaces. */
export function applyOverride(o: StateOverride, e: Element): Element {
  const out = cloneElement(e);
  if (o.stroke) out.style.stroke = { ...o.stroke };
  if (o.fill) out.style.fill = { ...o.fill };
  if (o.textColor) out.style.textColor = { ...o.textColor };
  if (o.strokeWidth !== null) out.style.strokeWidth = Math.max(0, o.strokeWidth);
  if (o.dash !== null) out.style.dash = o.dash;
  if (o.text !== null) out.text = o.text;
  if (o.cost !== null && out.connector) out.connector.cost = Math.min(Math.max(o.cost, 0), 1_000_000);
  if (o.capacity !== null) out.capacity = Math.max(o.capacity, 0);
  if (o.delay !== null && out.kind !== "connector") out.delay = Math.max(o.delay, 0);
  if (o.opacity !== null) {
    const v = Math.min(Math.max(o.opacity, 0), 1) * (out.style.opacity ?? 1);
    out.style.opacity = v >= 1 ? null : v;
  }
  return out;
}

/** Whether a click sets or flips a variable. */
export function changesState(c: ClickAction | null): boolean {
  return !!c && (c.reset === true || Object.keys(c.set ?? {}).length > 0 || (c.toggle ?? []).length > 0 || !!c.run);
}

/** `state` after the click: the starting values (`initial`) back if it resets, then its `set` values, then each
 * `toggle` flipped (a missing variable starts false). */
export function applyClick(c: ClickAction, state: Record<string, Var>, initial: Record<string, Var> = {}): Record<string, Var> {
  let out: Record<string, Var> = { ...state };
  if (c.reset === true) {
    out = {};
    for (const k of Object.keys(state)) out[k] = false;
    Object.assign(out, initial);
  }
  // Expressions are worked out from the state before any of them is given (after a reset).
  const before = { ...out };
  for (const [k, v] of Object.entries(c.set ?? {})) out[k] = clickValue(v, before, before[k]);
  for (const k of c.toggle ?? []) out[k] = !truthy(out[k] ?? false);
  return out;
}

/** A click's value given the state before it (ClickValue.value); an expression that can't be read leaves `current`. */
export function clickValue(v: ClickValue, state: Record<string, Var>, current: Var | undefined): Var {
  if (typeof v !== "string") return v;
  const e = parseExpr(v);
  return e ? evaluate(e, state) : current ?? false;
}

