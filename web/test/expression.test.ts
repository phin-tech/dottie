// ADR 0007's expression language against fixtures/expressions.json, which ExpressionTests.swift checks too, so
// dottie.js and Dottie agree on every value.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { evaluate, parseExpr, type Var } from "../src/expression.ts";
import { applyClick, conditionNames, holds, metricTerm } from "../src/state.ts";

const table = JSON.parse(readFileSync(new URL("../../fixtures/expressions.json", import.meta.url), "utf8")) as {
  cases: { expr: string; state: Record<string, Var>; value: Var }[];
  invalid: string[];
  metrics: { expr: string; state: Record<string, Var>; metrics: Record<string, number>; value: Var }[];
};

test("the shared table", () => {
  assert.ok(table.cases.length > 40);
  for (const c of table.cases) {
    const e = parseExpr(c.expr);
    assert.ok(e, c.expr);
    assert.equal(evaluate(e, c.state), c.value, c.expr);
  }
  for (const s of table.invalid) assert.equal(parseExpr(s), null, s);
  for (const c of table.metrics) {
    const e = parseExpr(c.expr)!;
    assert.equal(evaluate(e, c.state, (m, t) => c.metrics[`${m}(${t})`] ?? null), c.value, c.expr);
  }
});

test("old conditions mean what they did", () => {
  assert.equal(holds("east && !west || down", { down: true, east: false }), true);
  assert.deepEqual(conditionNames("east && !west || maint"), ["east", "west", "maint"]);
  assert.deepEqual(metricTerm("load(workers) >= 0.9"), { metric: "load", target: "workers", op: ">=", value: 0.9 });
  assert.equal(metricTerm("load < -1")?.value, -1);
  assert.equal(conditionNames("down &&"), null);
});

test("clicks compute from the state before", () => {
  const click = { scene: null, url: null, set: { count: "count + 1", stage: "(stage + 1) % 3", seen: true }, toggle: ["open"] };
  let state: Record<string, Var> = { count: 0, stage: 2 };
  for (let i = 0; i < 3; i++) state = applyClick(click, state);
  assert.deepEqual(state, { count: 3, stage: 2, seen: true, open: true });
  assert.deepEqual(applyClick({ scene: null, url: null, set: { a: "b", b: "a" }, toggle: null }, { a: 1, b: 2 }), { a: 2, b: 1 });
  assert.deepEqual(applyClick({ scene: null, url: null, set: { count: "count + 1" }, toggle: null, reset: true }, { count: 9 }, { count: 0 }),
    { count: 1 });
});
