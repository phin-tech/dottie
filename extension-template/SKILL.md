---
name: dottie-extension
description: Write a Dottie extension, a JavaScript bundle that adds parametric shapes with adjustment handles, commands, or drawing tools to the Dottie diagram app. Use when asked to make, change or debug a Dottie extension, a custom Dottie shape, command or drawing tool, or a .dottieext bundle.
---

# Writing a Dottie extension

An extension is a folder `<name>.dottieext` holding `manifest.json` and `main.js`. Dottie runs `main.js` in
JavaScriptCore, where it declares what it adds through the `extension` global:

- **Shapes** (`extension.shape`): a parameter schema and a pure `generate(params, frame)` returning Bézier subpaths,
  with optional ports, a label rectangle and adjustment handles.
- **Commands** (`extension.command`): a `run(params)` that edits the drawing through the `dottie` object, as one undo
  step, from the Extensions menu or MCP's `run_command`.
- **Drawing tools** (`extension.tool`): a pure `draw(gesture)` that turns a press and drag into plain elements, shown
  in the toolbar.

This folder is the template to start from. `dottie-extension.d.ts` is the API, with every field documented: read it
before writing code. `src/main.ts` has one of each kind (an inset box with a corner handle, a "Row of boxes"
command, and the Ribbon pen tool) and `build.sh` compiles it to `main.js`.

## Steps

1. **Make the bundle.** Copy `manifest.json`, `dottie-extension.d.ts`, `build.sh` and `src/` from this folder into a
   new `<name>.dottieext` folder (leave SKILL.md behind). Give the manifest a reverse-DNS `id` of the user's
   (`com.example.template` is the template's), a `name` and `category`, and keep `"dottieApi": 1`. Replace the
   examples in `src/main.ts` with what the user asked for; keep the `/// <reference>` line.
2. **Build.** `./build.sh` in the bundle writes `main.js`. It needs `tsc` (`npm install -g typescript`). A user who
   would rather write plain JavaScript can write `main.js` directly and skip `src/` and the build.
3. **Check.** `dottie ext check <bundle>` loads it as the app does, generates every shape with its defaults, runs
   every command on an empty drawing, draws a short drag with every tool, and type-checks `src/main.ts`. The bundle is
   done when every line reads `ok`, the type check included. (`dottie` is the app's command-line tool:
   Homebrew installs it, otherwise Settings ▸ Command Line.)
4. **Install.** With Dottie's MCP server connected, `install_extension` with the bundle's absolute path; otherwise
   copy the bundle into `~/Library/Application Support/Dottie/Extensions/`. Installing refuses an id that is already
   there, so after the first install, rebuild into the installed copy and call `reload_extensions` (the app watches
   the folder and reloads by itself).
5. **Look at it.** Over MCP: `add_shape` with `extension`, `shape` and `params` puts a shape on a page, `run_command`
   runs a command, and `export_png` shows the result. Look at the PNG, fix what reads badly, rebuild, reload. A tool
   can only be dragged by hand in the app, so ask the user to try it.

## Rules the API doesn't spell out

- **Three coordinate spaces.** `generate` returns coordinates normalized to the frame (0 to 1 across, y down); handle
  `position` and `drag` work in points from the frame's top-left; a tool's gesture and the elements it draws are in
  canvas points.
- **A subpath is `[x0, y0]` then six numbers per cubic segment** (`c1x, c1y, c2x, c2y, x, y`). A straight edge is a
  cubic with its control points a third and two thirds along it, as `src/main.ts` does. Fill is even-odd, so a hole is
  a second subpath.
- **Shapes, handles and tools are pure.** Plain data in, plain data out, no `dottie` object, no state kept between
  calls, under a short time limit. Only commands get `dottie`; `dottie script-types <dir>` writes its full types as
  `dottie.d.ts`.
- **No file system, network or timers.** `require` loads files inside the bundle (`"./lib/geometry"`) and the
  modules bundled with Dottie: lodash, d3-*, dagre, dayjs.
- **The stored path is the truth.** Dottie saves the path `generate` returned, and every renderer (exports, QuickLook,
  the web player) draws that path without running the extension, so drawings open anywhere. Changing `generate`
  leaves existing shapes alone until they are edited, or until Extensions ▸ Update Shapes from Extensions.
- **Renaming or removing a parameter** needs the manifest's `version` raised and an `extension.migrate(fn)` that maps
  the old parameters to the new ones; parameters missing after it get their defaults.
- **No keyboard shortcuts.** Manifests can't assign them to commands or tools. A user can give a command one in
  macOS's System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts, by its Extensions menu title.
- **A command adding the extension's own shapes** calls `dottie.shape({ extension: { id, shape }, params, x, y,
  width, height })`, as the template's Row of boxes does.
