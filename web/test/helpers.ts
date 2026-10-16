import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
export const FIXTURES = join(ROOT, "fixtures");

/** Every fixture that has goldens: [group, name]. */
export function fixtures(): [string, string][] {
  const out: [string, string][] = [];
  for (const group of ["design", "edge"]) {
    for (const f of readdirSync(join(FIXTURES, group)).sort()) if (f.endsWith(".dottie")) out.push([group, f.slice(0, -7)]);
  }
  return out;
}

export const read = (...parts: string[]): string => readFileSync(join(FIXTURES, ...parts), "utf8");

/** Differences between two JSON values, numbers compared within `tol`, as "path: expected vs actual". */
export function diff(expected: unknown, actual: unknown, tol: number, path = "", out: string[] = [], limit = 20): string[] {
  if (out.length >= limit) return out;
  if (typeof expected === "number" && typeof actual === "number") {
    if (!(Math.abs(expected - actual) <= tol)) out.push(`${path}: ${expected} vs ${actual}`);
  } else if (Array.isArray(expected) && Array.isArray(actual)) {
    if (expected.length !== actual.length) out.push(`${path}: length ${expected.length} vs ${actual.length}`);
    else expected.forEach((e, i) => diff(e, actual[i], tol, `${path}[${i}]`, out, limit));
  } else if (expected && actual && typeof expected === "object" && typeof actual === "object") {
    const keys = new Set([...Object.keys(expected), ...Object.keys(actual)]);
    for (const k of [...keys].sort()) {
      const e = (expected as Record<string, unknown>)[k], a = (actual as Record<string, unknown>)[k];
      if (e === undefined) out.push(`${path}.${k}: missing in golden (dottie.js has ${JSON.stringify(a)})`);
      else if (a === undefined) out.push(`${path}.${k}: missing in dottie.js (golden has ${JSON.stringify(e)})`);
      else diff(e, a, tol, `${path}.${k}`, out, limit);
    }
  } else if (expected !== actual) {
    out.push(`${path}: ${JSON.stringify(expected)} vs ${JSON.stringify(actual)}`);
  }
  return out;
}
