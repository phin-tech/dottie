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
| Arrowheads: arrow, triangle, dot, bar | Supported | [edge/connectors](../fixtures/edge/connectors.dottie) | |
| Connector labels | Supported | [edge/connectors](../fixtures/edge/connectors.dottie) | Label boxes sized with CoreText's measurements. The player paints them on the page color, like the app; Dottie's flipbook export leaves them unpainted |
| Keys and eases (linear, in, out, in-out, hold, spring, bounce, elastic) | Supported | [edge/timeline](../fixtures/edge/timeline.dottie), [edge/eases](../fixtures/edge/eases.dottie) | Unknown ease names play linear, with a warning |
| Visibility, reveal (draw-on, typing), opacity | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | |
| Transitions | Supported | [edge/transitions](../fixtures/edge/transitions.dottie) | They are ordinary keys in the file |
| Follow paths (connectors, outlines, orient, reverse, laps) | Supported | [edge/follow](../fixtures/edge/follow.dottie) | |
| Packets, labelled packets | Supported | [design/labels](../fixtures/design/labels.dottie) | |
| Marching ants (dashes travelling along a line) | Supported | [edge/march](../fixtures/edge/march.dottie) | `stroke-dashoffset` per frame, evened out to loop |
| Repeats (counted and forever) | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | |
| Boil (three drawings) and settle | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | Boiled seeds match bit for bit |
| Camera views | Supported | [edge/camera](../fixtures/edge/camera.dottie), [design/zoom](../fixtures/design/zoom.dottie) | |
| Scenes (markers) and click-through | Supported | [design/tour](../fixtures/design/tour.dottie) | Stops at each scene, as the HTML export does |
| Poster frame, reduced motion | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | |
| Damaged timelines (clamped, filtered, sorted) | Supported | [edge/timeline](../fixtures/edge/timeline.dottie) | Read the way DottieKit's decoders read them |
| Unknown kinds, fields and newer versions | Partial | [js-only/future](../fixtures/js-only/future.dottie) | Drawn as labelled placeholders, reported in `warnings`; Dottie refuses such files |
| Text fonts | Partial | | Positions use Helvetica Neue's metrics; browsers without Helvetica Neue draw Helvetica or Arial in the same places, so runs of mixed styles may sit slightly apart |
| Symbols: instances on their own clocks (loop, once, still, offset), nested, scaled and turned | Supported | [edge/symbols](../fixtures/edge/symbols.dottie) | Expanded as DottieKit expands them, with the same ids, seeds and limits ([js-only/hostile-symbols](../fixtures/js-only/hostile-symbols.dottie)) |
| Clicks: play a scene, open a link, hover looks, keyboard | Supported | [edge/clicks](../fixtures/edge/clicks.dottie) | As the HTML export does; only http, https and mailto links are followed |
| Links between shapes and pages | Partial | [edge/clicks](../fixtures/edge/clicks.dottie) | A link to a shape on another page shows that page; one on the same page does nothing. The HTML export holds one page, so it has neither |
| Editing | Missing | | |
| Ticking task boxes in notes | Missing | | Drawn, not clickable |
