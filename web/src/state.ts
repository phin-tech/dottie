// Page state (State.swift): named true-or-false variables that clicks set and flip, and conditions (`when`) that
// pick which elements a page draws, so a looping diagram can change without its timeline stopping or jumping.

import type { ClickAction, Page } from "./model.ts";

const MAX_NAME = 64;

/** Whether `name` can name a variable: a letter or underscore, then letters, digits and underscores. */
export function isName(name: string): boolean {
  return name.length <= MAX_NAME && /^[A-Za-z_][A-Za-z0-9_]*$/.test(name);
}

/** The variable names `condition` reads, or null when it isn't one: names, each optionally after `!`, joined by
 * `&&` and `||` (`&&` binds tighter). */
export function conditionNames(condition: string): string[] | null {
  const out: string[] = [];
  for (const any of condition.split("||")) {
    for (const all of any.split("&&")) {
      let term = trim(all);
      if (term.startsWith("!")) term = trim(term.slice(1));
      if (!isName(term)) return null;
      out.push(term);
    }
  }
  return out;
}

/** Whether `condition` holds with these values. A missing variable is false; a condition that can't be read never
 * holds. */
export function holds(condition: string, state: Record<string, boolean>): boolean {
  if (conditionNames(condition) === null) return false;
  return condition.split("||").some((any) => any.split("&&").every((all) => {
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
