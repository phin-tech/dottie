// Page state (State.swift): named true-or-false variables that clicks set and flip, and conditions (`when`) that
// pick which elements a page draws, so a looping diagram can change without its timeline stopping or jumping.

import { cloneElement, type ClickAction, type Element, type Page, type StateOverride } from "./model.ts";

const MAX_NAME = 64;

/** Whether `name` can name a variable: a letter or underscore, then letters, digits and underscores. */
export function isName(name: string): boolean {
  return name.length <= MAX_NAME && /^[A-Za-z_][A-Za-z0-9_]*$/.test(name);
}

/** The metrics a condition can compare (ADR 0003), as `load(workers) > 0.9`. */
export const METRIC_NAMES = ["throughput", "load", "delay", "backlog", "inFlight", "transit", "backup"];

/** A comparison of a metric in a condition (PageState.MetricTerm). */
export interface MetricTerm { metric: string; target: string; op: string; value: number }

const OPS = [">=", "<=", "==", "!=", ">", "<"];

/** `term` (trimmed) read as a metric comparison, or null. */
export function metricTerm(term: string): MetricTerm | null {
  const t = trim(term);
  const open = t.indexOf("("), close = t.indexOf(")");
  if (open < 0 || close < 0 || open >= close) return null;
  const name = trim(t.slice(0, open)), target = trim(t.slice(open + 1, close));
  let rest = trim(t.slice(close + 1));
  if (!METRIC_NAMES.includes(name) || target === "" || target.includes("(")) return null;
  const op = OPS.find((o) => rest.startsWith(o));
  if (op === undefined) return null;
  rest = trim(rest.slice(op.length));
  if (!/^-?[0-9]+(\.[0-9]+)?$/.test(rest)) return null;
  return { metric: name, target, op, value: Number(rest) };
}

function passes(m: MetricTerm, v: number): boolean {
  switch (m.op) {
    case ">": return v > m.value;
    case ">=": return v >= m.value;
    case "<": return v < m.value;
    case "<=": return v <= m.value;
    case "==": return v === m.value;
    default: return v !== m.value;
  }
}

/** Whether `condition` compares a metric anywhere. */
export function mentionsMetric(condition: string): boolean {
  return condition.split("||").some((any) => any.split("&&").some((all) => metricTerm(all) !== null));
}

/** The variable names `condition` reads, or null when it isn't one: names, each optionally after `!`, or metric
 * comparisons, joined by `&&` and `||` (`&&` binds tighter). */
export function conditionNames(condition: string): string[] | null {
  const out: string[] = [];
  for (const any of condition.split("||")) {
    for (const all of any.split("&&")) {
      if (metricTerm(all) !== null) continue;
      let term = trim(all);
      if (term.startsWith("!")) term = trim(term.slice(1));
      if (!isName(term)) return null;
      out.push(term);
    }
  }
  return out;
}

/** Whether `condition` holds with these values, and `metric` giving the frame's metrics. A missing variable is
 * false, and so is a comparison whose metric can't be had; a condition that can't be read never holds. */
export function holds(condition: string, state: Record<string, boolean>,
  metric: ((m: MetricTerm) => number | null) | null = null): boolean {
  if (conditionNames(condition) === null) return false;
  return condition.split("||").some((any) => any.split("&&").every((all) => {
    const m = metricTerm(all);
    if (m !== null) {
      const v = metric ? metric(m) : null;
      return v !== null && passes(m, v);
    }
    let term = trim(all);
    let negated = false;
    if (term.startsWith("!")) { negated = true; term = trim(term.slice(1)); }
    return (state[term] ?? false) !== negated;
  }));
}

/** Which elements a page shows as far as its variables go: their starting values ("initial"), these values (a
 * missing one takes its starting value), or every element ("all"). */
export type StateChoice = "initial" | "all" | Record<string, boolean>;

/** The values `choice` gives each variable; null for "all". */
export function stateValues(page: Page, choice: StateChoice): Record<string, boolean> | null {
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
export function activeOverrides(e: Element, values: Record<string, boolean> | null): StateOverride[] {
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
  return !!c && (Object.keys(c.set ?? {}).length > 0 || (c.toggle ?? []).length > 0);
}

/** `state` after the click: its `set` values, then each `toggle` flipped (a missing variable starts false). */
export function applyClick(c: ClickAction, state: Record<string, boolean>): Record<string, boolean> {
  const out = { ...state };
  for (const [k, v] of Object.entries(c.set ?? {})) out[k] = v;
  for (const k of c.toggle ?? []) out[k] = !(out[k] ?? false);
  return out;
}

/** Swift's `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not newlines. */
function trim(s: string): string {
  return s.replace(/^[ \t ]+|[ \t ]+$/g, "");
}
