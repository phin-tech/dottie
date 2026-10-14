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
    xcodegen generate

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

# Publish the newest notarized Dottie.app (Xcode: Archive, then Distribute App ▸ Direct Distribution), or `app`, as a GitHub release
release app="":
    scripts/release.sh "{{app}}"
