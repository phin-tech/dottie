# Developing Dottie

Native SwiftUI + AppKit app on top of `DottieKit`, a SwiftPM library with everything that can be tested without
a UI (model, renderer, exporters, importers, scripting). `dottie-mcp` (the MCP server) and `dottie` (the command
line tool) are built on the same library and ship inside the app at `Contents/Helpers`. See `ROADMAP.md` for
what is done and planned.

![Architecture](Design/architecture.png)

## Build and test

You need Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [just](https://github.com/casey/just).

```sh
just test          # DottieKit and MCP logic, headless (swift test)
just canvas-test   # drives the real canvas view with synthesized mouse events
just run           # generate the Xcode project, build and launch the app
just mcp           # release build of dottie-mcp; just mcp-install registers it with Claude Code
just cli           # release build of dottie; just cli-install links it into ~/.local/bin
```

`Dottie.xcodeproj` is generated from `project.yml` and gitignored, so change settings there, not in Xcode.

**Website.** `website/` is the GitHub Pages site (Material for MkDocs), published by
`.github/workflows/pages.yml` on pushes to `main` that touch it. Its demo players in `website/docs/players` are
made by `just demos` (and `just readme-animation`) on a Mac and committed. Preview it with
`pip install -r website/requirements.txt && mkdocs serve -f website/mkdocs.yml`.

**Looking at the running app.** `just debug-app file.dottie` launches a Debug build in the background on its own
live socket (`DOTTIE_LIVE_SOCKET`), so it doesn't take over the socket your everyday Dottie uses, and
`just debug <command>` drives it through `scripts/dottie-debug.py`: `snapshot out.png [canvas]` has the window
render itself to a PNG (no screen-recording permission needed; translucent toolbars and the inspector come out
blank), and `playhead`, `play`, `action`, `select`, `drag`, `key` and `menu` move it around. `just debug help`
lists everything. The commands exist only in Debug builds (`App/DebugDriver.swift`).

**Targets.** `Dottie` (the app) embeds `DottieCLI` and `DottieMCP` in `Contents/Helpers` and two Quick Look
app extensions in `Contents/PlugIns`, all linking DottieKit:

- `DottieQuickLookPreview` (`QuickLook/Preview`): a data-based `QLPreviewProvider` that answers Space in Finder
  with `Exporter.pdf(_: DottieFile)`, one PDF page per Dottie page. A `.dottielib` previews as
  `StencilLibrary.sheet()`, its items in a grid.
- `DottieQuickLookThumbnail` (`QuickLook/Thumbnail`): a `QLThumbnailProvider` that draws the first page (or the
  library sheet) with `Exporter.draw(_:in:size:)`, sized by `Exporter.fittedSize` so Finder doesn't letterbox it.

Both are sandboxed (Quick Look requires it; the previewed file is readable without further entitlements) and
use `Signing.xcconfig` like the other targets. Their version comes from the project-level `MARKETING_VERSION`
and `CURRENT_PROJECT_VERSION`, which must match the app's. To try them, build, then register the built app with
`lsregister -f -R -trusted <Dottie.app>` (or launch it once) and check `pluginkit -m -A -i tech.phin.dottie.QuickLookThumbnail`.
A plus sign in that listing means the extension is enabled.

**Signing.** Builds are signed to run locally unless a gitignored `Signing.local.xcconfig` sets
`DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY = Apple Development` (see `Signing.xcconfig`). Set the team there
rather than in Xcode's Signing & Capabilities pane, which is lost when the project is regenerated.

## Releasing

1. `just bump patch` (or `minor`, `major`): sets `MARKETING_VERSION` in `project.yml` and `DottieVersion`
   (the version the tool and the MCP server report), and adds one to the build number.
2. Commit and push.
3. In Xcode: Product ▸ Archive, then Distribute App ▸ Direct Distribution, and wait for "Ready to distribute".
   This needs a Developer ID Application certificate.
4. `just release`: finds the newest notarized `Dottie.app` Xcode kept in the archive's `Submissions` folder,
   checks it is a stapled, notarized Developer ID build of the version in `project.yml` and that `main` is clean
   and pushed, then publishes `Dottie-<version>.zip` as a GitHub release tagged `v<version>` with generated
   notes. Last, it points the cask in [phin-tech/homebrew-tap](https://github.com/phin-tech/homebrew-tap) at
   the new zip; `just tap` does that step alone if it failed.

The app's update check (`UpdateChecker`) reads GitHub's latest release, which skips drafts and pre-releases. It
only tells people: Homebrew installs get the `brew upgrade` command, others the release page.

## File format

A `.dottie` file is JSON (sorted keys, pretty-printed, rounded frames, so it diffs well in git): a `DottieFile`
with `version` and `pages`. Each page (`DottieDocument`) has an id, a name, layers, elements, guides and a theme.
Element ids are unique across the file, which is what lets a link point at a shape on another page.
A `note` element is a sticky note whose `text` is GitHub Flavored Markdown; `Note` parses it with
[swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm), DottieKit's only dependency, and lays
it out with CoreText, and the renderer and SVG export share that layout. A single newline is a line break, as in
GitHub comments, and bare URLs are underlined by `Note` itself (swift-markdown leaves cmark's autolink extension off). Dottie 0.1.1 and earlier cannot open a file containing a note.
An `image` element's picture is saved once per file, in a top-level `images` table keyed by its SHA-256 (`data`,
base64, and `format`, `png` or `jpeg`); the element holds `"image": {"ref": "<sha256>"}`, so copies cost nothing.
In memory and everywhere outside a `.dottie` file (clipboard, live mode, libraries) the element carries the
picture inline, and copies share one buffer. A reference with no table entry opens as a crossed-out box. Every picture
is normalized on the way in by `ImageImport` (EXIF rotation applied, longest side capped at 2048 px, re-encoded
as PNG, or JPEG for large opaque photos) so SVG and HTML exports can embed the bytes as a `data:` URI. Decoded
images are cached by that digest, always recomputed from the bytes. Versions before pictures cannot open a file containing one.

## Mermaid

`MermaidImporter` parses `flowchart` / `graph` text with a hand-written scanner into `DiagramOps.build` nodes
and edges, so an import lays out exactly like `build_diagram`. Shapes map to the nearest kind (circles and
stadiums to ellipses, `{}` to a diamond, the rest to rectangles). BT and RL draw as TB and LR, subgraphs are
flattened, and only `fill` survives from `style` / `classDef`. Other diagram types are refused with a clear error.

`Exporter.mermaid` goes the other way (File ▸ Export As ▸ Mermaid, `dottie render -f mermaid`, `export_mermaid`):
shapes become nodes with ids `n1`, `n2`, ... (or the element's `anchor` when it is a valid id), connectors attached
at both ends become links, and the direction is guessed from the layout. Everything else is skipped and counted
in a `%%` comment. Import, export and import again gives the same graph (`MermaidExportTests`).

## MCP server

A stdio MCP server; every tool takes an absolute `path` to a `.dottie` file, or `"current"` for the drawing in
front in the app.

Tools: `build_diagram` (nodes + edges, auto-laid-out), `import_mermaid` (a Mermaid flowchart, laid out the same
way), `add_shape`, `add_connector`, `update_element`,
`delete_element`, `add_image`, `list_elements`, `auto_layout`, `export_png` (returns an image so the agent can check its
work, plus each element's id and pixel box), `export_svg`, `export_mermaid`, `create_diagram`, `open_document`, `list_stencils`,
`add_stencil`, `list_pages`, `add_page`, `rename_page`, `run_script` and `script_api`. Tools that draw, list or
export take an optional `page` (name or 1-based number) and default to the first page; tools given an element
id find its page themselves. `add_shape` and `build_diagram` take kind `note` for a sticky note
whose text is Markdown. Connectors take a `label`; shapes and connectors take `fill_style`, `dash`,
`stroke_width`, `bowing`, `rotation` and `start_head` / `end_head`.

**Live mode.** The app listens on `~/Library/Application Support/Dottie/live.sock`. When it has the file open,
tool calls edit that window (one undo step each, shown as "Agent: <tool>") instead of the file on disk. When it
isn't running or the file isn't open, tools read and write the file.

It uses the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), pinned to a `main`
revision (in both `Package.swift` and `project.yml`) because 0.11.0 fails to compile under Swift 6.4. Move back
to a release tag once one builds.

## Scripting

Scripts run in JavaScriptCore with one global, `dottie`, and no file or network access. They run against a copy
and apply as one undo step only if they finish without throwing; runaway scripts stop after 10 s. The full API
is `DottieScript.apiReference` (shown in the console, the `script_api` tool and the `dottie://script-api`
resource).

`require()` loads CommonJS/UMD modules: bundled ones (`lodash`, `d3-array`, `d3-color`, `d3-hierarchy`, `dagre`,
`dayjs`; regenerate with `scripts/update-script-modules.py`), optional ones from Settings ▸ Scripting (pinned and
checksum-verified, or any npm name or `.js` URL resolved through jsDelivr), and files in
`~/Library/Application Support/Dottie/Scripts/modules/`. Timers never fire, so step `d3-force` by hand.

## Command line

```sh
dottie render a.dottie b.dottie -f html -d out/   # several files into a directory
dottie render diagram.dottie --clean --scale 3 -o - > clean.png
dottie render diagram.dottie --page Details
dottie render flow.mmd -o flow.svg                # a Mermaid flowchart, laid out like import_mermaid
dottie render diagram.dottie -f mermaid -o -       # shapes and connectors as Mermaid text
dottie library list
dottie library install shapes.dottielib
```

`--clean` / `--sketchy` override the look and `--transparent` drops the background. It reads the file on disk,
not unsaved edits in the app.
