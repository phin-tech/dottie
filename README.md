# Dottie

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
`export_svg`, `create_diagram`, `open_document`.

`export_png` also returns each element's id, kind, text and pixel box in the image. Connectors take a `label`;
shapes and connectors take `fill_style` (solid, hachure, crossHatch), `dash`, `stroke_width`, `bowing`,
`rotation` (degrees) and `start_head` / `end_head` (none, arrow, triangle, dot, bar).

**Live mode.** If the Dottie app has the file open, tool calls edit that open document (one undo step each,
shown as "Agent: <tool>" in Edit ▸ Undo) instead of the file on disk, and `export_png` renders what is on screen.
The app listens on `~/Library/Application Support/Dottie/live.sock`; when it isn't running or the file isn't
open, tools fall back to reading and writing the file. Save in the app to persist agent edits.

Uses the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), pinned to a `main`
revision because 0.11.0 fails to compile under Swift 6.4. Move back to a release tag once one builds.
