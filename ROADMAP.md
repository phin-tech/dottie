# Dottie roadmap

Native macOS diagramming: Excalidraw's speed and sketchy look, OmniGraffle's precision.
Stack: SwiftUI + AppKit, `DottieKit` (SwiftPM) for everything testable headless.

## Done
- [x] Model (`.dottie` JSON, sorted keys, versioned), layers, z-order
- [x] Seeded rough.js-style renderer (roughness 0 = precise)
- [x] PNG + PDF export through the same renderer as the canvas
- [x] Document app: new/open/save, undo/redo, select/move/delete, rect/ellipse/diamond tools, inspector (sketchiness, stroke, colors)

## Next (in order)
1. ~~Resize handles, marquee, text~~ (done)
2. Bound connectors (store bindings, compute endpoints at render time), arrowheads, elbow/curved routing
3. Freehand pencil with smoothing
4. Smart guides + grid snapping (modifier to bypass), alignment/distribute, layers panel (add/hide/lock/reorder)
5. SVG export, zoom/pan, copy/paste, groups, hachure fills
6. Stencil/shape libraries, rulers, themes

## Open questions
- Hand-drawn font: Excalidraw's Virgil/Excalifont have their own license; using system font until decided.
