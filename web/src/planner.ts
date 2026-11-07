// Planning an animation off the page's thread. A player has to know every frame's view before it shows the first
// (svg.ts's plan), and without a camera that means resolving every frame: for a long, busy animation, long enough to
// freeze the page. So <dottie-player> plans a big one in a worker running dottie.js itself, and shows the drawing
// when the plan comes back; the plan is the same one, so what it shows is too. Small drawings, and anywhere a worker
// can't start (no Worker, or a content security policy against it), plan in place as before.

import type { Page } from "./model.ts";
import { type Plan, hasPlan, plan, rememberPlan } from "./svg.ts";
import { frameTimes } from "./timeline.ts";

/** How the build lets this script start a worker of itself (build.mjs): "self" in the classic script, which is
 * wrapped in the function `dottiePlayerScript`; "sibling" in the module player, beside dottie-player.min.js. */
declare const __DOTTIE_WORKER__: string | undefined;
declare const dottiePlayerScript: (() => void) | undefined;

/** Frames times elements below which planning in place is quicker than starting a worker. */
export const WORKER_WORK = 30_000;

/** Roughly how much resolving every frame of `page` takes: none with a camera, which plans without resolving. */
export function planWork(page: Page): number {
  const tl = page.timeline;
  if (!tl || tl.camera?.some((k) => k.width > 1 && k.height > 1)) return 0;
  const elements = page.elements.length + (page.symbols ?? []).reduce((n, s) => n + s.elements.length, 0);
  return frameTimes(tl).length * elements;
}

/** A way to start a worker running this script, or null where there is none. */
function workerMaker(): (() => Worker) | null {
  if (typeof Worker === "undefined" || typeof __DOTTIE_WORKER__ === "undefined") return null;
  if (__DOTTIE_WORKER__ === "self" && typeof dottiePlayerScript === "function") {
    const source = `(${dottiePlayerScript.toString()})();\n`;
    return () => {
      const url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
      try { return new Worker(url); } finally { setTimeout(() => URL.revokeObjectURL(url), 60_000); }
    };
  }
  if (__DOTTIE_WORKER__ === "sibling") {
    const here: string | undefined = import.meta.url;
    if (!here) return null;
    return () => new Worker(new URL("./dottie-player.min.js", here));
  }
  return null;
}

let make: (() => Worker) | null | undefined;
let worker: Worker | null = null;
let failed = false;
let nextID = 1;
const waiting = new Map<number, { page: Page; done: (plan: Plan | null) => void }>();

/** Whether `page` is worth planning in a worker, and one can be had. */
export function plansInWorker(page: Page): boolean {
  if (failed || hasPlan(page) || planWork(page) < WORKER_WORK) return false;
  if (make === undefined) make = workerMaker();
  return make !== null;
}

/** Plans `page` in the worker; when it resolves, `plan(page)` returns that plan at once. On any failure it resolves
 * all the same, and `plan(page)` then plans in place. */
export function planInWorker(page: Page): Promise<void> {
  return new Promise((resolve) => {
    const done = (p: Plan | null) => { if (p) rememberPlan(page, p); resolve(); };
    let w: Worker;
    try { w = worker ?? start(); } catch { failed = true; done(null); return; }
    const id = nextID++;
    waiting.set(id, { page, done });
    try { w.postMessage({ dottiePlan: id, page }); } catch { waiting.delete(id); done(null); }
  });
}

function start(): Worker {
  const w = make!();
  w.onmessage = (ev: MessageEvent) => {
    const { dottiePlan: id, plan: p } = (ev.data ?? {}) as { dottiePlan?: number; plan?: Plan };
    const job = id === undefined ? undefined : waiting.get(id);
    if (!job) return;
    waiting.delete(id!);
    job.done(p ?? null);
    // A worker is a copy of all of dottie.js: let it go once there is nothing left for it to plan.
    if (waiting.size === 0 && worker === w) { w.terminate(); worker = null; }
  };
  // It couldn't load, or broke: everything waiting plans in place, and so does everything after.
  w.onerror = (ev: Event) => {
    ev.preventDefault?.();
    failed = true;
    if (worker === w) worker = null;
    w.terminate();
    const jobs = [...waiting.values()];
    waiting.clear();
    for (const job of jobs) job.done(null);
  };
  worker = w;
  return w;
}

/** In a worker started by `planInWorker`, answers its requests. Elsewhere it does nothing. */
export function servePlans(): void {
  const g = globalThis as unknown as { WorkerGlobalScope?: new () => unknown; addEventListener?: (t: string, f: (ev: MessageEvent) => void) => void; postMessage?: (m: unknown) => void };
  if (typeof g.WorkerGlobalScope === "undefined" || !(g instanceof g.WorkerGlobalScope)) return;
  g.addEventListener!("message", (ev) => {
    const id = (ev.data as { dottiePlan?: number } | null)?.dottiePlan;
    if (typeof id !== "number") return;
    let p: Plan | null = null;
    try { p = plan((ev.data as { page: Page }).page); } catch { p = null; }
    g.postMessage!({ dottiePlan: id, plan: p });
  });
}
