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
- [x] Automatic ink (adapts to dark mode, exports black), Settings window (⌘,), menu bar commands, hideable inspector
- [x] Copy/paste/duplicate, groups, align/distribute, z-order, smart guides + grid snap, pencil, SVG export
- [x] Live mode: the MCP server edits documents open in the app over a Unix socket (undoable)

## Next
1. Layers panel (add/hide/lock/reorder)
2. Hachure fills, stroke-width/dash styles, arrowhead choices
3. Resize-with-smart-guides, distribute spacing guides, rotate
4. Stencil/shape libraries, rulers, themes
5. Edit pencil strokes (point editing), eraser

## Agents (MCP)
- [x] Live mode (see README); `export_svg`
- [ ] Open a file in the app from the MCP server (`open_document`)
- [ ] Connector labels
- [ ] Return an element-id -> text map from `export_png` so agents can annotate

## Open questions
- Hand-drawn font: Excalidraw's Virgil/Excalifont have their own license; using system font until decided.
