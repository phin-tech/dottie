// The visual reference, compared as text: for every fixture page and moment in fixtures/goldens/svg, dottie.js
// writes the same SVG Dottie's own export wrote, sketchy strokes included (the same seeds draw the same lines).
// Numbers may differ by a rounding step.

import assert from "node:assert/strict";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { type Page, parseDottie } from "../src/model.ts";
import { svg } from "../src/svg.ts";
import { resolved } from "../src/timeline.ts";
import { FIXTURES, read } from "./helpers.ts";

export function withRoughness(page: Page, roughness: number): Page {
  return { ...page, elements: page.elements.map((e) => ({ ...e, style: { ...e.style, roughness } })) };
}

/** Line-by-line differences, numbers compared within `tol`. */
export function svgDiff(expected: string, actual: string, tol = 0.011, limit = 8): string[] {
  const a = expected.split("\n"), b = actual.split("\n");
  const out: string[] = [];
  const num = /-?\d+(?:\.\d+)?(?:e[-+]?\d+)?/g;
  for (let i = 0; i < Math.max(a.length, b.length) && out.length < limit; i++) {
    const x = a[i] ?? "", y = b[i] ?? "";
    if (x === y) continue;
    const xs = x.split(num), ys = y.split(num);
    const xn = x.match(num) ?? [], yn = y.match(num) ?? [];
    const same = xs.length === ys.length && xs.every((s, k) => s === ys[k]) && xn.every((n, k) => Math.abs(Number(n) - Number(yn[k])) <= tol);
    if (!same) out.push(`line ${i + 1}:\n    dottie:    ${x.slice(0, 300)}\n    dottie.js: ${y.slice(0, 300)}`);
  }
  return out;
}

for (const group of ["design", "edge"]) {
  const dir = join(FIXTURES, "goldens", "svg", group);
  for (const f of readdirSync(dir).sort()) {
    const m = /^(.+)-p(\d+)-t([\d.]+)-(clean|sketchy)\.svg$/.exec(f);
    if (!m) continue;
    const [, name, page, t, look] = m;
    test(`svg: ${group}/${f}`, () => {
      const file = parseDottie(read(group, `${name}.dottie`));
      let p = resolved(file.pages[Number(page) - 1], Number(t));
      if (look === "clean") p = withRoughness(p, 0);
      // Dottie's export embeds the bundled fonts it uses on a line of their own; dottie.js's player serves them.
      const expected = read("goldens", "svg", group, f).split("\n").filter((l) => !l.startsWith("<defs><style>@font-face")).join("\n");
      const problems = svgDiff(expected, svg(p));
      assert.deepEqual(problems, [], `${group}/${f}:\n  ${problems.join("\n  ")}`);
    });
  }
}
