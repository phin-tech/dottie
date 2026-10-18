---
status: proposed
---

# JavaScript extensions generate paths when edited, not when drawn

Dottie will load JavaScript **extensions** that add parametric **extension shapes** and document **commands**. An
extension shape's code runs only when its parameters or frame change; it returns a single path, which Dottie stores in
the document as an ordinary `kind: "path"` element alongside the parameters that made it. Every renderer (canvas,
PNG/SVG/Lottie export, QuickLook, the CLI, MCP, and the dottie.js web player) draws that stored path with the code it
already has, so no extension code runs to view, export or play a file, files open everywhere without the extension,
and `web/PARITY.md` holds without a second implementation in TypeScript.

The first audience is Sam and agents. Nothing here may rule out third-party extensions later, so extensions get no
file system, network or timers, and code is never embedded in documents.

## Decision

**Scope, in phases.**

- v1: extension shapes (parameter schema, inspector, `generate`) and commands.
- v1.1: on-canvas adjustment handles for shapes; live preview in command forms.
- Later: drawing tools, which first need the mouse handling in `CanvasView` turned from an if-chain over the closed
  `Tool` enum into a protocol; fill styles and connector styles.
- Out of scope: importers and exporters; shapes regenerated per animation frame; extension code inside documents.

**Bundle.** An extension is a folder, `<name>.dottieext/`, in `~/Library/Application Support/Dottie/Extensions/`,
holding `manifest.json`, `main.js` and an icon. The manifest carries `id` (reverse-DNS), `name`, a semver `version`,
`dottieApi` (a major version, checked at load; an incompatible extension is listed with the reason and not loaded),
and a reserved `permissions` array for the third-party phase. The runtime loads `main.js` only. `require` resolves to
the modules bundled with Dottie (lodash, d3, dagre, dayjs) and to files inside the bundle, not to the shared
`Scripts/modules` folder, so a bundle is self-contained. Settings › Extensions lists them with an enable switch each.

**Runtime.** One long-lived `JSContext` per extension, created at load and recreated on reload. Shape functions
(`generate`, and the handle functions `position` and `drag`) are pure: plain data in, plain data out, no `dottie`
document object. They run synchronously on the main actor under a short execution limit using the existing
`JSContextGroupSetExecutionTimeLimit` hook. If one throws or times out, the element keeps its last good path and the
inspector shows the error. Commands run the way `run_script` does today: the full `dottie` object on a copy of the
document, written back only if the command finishes, as one undo step.

**Extension shapes.**

- Parameters are declared as a typed schema (`number` with range and default, `integer`, `boolean`, `enum`,
  `string`). Dottie builds the inspector from it and validates values before calling `generate`.
- `generate(params, frame)` returns normalized subpaths (the form `.path` already uses, with even-odd fill) in the
  element's own style, plus optional `ports` (normalized connection points) and an optional `labelRect`. Resizing
  calls `generate` again, so a cylinder's lip keeps its height instead of stretching.
- Handles (v1.1) each declare `position(params, frame)` and `drag(params, frame, point) → params`; Dottie calls
  `generate` on every drag step.
- The element stores `extension: { id, version, params }`, the subpaths, and the optional `ports` and `labelRect`.
- Extension shapes appear in the shape library under the extension's name. `add_shape`, `build_diagram` and
  `dottie.shape()` accept `{ extension, params }`.

**Connectors and labels.** `edgePoint` for every `.path` element changes to intersect the actual outline rather than
the bounding rectangle, which also fixes the built-in Basics stencils. When an element has `ports` or `labelRect`,
connectors and the label use them. dottie.js implements the same three behaviours.

**Commands.** A command optionally declares a parameter schema, from which Dottie builds a form sheet. Commands
appear in an Extensions menu grouped by the manifest's category, in the canvas context menu when they declare
`when: "selection"`, and over MCP as `run_command`. Repeat Last Command reruns the previous one with the same
parameters. Manifests cannot declare keyboard shortcuts; users assign them in Settings.

**Versioning.** The stored path is the truth until someone edits the shape: a newer extension never rewrites a
document just because it was opened. Editing an older shape first runs the extension's optional
`migrate(fromVersion, params) → params`, then fills missing parameters from defaults and drops unknown ones. A
per-document "Update Shapes from Extensions" command regenerates everything on request.

**Authoring and agents.** Dottie ships `dottie-extension.d.ts`, a template bundle with a small build script for
anyone writing TypeScript, and `dottie ext check <bundle>`, an advisory type check through the existing `tsc` path.
The Extensions folder is watched and reloads on change. MCP gains `list_extensions`, `reload_extensions` and
`install_extension(path)`; load and `generate` errors appear in the Script Console and in MCP results.

## Considered options

- **Running extension code at draw time**, the way Symbols expand. Shapes could react to animation time, but every
  renderer, QuickLook and the web player would need to run extension code, files would not render without the
  extension, and untrusted code would run just to preview a file.
- **A new `kind: "extension"`.** Clearer in the file, but `ElementKind` decodes strictly, so every existing build and
  QuickLook on another Mac would refuse to open the whole document.
- **Several styled parts and text runs per shape.** Would cover gauges and UML classes, but a single path maps
  straight onto `.path` and is enough to start. A later output format can add parts.
- **A single `.js` file per extension.** Simpler, but a folder leaves room for the icon, the manifest, permissions and
  bundled files without a later format change.
- **Embedding extension code in documents.** Makes files self-contained, but opening a file would run its code.
- **Compiling `main.ts` inside Dottie.** Convenient, but makes the bundle format depend on Dottie having `tsc`.
- **Shortcuts in the manifest.** Sketch did this and plugins fought over keys.

Precedents: Inkscape `.inx` and Figma `parameters` for schema-generated forms; Figma relaunch data for linking a shape
back to its generator; VS Code `engines` and Figma `api` for the API version check; Keynote and PowerPoint
adjustment handles; Inkscape "Repeat last extension".

## Consequences

- An older Dottie, or one without the extension, draws extension shapes correctly but treats them as plain paths, and
  saving there drops the `extension` field. The shape then stays a plain path.
- Animating a frame's width or height rescales the stored path, so extension shapes stretch during resize keyframes.
  Draw-on, follow-path and Magic Move work because the shape is a path. Parameters are not keyable.
- dottie.js needs the outline-based `edgePoint` and support for `ports` and `labelRect`, with fixtures covering them,
  before extension shapes ship.
- The schema in `schema/dottie.schema.json` gains the optional `extension`, `ports` and `labelRect` fields.
- Drawing tools cannot be added as extensions until the `CanvasView` tool refactor is done.
