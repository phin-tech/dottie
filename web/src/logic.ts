// A page's click logic (ADR 0007, step 2): JavaScript handlers a click can `run`, each run in a fresh QuickJS
// context compiled to WebAssembly, never in the page's own JavaScript. A handler gets the variables and the click
// and returns new variable values. It has a memory and an operation budget, and nothing that varies: no clock, no
// randomness, no timers, no network, no DOM. The same click on the same state gives the same result in every browser
// and in Dottie, which runs this file in JavaScriptCore (LogicEngine.swift).

import { newQuickJSWASMModuleFromVariant, type QuickJSWASMModule } from "quickjs-emscripten-core";
import variant from "@jitl/quickjs-singlefile-browser-release-sync";
import type { Var } from "./expression.ts";
import { polyfill } from "./logic-polyfill.ts";

/** What a handler is told about the click. */
export interface ClickEvent {
  /** The clicked element's id, anchor and first line of text. */
  id: string;
  anchor: string | null;
  text: string | null;
  /** Seconds into the page's timeline, and the scene playing. */
  time: number;
  scene: string | null;
}

/** New variable values, or why there are none (the state then stays as it was). */
export type LogicResult = { ok: true; set: Record<string, Var> } | { ok: false; error: string };

/** How much a handler may do: QuickJS checks in every 10,000 or so operations, and this many check-ins is the
 * limit (a few million operations, well under a second). */
export const OPERATION_BUDGET = 400;
/** How much memory a handler may use. */
export const MEMORY_LIMIT = 16 * 1024 * 1024;
/** Longest logic a page may have, in characters. */
export const MAX_SOURCE = 64 * 1024;

const NAME = /^[A-Za-z_][A-Za-z0-9_]{0,63}$/;

// What the sandbox starts without: the things that vary from run to run.
const SEAL = "delete globalThis.Date; Math.random = undefined; delete Math.random;\n";

let loading: Promise<QuickJSWASMModule> | null = null;
let engine: QuickJSWASMModule | null = null;

/** Loads the engine (once). */
export function loadLogic(): Promise<void> {
  polyfill();
  loading ??= newQuickJSWASMModuleFromVariant(variant).then((m) => { engine = m; return m; });
  return loading.then(() => undefined);
}

/** Whether the engine is loaded, so `runLogic` can be called. */
export function logicReady(): boolean { return engine !== null; }

/** Runs `handler` from `source` for a click; the engine must be loaded. */
export function runLogic(source: string, handler: string, state: Record<string, Var>, event: ClickEvent): LogicResult {
  if (!engine) return { ok: false, error: "The logic engine isn't loaded" };
  if (!NAME.test(handler)) return { ok: false, error: `'${handler}' can't name a handler` };
  if (source.length > MAX_SOURCE) return { ok: false, error: `The page's logic is longer than ${MAX_SOURCE} characters` };
  const rt = engine.newRuntime();
  rt.setMemoryLimit(MEMORY_LIMIT);
  rt.setMaxStackSize(512 * 1024);
  let ticks = 0;
  rt.setInterruptHandler(() => ++ticks > OPERATION_BUDGET);
  const vm = rt.newContext();
  try {
    const call = `\n;(function () {\n  if (typeof ${handler} !== "function") throw new Error("No handler called ${handler}");\n`
      + `  const out = ${handler}(${JSON.stringify(state)}, ${JSON.stringify(event)});\n`
      + `  return JSON.stringify(out === undefined ? {} : out);\n})()`;
    const r = vm.evalCode(SEAL + source + call, "logic.js");
    if (r.error) {
      const e = vm.dump(r.error) as { name?: string; message?: string } | string;
      r.error.dispose();
      if (ticks > OPERATION_BUDGET) return { ok: false, error: `${handler} ran too long` };
      return { ok: false, error: typeof e === "string" ? e : `${e?.name ?? "Error"}: ${e?.message ?? ""}`.trim() };
    }
    const text = vm.dump(r.value);
    r.value.dispose();
    return checked(handler, typeof text === "string" ? text : "null");
  } catch (e) {
    // Out of memory and the like surface here.
    return { ok: false, error: `${handler} failed: ${(e as Error).message}` };
  } finally {
    vm.dispose();
    rt.dispose();
  }
}

/** A handler's answer as new variable values: an object of names to true, false or finite numbers. */
function checked(handler: string, text: string): LogicResult {
  let v: unknown;
  try { v = JSON.parse(text); } catch { return { ok: false, error: `${handler} returned something that isn't values` }; }
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    return { ok: false, error: `${handler} must return an object of variable values, like {count: 3}` };
  }
  const set: Record<string, Var> = {};
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
    if (!NAME.test(k)) return { ok: false, error: `${handler} returned '${k}', which can't name a variable` };
    if (typeof x === "boolean" || (typeof x === "number" && Number.isFinite(x))) set[k] = x;
    else return { ok: false, error: `${handler} returned ${k}: ${JSON.stringify(x)}; values are true, false or finite numbers` };
  }
  return { ok: true, set };
}
