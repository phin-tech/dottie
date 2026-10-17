#!/usr/bin/env bash
# One command release: bump, commit, push, publish dottie.js, build + notarize the app, publish the GitHub
# release and the Homebrew cask. Usage: scripts/ship.sh patch|minor|major
# Write release-notes/<next version>.md first if you want curated notes (otherwise they are generated).
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "ship: $*" >&2; exit 1; }
part="${1:-}"
[[ $part == major || $part == minor || $part == patch ]] || die "usage: ship.sh major|minor|patch"

[[ $(git branch --show-current) == main ]] || die "not on main"
git diff --quiet && git diff --cached --quiet || die "there are uncommitted changes"
git fetch --quiet origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "main is not the same as origin/main"

scripts/bump.sh "$part"
version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
git add -A
git commit --quiet -m "Dottie $version"
git push --quiet origin main

# dottie.js is published at the app's version; skip with SKIP_NPM=1.
if [[ -z ${SKIP_NPM:-} ]]; then (cd web && npm publish); fi

app=$(scripts/notarize.sh | tail -1)
scripts/release.sh "$app"
