# Dottie

<img src="Design/icon-1024.png" width="128" alt="Dottie">

A native macOS diagramming app: Excalidraw's sketchy speed with OmniGraffle-style precision.
See `ROADMAP.md` for status.

## Build

```sh
swift test                         # DottieKit + MCP logic, headless
xcodegen generate                  # regenerates Dottie.xcodeproj from project.yml
xcodebuild -project Dottie.xcodeproj -scheme Dottie build
```

## Let agents draw: `dottie-mcp`

A stdio MCP server that creates and edits `.dottie` files. Every tool takes an absolute `path`.

```sh
swift build -c release --product dottie-mcp
claude mcp add dottie -- "$(swift build -c release --product dottie-mcp --show-bin-path)/dottie-mcp"
```

Tools: `build_diagram` (nodes + edges, auto-laid-out), `add_shape`, `add_connector`, `update_element`,
`delete_element`, `list_elements`, `auto_layout`, `export_png` (returns an image so the agent can check its work),
`export_svg`, `create_diagram`, `open_document`, `list_stencils` and `add_stencil` (place shapes from the
built-in and user stencil libraries).

### Themes, rulers, layers

The Canvas section of the inspector sets a per-drawing theme (page color and ink; exports match) and shows
rulers (⇧⌘R). Drag out of a ruler to pull a guide: moves and resizes snap to it, and dropping it back on the
ruler removes it. The Layers section unfolds each layer to its elements; drag one onto another to restack,
or onto a layer to move it there. Guides can be typed in exactly, added at a position, and locked.

### Stencils

The Library tab in the sidebar holds stencil libraries: the built-in Basics set (flowchart symbols and common
shapes) plus any `.dottielib` in `~/Library/Application Support/Dottie/Libraries`. Click or drag an item to place
it. **+ ▸ New Library from SVGs…** turns SVG files or folders into a library; **Add Selection to Library…** saves
what you have selected. Items are stored at original fidelity and restyled to the drawing's look when placed
(**Keep original colors** places them as drawn). Drop `.svg` files straight onto the canvas, or use
File ▸ Import SVG…. Right-click an item in one of your libraries to rename, tag, duplicate or reorder it.
Double-click a `.dottielib` in Finder to browse it in the library viewer, copy or export items, or install it.

`export_png` also returns each element's id, kind, text and pixel box in the image. Connectors take a `label`;
shapes and connectors take `fill_style` (solid, hachure, crossHatch), `dash`, `stroke_width`, `bowing`,
`rotation` (degrees) and `start_head` / `end_head` (none, arrow, triangle, dot, bar).

**Live mode.** If the Dottie app has the file open, tool calls edit that open document (one undo step each,
shown as "Agent: <tool>" in Edit ▸ Undo) instead of the file on disk, and `export_png` renders what is on screen.
The app listens on `~/Library/Application Support/Dottie/live.sock`; when it isn't running or the file isn't
open, tools fall back to reading and writing the file. Save in the app to persist agent edits.

Uses the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), pinned to a `main`
revision because 0.11.0 fails to compile under Swift 6.4. Move back to a release tag once one builds.
