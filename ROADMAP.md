# Dottie roadmap

Native macOS diagramming: Excalidraw's speed and sketchy look, OmniGraffle's precision.
Stack: SwiftUI + AppKit, `DottieKit` (SwiftPM) for everything testable headless.

## Done
- [x] Model (`.dottie` JSON, sorted keys, versioned), layers, z-order
- [x] Seeded rough.js-style renderer (roughness 0 = precise)
- [x] PNG + PDF export through the same renderer as the canvas
- [x] Document app: new/open/save, undo/redo, select/move/delete, rect/ellipse/diamond tools, inspector (sketchiness, stroke, colors)

- [x] Bound connectors (edge-following or pinned ports; straight/curved/elbow), pan, zoom, select all, tool shortcuts
- [x] `dottie-mcp`: headless MCP server so agents can build diagrams (see README)

## Next (in order)
1. ~~Resize handles, marquee, text~~ (done)
2. Bound connectors (store bindings, compute endpoints at render time), arrowheads, elbow/curved routing
3. Freehand pencil with smoothing
4. Smart guides + grid snapping (modifier to bypass), alignment/distribute, layers panel (add/hide/lock/reorder)
5. SVG export, zoom/pan, copy/paste, groups, hachure fills
6. Stencil/shape libraries, rulers, themes

## Agents (MCP)
- [ ] Live mode: edit the open document in the running app (same tools, IPC behind them)
- [ ] Connector labels; SVG export tool
- [ ] Return an element-id -> text map from `export_png` so agents can annotate

## Open questions
- Hand-drawn font: Excalidraw's Virgil/Excalifont have their own license; using system font until decided.
