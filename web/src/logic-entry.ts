// The click-logic engine as a script of its own (dist/dottie-logic.min.js): <dottie-player> loads it only for a page
// with logic it may run, and Dottie runs it in JavaScriptCore (LogicEngine.swift). Data crosses as JSON text.

import { loadLogic, logicReady, runLogic, type ClickEvent } from "./logic.ts";
import type { Var } from "./expression.ts";

interface Request { source: string; handler: string; state: Record<string, Var>; event: ClickEvent }

const api = {
  /** Starts loading the engine; `ready()` says when it has. */
  load(): void { loadLogic().catch(() => undefined); },
  ready: logicReady,
  /** One click's handler, as JSON text in and out. */
  run(request: string): string {
    const r = JSON.parse(request) as Request;
    return JSON.stringify(runLogic(r.source, r.handler, r.state, r.event));
  },
  loadLogic, runLogic,
};

(globalThis as { DottieLogic?: typeof api }).DottieLogic = api;
