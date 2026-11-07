// The simulation DottieKit runs in JavaScriptCore (SimulationEngine.swift): the assignment, packets and metrics of
// one posed frame (`flowFrame`, ADR 0003), so Swift and dottie.js share one implementation of them. Data crosses as
// JSON text: a .dottie page in, packets and metrics out.

import { flowFrame } from "./measure.ts";
import { parseDottie } from "./model.ts";

interface Request {
  page: unknown;
  t: number;
  values: Record<string, boolean> | null;
  offline: string[];
  since: number | null;
  carried: Record<string, number>;
}

/** One frame's packets (as centers, styled by their flow in Swift) and metrics, as JSON text. */
function frame(request: string): string {
  const r = JSON.parse(request) as Request;
  const page = parseDottie({ version: 2, pages: [r.page] }).pages[0];
  const out = flowFrame(page.flows, page, r.t, r.values, new Set(r.offline), r.since, r.carried);
  const packets = out.packets.map((p) => [p.id, p.x, p.y, p.width, p.layerID]);
  return JSON.stringify({
    packets,
    elements: Object.fromEntries(out.metrics.elements),
    flows: Object.fromEntries(out.metrics.flows),
    carry: out.metrics.carry,
  });
}

(globalThis as { DottieSim?: unknown }).DottieSim = { frame };
