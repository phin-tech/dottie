// The simulation DottieKit runs in JavaScriptCore (SimulationEngine.swift): the assignment, packets and metrics of
// one posed frame (`flowFrame`, ADR 0003), so Swift and dottie.js share one implementation of them. Data crosses as
// JSON text. The posed page is sent only when it changes (`page`); each frame sends only its time and state.

import { flowFrame } from "./measure.ts";
import { parseDottie, type Page } from "./model.ts";

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
  const out = flowFrame(current.flows, current, r.t, r.values, new Set(r.offline), r.since, r.carried);
  return JSON.stringify({
    packets: out.packets.map((p) => [p.id, p.x, p.y, p.width, p.layerID]),
    elements: Object.fromEntries(out.metrics.elements),
    flows: Object.fromEntries(out.metrics.flows),
    carry: out.metrics.carry,
  });
}

(globalThis as { DottieSim?: unknown }).DottieSim = { page, frame };
