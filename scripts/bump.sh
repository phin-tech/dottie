#!/usr/bin/env bash
# Bumps the release version: MARKETING_VERSION in project.yml (the app) and DottieVersion (the dottie tool
# and the MCP server), and adds one to the build number. Then regenerates the Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."

part="${1:-}"
[[ $part == major || $part == minor || $part == patch ]] || { echo "usage: just bump major|minor|patch" >&2; exit 2; }

current=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"$/\1/p' project.yml)
[[ $current =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[0-9]+$ ]] || { echo "bump: cannot read the version from project.yml" >&2; exit 1; }

IFS=. read -r major minor patch <<<"$current"
case $part in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
esac
next="$major.$minor.$patch"
build=$((build + 1))

sed -i '' "s/^\( *MARKETING_VERSION: \)\".*\"$/\1\"$next\"/" project.yml
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: \)\".*\"$/\1\"$build\"/" project.yml
sed -i '' "s/\(static let current = \)\".*\"/\1\"$next\"/" Sources/DottieKit/Version.swift

if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi
echo "$current -> $next (build $build). Commit and push, then archive in Xcode and run just release."
