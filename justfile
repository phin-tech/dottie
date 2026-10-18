set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Run DottieKit + MCP tests (headless)
test:
    swift test

# Drive the real canvas with synthesized mouse events (rotate, erase, stroke handles, resize)
canvas-test: gen
    xcodebuild -project Dottie.xcodeproj -scheme CanvasTests -destination 'platform=macOS' test

# Regenerate Dottie.xcodeproj from project.yml
gen:
    xcodegen generate --use-cache

# Regenerate the README's animation (Design/animation.gif, .mp4, .dottie) from scripts/readme-animation.js
readme-animation:
    swift build --product dottie-mcp
    swift build --product dottie
    scripts/make-demos.py readme

# Regenerate the feature demos in Design/demos from scripts/demos/*.js (or just the ones named)
demos *names:
    swift build --product dottie-mcp
    swift build --product dottie
    scripts/make-demos.py {{ if names == "" { "demos" } else { names } }}

# Regenerate fixtures/ (edge cases from scripts/make-fixtures.py, copies of Design/) and the goldens dottie.js is tested against
goldens:
    swift build --product dottie
    scripts/make-fixtures.py
    scripts/make-goldens.py

# Fail if fixtures/goldens is out of date with DottieKit (what CI runs on a Mac)
goldens-check:
    swift build --product dottie
    scripts/make-goldens.py --check

# Rebuild dottie.js and embed its player in DottieKit (Sources/DottieKit/PlayerScript.swift), for dottie render -f js
player-script:
    cd web && npm ci --silent && npm run build
    scripts/update-player-script.py

# Build dottie.js (web/) and run its unit and contract tests
web-test:
    cd web && npm ci --silent && npm test

# Preview the Pages site locally (needs: pip install -r website/requirements.txt)
site:
    mkdocs serve -f website/mkdocs.yml

# Launch a Debug build on its own live socket, for scripts/dottie-debug.py to drive (snapshots, playhead, actions)
# (in the background, so it doesn't take focus; files open through the debug socket once it's up)
debug-app *files: build
    open -n -g --env DOTTIE_LIVE_SOCKET="$HOME/Library/Application Support/Dottie/debug.sock" "$(xcodebuild -project Dottie.xcodeproj -scheme Dottie -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Dottie.app"
    for f in {{files}}; do scripts/dottie-debug.py --wait 3 open "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"; done

# Send a command to the Debug build started by debug-app (try: just debug help)
debug *args:
    scripts/dottie-debug.py {{args}}

# Build the macOS app
build: gen
    xcodebuild -project Dottie.xcodeproj -scheme Dottie build

# Build and launch the app
run: build
    open "$(xcodebuild -project Dottie.xcodeproj -scheme Dottie -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Dottie.app"

# Build the dottie-mcp server (release)
mcp:
    swift build -c release --product dottie-mcp

# Register dottie-mcp with Claude Code
mcp-install: mcp
    claude mcp add dottie -- "$(swift build -c release --product dottie-mcp --show-bin-path)/dottie-mcp"

# Build the dottie command-line tool (release)
cli:
    swift build -c release --product dottie

# Link the built dottie tool into ~/.local/bin
cli-install: cli
    mkdir -p ~/.local/bin
    ln -sf "$(swift build -c release --product dottie --show-bin-path)/dottie" ~/.local/bin/dottie

# Remove build artifacts and the generated Xcode project
clean:
    rm -rf .build DerivedData Dottie.xcodeproj

# Release tooling: app-release (https://git.phin.tech/sam/app-release), pinned in scripts/release and run with uv;
# release.toml says what it needs to know, scripts/release/hooks.py adds dottie.js's steps. Each recipe takes
# --dry-run, which checks and reads but only prints what it would change. `just release-tool --help` lists it all.
release_tool := "uv run --quiet --project scripts/release app-release"

# Run app-release directly
[positional-arguments]
release-tool *args:
    {{release_tool}} "$@"

# Check everything a release needs outside the repo: tools, GitHub, the tap, 1Password, certificates
doctor:
    {{release_tool}} doctor

# Draft release-notes/<version>.md with a cheap model, from the commits since the last release (patch, minor, major, beta [--of patch], or a version)
[positional-arguments]
notes *args:
    {{release_tool}} notes "$@"

# Bump the version (major, minor, patch, or beta: 0.6.1 -> 0.7.0-beta.1 -> -beta.2; beta --of patch: 0.6.2-beta.1) everywhere, and the build number
[positional-arguments]
bump part *args:
    {{release_tool}} bump "$@"

# Point the Homebrew cask in phin-tech/homebrew-tap at a published release (default: the current version; never a beta)
[positional-arguments]
tap *args:
    {{release_tool}} tap "$@"

# Publish the newest notarized Dottie.app (Xcode: Archive, then Distribute App ▸ Direct Distribution), or a given app, as a GitHub release
[positional-arguments]
release *args:
    {{release_tool}} release "$@"

# Build, sign with Developer ID, notarize and staple Dottie.app headless (one-time: xcrun notarytool store-credentials dottie-notary)
[positional-arguments]
notarize *args:
    {{release_tool}} notarize "$@"

# The whole release: bump, commit, push, npm, notarize, GitHub release, appcast, cask (`ship beta [--of patch|major]`: a pre-release, no cask)
[positional-arguments]
ship part *args:
    {{release_tool}} ship "$@"

# Make and upload the Sparkle appcast for a published release (default: the current version); `just release` does this
[positional-arguments]
appcast *args:
    {{release_tool}} appcast "$@"

# Check release.toml, the hooks and the version files (no network, changes nothing)
release-check:
    {{release_tool}} check
