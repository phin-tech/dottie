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
`create_diagram`.

Uses the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), pinned to a `main`
revision because 0.11.0 fails to compile under Swift 6.4. Move back to a release tag once one builds.
