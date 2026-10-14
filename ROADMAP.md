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

- [x] Pen strokes stored as fitted Béziers (flat, deterministic); point editing and an eraser that cuts strokes
- [x] Hachure / cross-hatch fills, dashed and dotted lines, arrowhead choices, bowing, connector labels
- [x] Layers panel (add, hide, lock, rename, reorder; layer order is z-order)
- [x] Rotation (single and multi-selection), resize with smart guides, equal-spacing guides while moving
- [x] Large-document performance: id-indexed connector passes, viewport culling, linear layer ordering (see PerformanceTests)
- [x] `path` element kind: compound Bézier shapes with holes (even-odd or nonzero), sketchy and hatched like the rest
- [x] SVG import (File ▸ Import SVG…, or drop `.svg` files; ⌥-drop keeps original colors): paths, shapes, transforms, `<use>`, CSS classes, gradients flattened to their first stop
- [x] Stencil libraries: `.dottielib` files, built-in Basics set, Library sidebar tab (search, click/drag to place, SVG folders to library, add selection), `list_stencils` / `add_stencil` over MCP
- [x] Excalidraw (`.excalidraw`, `.excalidrawlib`) and draw.io (`.drawio`, compressed or not) import: File menu, drop, or into a library

## Next
2. Rulers, themes
3. Per-element layer drag-and-drop in the layers panel

## Agents (MCP)
- [x] Live mode (see README); `export_svg`
- [x] `open_document`: open a file in the app from the MCP server
- [x] Connector labels (`label` on edges and `add_connector`; `text` on `update_element`)
- [x] `export_png` returns an element-id -> kind, text and pixel box map
- [x] Look options on shapes and connectors: `fill_style`, `dash`, `stroke_width`, `bowing`, `rotation`, `start_head`, `end_head`

## Open questions
- Hand-drawn font: Excalidraw's Virgil/Excalifont have their own license; using system font until decided.
