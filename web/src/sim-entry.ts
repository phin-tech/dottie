// The simulation DottieKit runs in JavaScriptCore (SimulationEngine.swift, ADR 0004): one posed frame's assignment,
// packets and metrics (`flowFrame`), then the looks of overrides that compare metrics and the gauges (`finishPlan`,
// `gauge`), so the app, the CLI and dottie.js share one implementation of them (ADR 0003). Data crosses as JSON text.
// The posed page is sent only when it changes (`page`); each frame sends only its time and state.

import { finishPlan, flowFrame, gauge } from "./measure.ts";
import { parseDottie, type Page, type PathSubpath, type RGBA } from "./model.ts";
import { applyOverride, looksOnly } from "./state.ts";

interface Request {
  t: number;
  values: Record<string, boolean> | null;
  offline: string[];
  since: number | null;
  carried: Record<string, number>;
}

let current: Page | null = null;

/** Keeps the posed page, with its flows, that the next frames are worked out on: a .dottie page as JSON text. */
function page(json: string): void {
  current = parseDottie({ version: 2, pages: [JSON.parse(json)] }).pages[0];
}

/** One frame's packets (`[id, x, y, size, layer]`, styled by their flow in Swift) and metrics, as JSON text. */
function frame(request: string): string {
  if (!current) throw new Error("no page");
  const r = JSON.parse(request) as Request;
  // Swift leaves out keys whose value is nil: no `values` is every element whatever its `when` (StateChoice.all).
  r.values ??= null; r.since ??= null; r.offline ??= []; r.carried ??= {};
  const page = current;
  const out = flowFrame(page.flows, page, r.t, r.values, new Set(r.offline), r.since, r.carried);
  const since = Math.max(0, Math.min(r.since ?? r.t, 1e6));
  const { plan, readings } = finishPlan(page.elements, out.metrics, r.values, page, since, r.carried);
  // Per element changed: its id, the overrides whose looks apply, and a gauge's drawing (Swift builds the elements).
  const finish: [string, number[], Drawn | null][] = [];
  page.elements.forEach((e, i) => {
    const { applied, gauge: g } = plan[i];
    if (applied.length === 0 && !g) return;
    let shown = e;
    for (const k of applied) shown = applyOverride(looksOnly(e.overrides![k]), shown);
    finish.push([e.id, applied, g && shown.gauge ? drawn(gauge(shown, shown.gauge, g.value, page, page.flows ?? [])) : null]);
  });
  return JSON.stringify({
    packets: out.packets.map((p) => [p.id, p.x, p.y, p.width, p.layerID]),
    elements: Object.fromEntries(out.metrics.elements),
    flows: Object.fromEntries(out.metrics.flows),
    carry: { ...out.metrics.carry, ...readings },
    finish,
  });
}

/** A gauge as drawn: its frame's label, label box, text color and outline, then each bar or dial part
 * (`[id, subpaths, stroke, fill or null, width]`). */
interface Drawn {
  text: string; label: [number, number, number, number]; textColor: RGBA | null; subpaths: PathSubpath[];
  parts: [string, PathSubpath[], RGBA, RGBA | null, number][];
}

function drawn([back, ...parts]: ReturnType<typeof gauge>): Drawn {
  const l = back.labelRect!;
  return {
    text: back.text ?? "", label: [l.x, l.y, l.width, l.height], textColor: back.style.textColor, subpaths: back.subpaths ?? [],
    parts: parts.map((p) => [p.id, p.subpaths ?? [], p.style.stroke, p.style.fill.a > 0 ? p.style.fill : null, p.style.strokeWidth]),
  };
}

(globalThis as { DottieSim?: unknown }).DottieSim = { page, frame };
