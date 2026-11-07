# dottie.js performance review

Reviewed 2026-11-07 at commit `38f41f4`. Scope: the rendering, playback, animation and simulation paths in `web/src/`. This is a source review, not a browser profile or an exhaustive audit of every module. Priorities indicate likely impact under the stated workload; no latency or memory measurements were taken. No implementation changes were made.

## 1. High: startup resolves the entire animation synchronously

**Evidence:** `src/player.ts:107–111`, `src/svg.ts:44–61`, `src/timeline.ts:389–400`.

`Playback` calls `plan()` in its constructor. Without a camera, planning calls `resolved()` and computes bounds for every frame before displaying anything. Resolution includes follows, symbol expansion and flow simulation. Cost grows with duration × FPS × scene complexity, even when the page is being opened as a still. A ten-minute animation at 60 FPS requires roughly 36,000 frame resolutions upfront. The camera branch avoids these resolutions but still materializes frame times and rectangles.

**Direction:** separate interactive initialization from exhaustive export planning. Cache exact plans by page revision, or compute them outside the browser UI thread. Any cheaper bounds scheme must preserve the existing view, including spring overshoot, symbols and packets; sampling fewer frames blindly changes behavior.

**Validation:** compare time to first frame for otherwise identical 10-, 60- and 600-second drawings, both with and without camera keys. Check bounds against current plans and goldens.

## 2. High: button states render entire pages before discarding most output

**Evidence:** `src/player.ts:184–208`, `src/svg.ts:86–115`.

`drawAt()` renders the normal page, then calls `svgParts()` on the entire page again for hover looks and each populated over/down/hit state map. Only afterwards does it filter to the relevant elements. A page with all these features can perform five full SVG generation passes per draw, even if only one small button needs alternate markup. The symbol-state passes also expand the whole page again. Geometry caching does not eliminate page traversal, markup generation or note layout.

**Direction:** render the affected owners and their dependencies for alternate states. Retain the full geometry index and ordering context for attached connectors and hops. Cache alternate states when their inputs are unchanged.

**Validation:** add a button with over/down/hit states and a hoverable shape to a large otherwise static page; profile draw time before and after. Verify clickable bounds, focus and every button state with real browser integration tests.

## 3. High: crossing detection runs before the connector cache lookup

**Evidence:** `src/shapes.ts:203–214` and `src/shapes.ts:279–323`.

`connectorParts()` computes `hopCrossings()` to construct its cache key. For each hopping connector, that function orders the page, routes earlier visible connectors, and compares sampled segment pairs. With many hopping connectors this repeats pairwise work every render, including unchanged frames. Curved routes amplify the segment comparisons. The existing connector cache saves final path construction but cannot save this work.

**Direction:** compute ordered connector routes and samples once per resolved frame; cache crossings by geometry, visibility and drawing order. Use bounding-box rejection or a spatial index to reduce candidate pairs.

**Validation:** profile repeated renders with 100, 300 and 1,000 crossing connectors, straight and curved, then move one endpoint. Check exact path output against existing hop fixtures.

## 4. High on larger networks: routing repeatedly rebuilds the graph and scans the frontier

**Evidence:** `src/flows.ts:27–68`, `src/measure.ts:153–166`, `src/measure.ts:281`.

Every `flowTree()` call rebuilds shape membership and adjacency from the page. Dijkstra selects its next vertex with a linear scan and removes it with `splice`; wide frontiers can produce quadratic vertex-selection work. `flowFrame()` calls this once for a flow's base route and again during capacity assignment, potentially up to 32 iterations per share, plus queue draining. Even flows with the same source rebuild the base tree separately.

**Direction:** build a reusable adjacency representation once per frame and use a priority queue preserving the existing distance/discovery-order tie break. Reuse base trees for identical sources and offline sets. Capacity-dependent routes must respect changing residual capacity and page-order assignment; do not cache those by source alone.

**Validation:** vary vertices, edges, flow count and capacity bottlenecks independently. Verify route identities, tie breaks, placements and metrics with pure state-based tests. Measure both browser and JavaScriptCore workloads.

## 5. Medium: every followed connector rebuilds a page-wide index

**Evidence:** `src/timeline.ts:160–179`, `src/measure.ts:100–109`, `src/connector.ts:248–252`.

`tracing()` calls `indexOf(page)` whenever it traces a connector. `following()` also scans the element array for its target. Simulation calls `tracing()` for each hop of each assembled way. Repeated follows or flows over the same connectors consequently rebuild the same index and flatten the same routes. For H traced connector hops and N elements, index construction alone costs O(HN) per frame.

**Direction:** pass a frame-local geometry context containing the first-ID-wins index and lazily cached polylines. Share it across follows and simulation where the posed geometry is identical.

**Validation:** hold network size fixed and increase flows sharing a long route; compare resulting packet positions and metrics exactly, including reverse hops and moving endpoints.

## 6. Medium: unchanged notes are parsed and laid out on every draw

**Evidence:** `src/svg.ts:193–194`, `src/note.ts:483–489`, `src/player.ts:227`.

Each visible note with text invokes `noteMarkup()`, which reparses Markdown, rebuilds paragraphs and lays out lines. The player's markup equality check happens after all this work. A stationary page full of long notes therefore keeps paying text-layout costs while an unrelated packet or symbol animates; alternate-state rendering multiplies that cost.

**Direction:** cache parsed blocks by source and layout by source, dimensions and font inputs. Keep color/position-dependent output separate or include those inputs in a bounded final-markup cache. Avoid relying solely on element object identity because resolution can produce fresh objects.

**Validation:** animate a single element alongside many unchanged notes. Check tables, wrapping, font changes, resizing and text changes against SVG goldens.

## 7. Medium, potentially severe for long tokens: wrapping repeatedly measures shrinking prefixes

**Evidence:** `src/text.ts:88–106`.

For an unbroken token wider than its box, `wrap()` starts with almost the entire token and repeatedly slices, joins and measures shorter prefixes until one fits. It repeats that search for the remainder. At a fixed narrow width, this can approach cubic character-processing work as token length grows. Long URLs or generated identifiers in connector labels and packet text can trigger it.

**Direction:** scan advances and kerning incrementally to find each break. Preserve Unicode code-point handling, trailing-space behavior and exact kerning semantics; width monotonicity should not be assumed without checking the metrics.

**Validation:** benchmark 100-, 1,000- and 5,000-character unbroken strings at fixed narrow widths. Use state-based tests for exact wrapped lines, including Unicode and kerning pairs.

## Validation status

No benchmarks, browser profiles or test suites were run. `just test`, `just web-test` and `just goldens-check` were not run for this documentation-only review. No generated artifacts require regeneration. Proposed fixes should follow the repository's RED/GREEN approval protocol, preserve Swift/web parity where applicable, and pass the required checks before landing.
