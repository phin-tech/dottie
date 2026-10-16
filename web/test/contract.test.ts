// The geometry contract: for every fixture, dottie.js resolves each page at the golden times to exactly what
// `dottie inspect` printed (within a hair of floating point). Regenerate goldens with `just goldens`.

import assert from "node:assert/strict";
import { test } from "node:test";
import { inspectPage } from "../src/inspect.ts";
import { parseDottie } from "../src/model.ts";
import { diff, fixtures, read } from "./helpers.ts";

for (const [group, name] of fixtures()) {
  test(`contract: ${group}/${name}`, () => {
    const file = parseDottie(read(group, `${name}.dottie`));
    const golden = JSON.parse(read("goldens", group, `${name}.json`)) as { pages: { frames: { t: number }[] }[] };
    golden.pages.forEach((page, i) => {
      const times = page.frames.map((f) => f.t);
      const mine = inspectPage(file.pages[i], i, times);
      const problems = diff(page, mine, 2e-3, `page ${i + 1}`);
      assert.deepEqual(problems, [], `${group}/${name}:\n  ${problems.join("\n  ")}`);
    });
  });
}
