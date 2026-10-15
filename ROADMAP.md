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

- [x] Themes (Paper, White, Sepia, Blueprint, Chalkboard, Midnight): stored per drawing, used by the canvas and every export
- [x] Rulers (⇧⌘R) with guides you drag out of them: persisted in the file, snapped to by moves and resizes
- [x] Layers panel unfolds to elements: drag to restack, or onto a layer to move
- [x] Pages: tabs under the canvas (add, rename, reorder, duplicate, delete), links and Back/Forward across pages, `page` on MCP tools and `dottie render --page`

- [x] Library viewer: `.dottielib` opens in its own window (Finder double-click or Library ▸ Open in Viewer); copy, export PNG/SVG, install
- [x] Guides by number (type, add, remove) and lock; stencil items rename, tag, duplicate, reorder; library rename
- [x] Element links: pick a target in the inspector, follow by badge or ⌘-click, Back/Forward (⌘[ ⌘]); `link` over MCP and scripts
- [x] Canvas context menu (edit, link, arrange); hidden element anchors (`anchor`)
- [x] `dottie` command-line tool: render to png, svg, pdf and html, library list/install; installed from Settings ▸ Command Line
- [x] Pictures (`image` kind): paste, drop or File ▸ Insert Image…; embedded as PNG/JPEG (EXIF-rotated, capped at 2048 px), optional sketchy border, in every export; `add_image` over MCP
- [x] Mermaid flowchart import: File ▸ Import Mermaid…, ⌘V of flowchart text, `.mmd` drop, `import_mermaid` over MCP, `dottie render flow.mmd`
- [x] Mermaid flowchart export: File ▸ Export As ▸ Mermaid, `dottie render -f mermaid`, `export_mermaid` over MCP; round-trips with import
- [x] Sticky notes (`note` kind, N): GitHub Flavored Markdown (swift-markdown) laid out with CoreText, tables included; click-to-tick task boxes, color swatches, identical in PNG, PDF and SVG; `note` over MCP and scripts
- [x] Quick Look: Space in Finder previews a drawing (every page, as a PDF) or a stencil library; Finder thumbnails show the first page on its theme's color

## Next
- Custom themes and a color palette per theme
- Cursor-position marker on the rulers
- Visio (`.vsdx`) import
- Links: a Sections list in the sidebar, URL links, clickable links in PDF and SVG export, links to other drawings

## Agents (MCP)
- [x] Live mode (see README); `export_svg`
- [x] `open_document`: open a file in the app from the MCP server
- [x] Connector labels (`label` on edges and `add_connector`; `text` on `update_element`)
- [x] `export_png` returns an element-id -> kind, text and pixel box map
- [x] Look options on shapes and connectors: `fill_style`, `dash`, `stroke_width`, `bowing`, `rotation`, `start_head`, `end_head`
- [x] `link` on `update_element` (and in `list_elements`)

## Open questions
- Hand-drawn font: Excalidraw's Virgil/Excalifont have their own license; using system font until decided.
