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

# Bump the version (major, minor or patch) in project.yml and the tools, and the build number
bump part:
    scripts/bump.sh "{{part}}"

# Point the Homebrew cask in phin-tech/homebrew-tap at a published release (default: the current version)
tap version="":
    scripts/update-tap.sh {{version}}

# Publish the newest notarized Dottie.app (Xcode: Archive, then Distribute App ▸ Direct Distribution), or `app`, as a GitHub release
release app="":
    scripts/release.sh "{{app}}"

# Build, sign with Developer ID, notarize and staple Dottie.app headless (one-time: xcrun notarytool store-credentials dottie-notary)
notarize:
    scripts/notarize.sh

# The whole release in one command: bump, commit, push, npm publish, notarize, GitHub release, Homebrew cask
ship part:
    scripts/ship.sh "{{part}}"
