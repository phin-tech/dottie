# AGENTS.md

Dottie draws sketchy or clean diagrams stored as `.dottie` JSON. One model, `Sources/DottieKit`, feeds the macOS app
(`App/`), the `dottie` CLI, the MCP server, QuickLook, and dottie.js (`web/`), the TypeScript player for the web.

## Where things are explained

- `DEVELOPMENT.md`: building, testing, releasing, the file format, scripting, MCP, extensions. Read the section for
  the area you are changing first.
- `CONTEXT.md`: the glossary (stencil, symbol, script, extension, extension shape, command, adjustment handle). Use
  its words in code, comments and docs.
- `docs/adr/`: decisions and their reasons. Read ADR 0001 before touching extensions.
- `web/PARITY.md`: what dottie.js must match, feature by feature.

## Parity

dottie.js draws exactly what the app draws, and the goldens in `fixtures/` prove it. A Swift change to geometry,
connectors, labels, the model or the file format is one change across both:

1. Mirror it in `web/src`. A new element field also goes in `schema/dottie.schema.json` and `KNOWN_FIELDS` in
   `web/src/model.ts`.
2. Add a case to `scripts/make-fixtures.py` that would fail without the change.
3. `just goldens`, and commit the regenerated goldens with the change.
4. After any `web/src` change, `just player-script`: HTML and js exports embed a minified dottie.js
   (`Sources/DottieKit/PlayerScript.swift`).

`fixtures/design/` holds copies of `Design/`, so a change to a drawing in `Design/` also needs `just goldens`.

## Done

The change is done when these pass, and your report names any you did not run:

- `just test`, `just web-test`, `just goldens-check`, always.
- `just build` and `just canvas-test` for changes under `App/` or to `project.yml`.
- `just release-check` for changes to `release.toml` or under `scripts/release` (app-release itself is its own
  repository, sam/app-release on git.phin.tech).

## Generated files

Edit the source and regenerate:

- `Dottie.xcodeproj` from `project.yml` (`just gen`).
- `Sources/DottieKit/PlayerScript.swift` from `web/` (`just player-script`).
- `Sources/DottieKit/BundledModules.swift` from `scripts/update-script-modules.py`.
- Version strings from `just bump` (bump-my-version; `.bumpversion.toml` lists the files).

## Gotchas

- `swift build` and `swift test` rewrite `Package.resolved` and drop its Sparkle pin, because Sparkle is an Xcode-only
  dependency. `git restore Package.resolved` before committing.
- A script or MCP API change spans three places, kept in step: the dispatcher and the `apiReference` text in
  `Sources/DottieKit/Script.swift`, the TypeScript declarations in `ScriptTypes.swift`, and, for MCP, the tool schema
  in `Sources/DottieMCP/DottieTools.swift`.
- `skills/dottie/SKILL.md` and `extension-template/SKILL.md` are skills users install with `npx skills add
  phin-tech/dottie`. A change to the MCP tools, the `dottie` command or the extension API updates the one they name.
- Extension code runs only when a shape is created or edited; every renderer draws the stored path (ADR 0001). Keep
  JavaScript on the edit path.
- An agent session's `dottie` MCP server is whatever was installed when the session started, so it can lag this
  checkout. To try new MCP behaviour, run this checkout's `.build/arm64-apple-macosx/debug/dottie-mcp`.
- Xcode's build service sometimes hangs at 0% CPU, which is not a Dottie bug. Give `xcodebuild` and `just build` a
  timeout.
- To see the app: `just debug-app file.dottie`, then `just debug snapshot out.png`, then `just debug quit`. Leave
  other Dottie processes running; the maintainer may have their own copy open.

## Releases

The maintainer releases with `just ship patch|minor|major|beta`; leave releases, version bumps and pushes to them
unless asked. Every release recipe takes `--dry-run`, which runs the checks and reads and prints the rest.
