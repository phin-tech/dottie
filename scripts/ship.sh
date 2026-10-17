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

# Fail now, before anything is bumped or pushed, if 1Password cannot be read (locked, or the app needs a restart).
item="${NOTARY_OP_ITEM:-op://Development/Mac App Release}"
command -v op >/dev/null || die "the 1Password CLI (op) is not installed"
op read "$item/apple_id" >/dev/null || die "cannot read $item: unlock 1Password (restart the app if it was updated)"
if [[ -z ${SKIP_NPM:-} ]]; then
    [[ -n $(op read "$item/npm_token") ]] || die "npm_token in $item is empty; fill it in, or SKIP_NPM=1"
fi

scripts/bump.sh "$part"
version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
git add -A
git commit --quiet -m "Dottie $version"
git push --quiet origin main

# dottie.js goes to npm at the app's version; skip with SKIP_NPM=1. The token in
# op://Development/Mac App Release/npm_token is stage-only (npm no longer lets tokens publish straight to the
# registry): `npm stage publish` uploads the version and it goes live when you approve it with 2FA, at
# npmjs.com (the package's Staged tab) or `npm stage approve <id>`. The release does not wait for that. Without a
# token, set SKIP_NPM=1 and publish by hand.
staged=
if [[ -z ${SKIP_NPM:-} ]]; then
    npm_token=$(op read "$item/npm_token") || die "cannot read the npm token from 1Password"
    (cd web && env "npm_config_//registry.npmjs.org/:_authToken=$npm_token" npm stage publish) && staged=1
fi

app=$(scripts/notarize.sh | tail -1)
scripts/release.sh "$app"
if [[ -n $staged ]]; then
    echo
    echo "dottie.js $version is staged on npm, not live yet: approve it at npmjs.com (the package's staged versions)"
    echo "or run \`npm stage list\` then \`npm stage approve <id>\`."
fi
