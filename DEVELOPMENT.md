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

## MCP server

A stdio MCP server; every tool takes an absolute `path` to a `.dottie` file, or `"current"` for the drawing in
front in the app.

Tools: `build_diagram` (nodes + edges, auto-laid-out), `add_shape`, `add_connector`, `update_element`,
`delete_element`, `list_elements`, `auto_layout`, `export_png` (returns an image so the agent can check its
work, plus each element's id and pixel box), `export_svg`, `create_diagram`, `open_document`, `list_stencils`,
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
dottie library list
dottie library install shapes.dottielib
```

`--clean` / `--sketchy` override the look and `--transparent` drops the background. It reads the file on disk,
not unsaved edits in the app.
