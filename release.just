# Release tooling: app-release (https://git.phin.tech/sam/app-release), pinned in scripts/release and run with uv;
# release.toml says what it needs to know. Each recipe takes --dry-run, which checks and reads but only prints what it
# would change.
# `just release-tool --help` lists it all. The project's justfile has `import 'release.just'`; apple-template keeps
# this file up to date (`copier update`), so recipes of the project's own go in the justfile.
release_tool := "uv run --quiet --project scripts/release app-release"

# Run app-release directly
[positional-arguments]
release-tool *args:
    {{release_tool}} "$@"

# Check release.toml and the version files (no network, changes nothing)
release-check:
    {{release_tool}} check

# Check everything a release needs outside the repo: tools, GitHub, the tap, the download page, 1Password, certificates
[positional-arguments]
doctor *args:
    {{release_tool}} doctor "$@"

# Draft release-notes/<version>.md with a cheap model, from the commits since the last release (patch, minor, major, beta [--of patch], or a version)
[positional-arguments]
notes *args:
    {{release_tool}} notes "$@"

# Bump the version (major, minor, patch, or beta: 0.6.1 -> 0.7.0-beta.1 -> -beta.2; beta --of patch: 0.6.2-beta.1) everywhere and the build number; build: only the build number
[positional-arguments]
bump part *args:
    {{release_tool}} bump "$@"

# Build, sign with Developer ID, notarize and staple Dottie.app headless
[positional-arguments]
notarize *args:
    {{release_tool}} notarize "$@"

# Publish the newest notarized Dottie.app (from `just notarize` or Xcode's Distribute App), or a given app, as a GitHub release and on the download page
[positional-arguments]
release *args:
    {{release_tool}} release "$@"

# Make and upload the Sparkle appcast for a published release (default: the current version); `just release` does this
[positional-arguments]
appcast *args:
    {{release_tool}} appcast "$@"

# Point the Homebrew cask in phin-tech/homebrew-tap at a published release (default: the current version; never a beta)
[positional-arguments]
tap *args:
    {{release_tool}} tap "$@"

# The whole release: bump, commit, push, notarize, GitHub release, appcast, cask, the download page (`ship beta [--of patch|major]`: a pre-release, no cask). Ship from main
[positional-arguments]
ship part *args:
    {{release_tool}} ship "$@"
