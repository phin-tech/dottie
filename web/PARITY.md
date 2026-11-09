# dottie.js parity with Dottie

What dottie.js draws and plays compared with the Dottie app. **Supported** means it matches Dottie exactly:
the geometry contract (`dottie inspect`) and Dottie's own SVG export agree with dottie.js on the listed
fixture, and the tests in `web/test` check it. A new app feature lands here as a **missing** row, with a
fixture, so the gap is visible rather than silent.

| Feature | Status | Fixture | Notes |
|---|---|---|---|
| Rectangle, ellipse, diamond | Supported | [edge/shapes](../fixtures/edge/shapes.dottie) | Sketchy strokes are a port of Rough.swift, so the same seed draws the same lines |
| Text (multi-line) | Supported | [edge/shapes](../fixtures/edge/shapes.dottie) | Lines split on newlines, as Dottie's SVG export does |
| Freehand strokes (fitted and raw) | Supported | [edge/shapes](../fixtures/edge/shapes.dottie) | |
| Paths (compound, holes, even-odd) | Supported | [edge/shapes](../fixtures/edge/shapes.dottie) | |
| Sticky notes (Markdown) | Supported | [edge/notes](../fixtures/edge/notes.dottie) | Headings, paragraphs, line breaks, nested and task lists, quotes, code, rules, tables, bold, italic, code, strikethrough, links, bare URLs. Laid out with Helvetica Neue metrics from CoreText, so lines break where Dottie breaks them. HTML blocks show as plain text |
| Pictures (by reference, inline, missing) | Supported | [edge/shapes](../fixtures/edge/shapes.dottie) | A missing picture draws nothing, as in Dottie's SVG export (the app's PNG shows a crossed box) |
| Fills: solid, hachure, cross-hatch | Supported | [edge/shapes](../fixtures/edge/shapes.dottie) | |
| Grid fill and dungeon rock hatching | Supported | [edge/dungeon](../fixtures/edge/dungeon.dottie) | |
| Dashed and dotted strokes, stroke width, bowing | Supported | [edge/shapes](../fixtures/edge/shapes.dottie) | |
| Rotation, opacity | Supported | [edge/shapes](../fixtures/edge/shapes.dottie) | |
| Layers (order, hidden layers) | Supported | [edge/shapes](../fixtures/edge/shapes.dottie) | |
| Themes and automatic ink | Supported | [edge/themes](../fixtures/edge/themes.dottie) | An unknown theme draws on white, as in Dottie |
| Pages | Supported | [edge/themes](../fixtures/edge/themes.dottie) | `page` attribute or option: name or number |
| Connectors: straight, curved, elbow | Supported | [edge/connectors](../fixtures/edge/connectors.dottie) | |
| Ports and edge-following, rotated shapes, free ends | Supported | [edge/connectors](../fixtures/edge/connectors.dottie) | |
| Connectors and labels on outlines (ADR 0001) | Supported | [edge/extensions](../fixtures/edge/extensions.dottie) | Edge-following meets a `.path`'s actual outline, not its box (ray against 16-step flattened curves). Endpoints pinned with `portIndex` attach to the element's `ports`. A path's label goes in its `labelRect`. |
| Extension shapes as stored (ADR 0001) | Supported | [edge/extensions](../fixtures/edge/extensions.dottie) | Drawn from the stored path with no extension installed. The `extension` field is kept as metadata and nothing runs. Parameters, commands and handles are Dottie-only. |
| Click logic (`logic`, a click's `run`) | Supported | [edge/logic](../fixtures/edge/logic.dottie) | One engine for both: `logic.ts` (QuickJS in WebAssembly), run by `LogicEngine.swift` in JavaScriptCore. Runs only with `allow-logic` (ADR 0007). |
| Number variables, expressions in conditions and clicks, `{value}` in labels | Supported | [edge/counters](../fixtures/edge/counters.dottie), [expressions.json](../fixtures/expressions.json) | One grammar in `Expression.swift` and `expression.ts` (ADR 0007). |
| Containers and swimlanes | Supported | [edge/containers](../fixtures/edge/containers.dottie) | Drawn from the stored frame and title band (`labelRect`); the app keeps them fitted (ADR 0006). |
| Themes of a page's own, and palette colors by name | Supported | [edge/palette](../fixtures/edge/palette.dottie) | Names are resolved when a file is read, by the same rules in `Theme.swift` and `theme.ts` (ADR 0005). |
| Elbows that go round shapes (`avoid`) | Supported | [edge/elbow-around](../fixtures/edge/elbow-around.dottie) | The same grid router, point for point (`ElbowRouter.swift`, `elbow.ts`). |
| Waypoints (bends) on every routing, and hops | Supported | [edge/waypoints](../fixtures/edge/waypoints.dottie), [edge/waypoints-symbol](../fixtures/edge/waypoints-symbol.dottie) | Hops need the page, so `connectorParts` takes it; without one a line draws none. |
| Arrowheads: arrow, triangle, dot, bar | Supported | [edge/connectors](../fixtures/edge/connectors.dottie) | |
| Label colors (`textColor`, apart from the stroke) | Supported | [edge/text-colors](../fixtures/edge/text-colors.dottie) | Text boxes and notes ignore it, as in Dottie |
| Connector labels | Supported | [edge/connectors](../fixtures/edge/connectors.dottie) | Label boxes sized with CoreText's measurements. The player paints them on the page color, like the app |
| Keys and eases (linear, in, out, in-out, hold, spring, bounce, elastic) | Supported | [edge/timeline](../fixtures/edge/timeline.dottie), [edge/eases](../fixtures/edge/eases.dottie) | Unknown ease names play linear, with a warning |
| Visibility, reveal (draw-on, typing), opacity | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | |
| Transitions | Supported | [edge/transitions](../fixtures/edge/transitions.dottie) | They are ordinary keys in the file |
| Follow paths (connectors, outlines, orient, reverse, laps) | Supported | [edge/follow](../fixtures/edge/follow.dottie) | |
| Packets, labelled packets | Supported | [design/labels](../fixtures/design/labels.dottie) | |
| Marching ants (dashes travelling along a line) | Supported | [edge/march](../fixtures/edge/march.dottie) | `stroke-dashoffset` per frame, evened out to loop |
| Repeats (counted and forever) | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | |
| Boil (three drawings) and settle | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | Boiled seeds match bit for bit |
| Camera views | Supported | [edge/camera](../fixtures/edge/camera.dottie), [design/zoom](../fixtures/design/zoom.dottie) | |
| Scenes (markers) and click-through | Supported | [design/tour](../fixtures/design/tour.dottie) | Stops at each scene. The HTML export is this player |
| Poster frame, reduced motion | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | |
| Damaged timelines (clamped, filtered, sorted) | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | Read the way DottieKit's decoders read them |
| Unknown kinds, fields and newer versions | Partial | [js-only/future](../fixtures/js-only/future.dottie) | Drawn as labelled placeholders, reported in `warnings`; Dottie refuses such files |
| Text fonts | Partial | [edge/fonts](../fixtures/edge/fonts.dottie) | Measured with CoreText's metrics for Helvetica Neue and the bundled handwriting fonts (Caveat, Patrick Hand, Architects Daughter), which the player loads from `dist/fonts` and a compiled drawing carries; browsers without Helvetica Neue draw Helvetica or Arial in the same places, so runs of mixed styles may sit slightly apart. A font of one's own is laid out as Helvetica Neue and drawn in that font where the viewer has it |
| Symbols: instances on their own clocks (loop, once, still, offset), nested, scaled and turned | Supported | [edge/symbols](../fixtures/edge/symbols.dottie) | Expanded as DottieKit expands them, with the same ids, seeds and limits ([js-only/hostile-symbols](../fixtures/js-only/hostile-symbols.dottie)) |
| Button symbols (up, over, down, hit) and clickable copies | Supported | [edge/buttons](../fixtures/edge/buttons.dottie) | Up, over, down and hit, in the player and the HTML export alike |
| Symbol parameters (`{{name}}` in a symbol's text, filled per copy) | Supported | [edge/params](../fixtures/edge/params.dottie) | Defaults, undeclared names left as written, values passed into nested copies, filled before text types out |
| Copies that play when clicked | Supported | [edge/buttons](../fixtures/edge/buttons.dottie) | In the player and the HTML export |
| Clicks: play a scene, open a link, hover looks, keyboard | Supported | [edge/clicks](../fixtures/edge/clicks.dottie) | Only http, https and mailto links are followed |
| Page variables and conditions (`variables`, `when`) | Supported | [edge/state](../fixtures/edge/state.dottie) | Starting values in every still and export; connectors go with a shape the state hides |
| Overrides (`overrides`: restyle and reroute under a condition) | Supported | [edge/state](../fixtures/edge/state.dottie) | Opacity multiplies; a reroute or key that isn't an id is dropped as DottieKit drops it |
| Traffic flows (`flows`) | Supported | [edge/flows](../fixtures/edge/flows.dottie) | Routed each frame over the connectors drawn, cheapest by connector `cost` (ADR 0002); packet ids derive from the flow's |
| Volume, capacity, delay, metrics, gauges | Supported | [edge/flows](../fixtures/edge/flows.dottie) (Capacity page) | One implementation: Dottie runs `measure.ts` in JavaScriptCore (ADRs 0003, 0004). Assignment in page order, backlog piles, conditions on metrics, gauges expanded to `.path` elements |
| Clicks that set and toggle variables | Supported | [edge/state](../fixtures/edge/state.dottie) | Change what shows without touching the playhead |
| Looping scenes (`loop` on a marker) | Supported | [edge/state](../fixtures/edge/state.dottie) | No stop on entering, round from the scene's end to its start |
| Links out of the drawing (`url`) | Supported | [edge/links](../fixtures/edge/links.dottie) | A web or mail `url` opens when clicked if there is no `click`, and SVG export wraps it in `<a>`; a link to another drawing does nothing on the web |
| Links between shapes and pages | Partial | [edge/clicks](../fixtures/edge/clicks.dottie) | A link to a shape on another page shows that page; one on the same page does nothing. The HTML export holds one page, so it has neither |
| Editing | Missing | | |
| Ticking task boxes in notes | Missing | | Drawn, not clickable |
