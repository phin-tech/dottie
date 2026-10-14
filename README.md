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

## Command line: `dottie`

Render drawings and manage libraries without opening the app.

```sh
dottie render diagram.dottie                      # diagram.png next to it
dottie render diagram.dottie -o diagram.svg       # png, svg, pdf or html, from the extension
dottie render a.dottie b.dottie -f html -d out/   # several files into a directory
dottie render diagram.dottie --clean --scale 3 -o - > clean.png
dottie library list
dottie library install shapes.dottielib
```

`--clean` / `--sketchy` override the look, `--transparent` drops the page background, and the HTML output is a
single self-contained page. It reads the file on disk, not unsaved edits in the app. To install it, open
Settings ▸ Command Line and link it into `/usr/local/bin` or `~/.local/bin` (the app carries the tool in
`Contents/Helpers`), or from a checkout run `just cli-install`.

## Let agents draw: `dottie-mcp`

A stdio MCP server that creates and edits `.dottie` files. Every tool takes an absolute `path`.

```sh
swift build -c release --product dottie-mcp
claude mcp add dottie -- "$(swift build -c release --product dottie-mcp --show-bin-path)/dottie-mcp"
```

Tools: `build_diagram` (nodes + edges, auto-laid-out), `add_shape`, `add_connector`, `update_element`,
`delete_element`, `list_elements`, `auto_layout`, `export_png` (returns an image so the agent can check its work),
`export_svg`, `create_diagram`, `open_document`, `list_stencils` and `add_stencil` (place shapes from the
built-in and user stencil libraries), and `run_script` / `script_api` (see below).

### Scripting

Drawings can be scripted in JavaScript (JavaScriptCore, no dependencies). A script sees one global, `dottie`,
with calls to read, draw and change elements; it has no file or network access, runs against a copy, and is
applied as a single undo step only if it finishes without throwing. Runaway scripts are stopped after 10 s.

```js
const a = dottie.rect({ x: 0, y: 0, text: "Start", fill: "#d6f5d6" });
const b = dottie.diamond({ x: 0, y: 140, text: "OK?" });
dottie.connect(a, b, { routing: "elbow" });
return dottie.elements().length;
```

- **In the app:** Script ▸ Script Console… (⌥⌘J) opens an editor with Run (⌘↩), Open/Save and an API
  reference; `dottie.selection` is the selected elements. `.js` files in
  `~/Library/Application Support/Dottie/Scripts` appear in the Script menu and run on the front drawing.
- **From an agent (code mode):** the MCP tool `run_script` takes a `path` and `code`, so a loop or a computed
  edit is one call instead of dozens, and returns `console.log` output, the script's value, and optionally a
  PNG (`render`). The API is documented in the tool's description, the `script_api` tool, and the
  `dottie://script-api` resource.

Scripts can `require()` libraries. Bundled: `lodash`, `d3-array`, `d3-color`, `d3-hierarchy`, `dagre` (graph layout), `dayjs` (regenerate or bump
with `scripts/update-script-modules.py`). The Settings ▸ Scripting tab has a checklist of optional libraries (`d3-scale`, `d3-shape`, `d3-force`, `chroma-js`,
`seedrandom`, `simple-statistics`): checking one downloads its pinned, checksum-verified version into the modules
folder, unchecking removes it. Timers never fire in scripts, so step `d3-force` by hand with `simulation.stop().tick(n)`.
The same tab has an **Add a library** field: paste an npm name (`marked`, `lodash@4`) or an `https://` link to a
`.js` file. Dottie resolves and pins the version via jsDelivr, loads the file in the script engine before keeping it
(ES-module-only or Node-only packages are refused with the reason), fetches missing package dependencies the same
way, and lists what you added so it can be removed. This is app-only; agents cannot install libraries.
You can also drop any other single-file CommonJS/UMD bundle into
`~/Library/Application Support/Dottie/Scripts/modules/` (Script ▸ Show Scripts Folder) and `require("name")` loads
it; a file there overrides a bundled one. `./` and `../` work between your modules, and nothing outside that folder
is reachable. Agents can also pass `modules: {name: source}` to `run_script`, and `script_api` lists what is
installed. There is no npm, `import` syntax, or Node built-ins.

```js
const _ = require("lodash"), { hierarchy, tree } = require("d3-hierarchy");
const root = tree().nodeSize([180, 120])(hierarchy({ name: "App", children: [{ name: "UI" }, { name: "API" }] }));
const ids = {};
root.each(n => { ids[n.data.name] = dottie.rect({ x: n.x + 300, y: n.y, text: n.data.name }); });
root.links().forEach(l => dottie.connect(ids[l.source.data.name], ids[l.target.data.name]));
```

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
