---
status: accepted
---

# The simulation is written once, in dottie.js, and Dottie runs it in JavaScriptCore

ADRs 0002 and 0003 made every frame a pure function of the page, the time, the variables, the time since the state
last changed and what the queues held then. They were built twice, in Swift (`Metrics.swift`, `Flows.swift`) and in
TypeScript (`web/src/measure.ts`, `web/src/flows.ts`), and the goldens proved the two agreed. Each new behaviour
(queues draining through every route, capacities that combine, alarms on an element's own metric) meant writing it
twice and making both agree down to tie-breaking and the order of floating-point operations. Most of what Dottie
shows interactively is played by dottie.js anyway: the HTML export is `<dottie-player>`, and the web pages embed it.

## Decision

- **One implementation.** Flows' routing and assignment, packets, metrics, the overrides that compare metrics, and
  gauges live only in dottie.js (`web/src/measure.ts`, `flows.ts`). Swift's copies are gone.
- **Dottie runs it in JavaScriptCore.** `just player-script` bundles `web/src/sim-entry.ts` as
  `PlayerScript.simulation`. `SimulationEngine` (one long-lived `JSContext`, used by one caller at a time) is called
  from `posedWithMetrics`, so the app, the CLI, QuickLook, MCP, `simulate` and every Swift export pose the same frames
  the browser does.
- **Plain data at the boundary.** Swift sends the posed page as `.dottie` JSON, and only when it differs from the
  last one sent. Each frame then sends only its time, the variables, what's offline, the time since the state
  changed, and the carried queues. JS sends back packets as `[id, x, y, size, layer]`, the metrics, and for each
  element finishing changes, the overrides whose looks hold and a gauge's drawing. Swift builds the elements, with
  the styles and ids it always used. No Swift type crosses as an object.
- **The model stays declarative.** This is Dottie's own code, bundled at build time. Documents still hold no code
  (ADR 0001), and the frame is still a pure function of its inputs (ADR 0002).
- **Failure.** If the script can't load or throws (a bug in the bundle; JavaScriptCore is part of macOS), the frame
  is drawn without traffic and gauges as their rectangles, `SimulationEngine.failure` says why, and debug builds stop.

## Consequences

- A change to the simulation is a `web/src` change, then `just player-script` and `just goldens`. AGENTS.md's parity
  rule no longer asks for a Swift mirror of it. The geometry, connectors, labels, the model and the file format are
  still in both languages.
- The goldens no longer check two independent implementations of the simulation against each other; they're its
  regression tests. Correctness rests on behaviour tests with numbers a reader can check (`MetricsTests`,
  `FlowTests`, `ControlsTests`, `ScriptExamplesTests` in Swift; `state.test.ts` and the browser tests in dottie.js).
  Before the Swift copy was deleted, the two posed 16,650 frames of the worked examples and flow fixtures
  identically, every combination of variables, times, clicks and carried queues included.
- Cost. A debug build poses an interactive page with the engine about as fast as Swift did (0.4 to 1.3 ms a frame
  for pages of 16 to 32 elements). A page whose shapes move under its flows is re-sent every frame: about 0.8 ms
  more. Sending only what changed would recover that; it isn't worth the extra state yet.
- Parallel exports take turns on the one context. A context per thread would remove that if it ever shows.
- Debugging the simulation in the app means debugging minified JavaScript; reproduce it in dottie.js's tests instead.

## Considered and rejected

- **Keeping both, with the goldens as the bridge.** It catches a bug made in only one language, but almost every
  difference the goldens found was the two drifting apart, which one implementation can't do.
- **Running document code at play time** (click handlers, scripted models). ADRs 0001 and 0002 rejected it for
  reasons that still hold: drawings play on other people's sites and in QuickLook, and files must draw without code.
- **Drawing exports with dottie.js** (SVG out of JavaScriptCore). The app's canvas needs the Swift renderer anyway,
  so it would add a second path without removing one.
- **Sending deltas of the page.** Measured first: only pages with keyframes under their flows re-send, and
  0.8 ms a frame doesn't need the extra state on both sides.
- **Posing in dottie.js too** (keys, follows, state, symbol expansion: `posedWithMetrics` and `expandingSymbols`).
  Measured on the `js-posing` branch: it posed all 6,776 frames of the fixtures, design drawings and worked
  examples as Swift does (within 1e-6), and on a page that doesn't change it costs little once unchanged elements
  come back as indices and changed ones as patches (1,000 elements, 10% moving: 3.7 ms a frame against Swift's
  3.4, debug build). But the editor poses and expands instances on every redraw, and a page that changes every
  frame is sent again every frame: dragging on a 1,000-element animated page took 23 to 26 ms a frame against
  Swift's 3.5. Swift also keeps its tracks for editing (Magic Move, transitions, the timeline rows) and Lottie, so
  little would be deleted. Worth revisiting only if posing starts drifting between the two the way the
  simulation did.
