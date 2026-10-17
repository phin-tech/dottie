#!/usr/bin/env bash
# Publishes a notarized, stapled Dottie.app as a GitHub release tagged v<CFBundleShortVersionString>, at the
# commit on main. With no argument it takes the newest one Xcode notarized: after Distribute App ▸ Direct
# Distribution, the Organizer keeps that copy in <archive>.xcarchive/Submissions/<id>/Dottie.app.
set -euo pipefail

die() { echo "release: $*" >&2; exit 1; }

app="${1:-}"
if [[ -z $app ]]; then
    archives="$HOME/Library/Developer/Xcode/Archives"
    app=$(find "$archives" -maxdepth 5 -type d -path '*.xcarchive/Submissions/*/Dottie.app' -print0 2>/dev/null \
        | xargs -0 stat -f '%m%t%N' | sort -rn | head -1 | cut -f2-)
    [[ -n $app ]] || die "no notarized Dottie.app under $archives; archive, then Distribute App ▸ Direct Distribution"
    echo "Using $app"
fi
app="${app%/}"
[[ -d $app && $(basename "$app") == Dottie.app ]] || die "$app is not a Dottie.app"

plist="$app/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null) == tech.phin.dottie ]] \
    || die "$app is not Dottie (bundle id)"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null) \
    || die "$app has no version; it was archived before MARKETING_VERSION was set, so archive again"
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || echo "?")
tag="v$version"

# What users will run: a valid signature, Developer ID, notarized, with the ticket stapled for offline launch.
codesign --verify --deep --strict "$app" || die "the signature does not verify"
assessment=$(spctl --assess --type execute -vv "$app" 2>&1) || die "Gatekeeper rejects it: $assessment"
grep -q "source=Notarized Developer ID" <<<"$assessment" || die "not a notarized Developer ID app: $assessment"
xcrun stapler validate "$app" >/dev/null 2>&1 || die "no notarization ticket is stapled"

# The tag goes on the commit the app was built from, so that commit must be main, clean and pushed.
cd "$(dirname "$0")/.."
[[ $(git branch --show-current) == main ]] || die "not on main"
if ! git diff --quiet || ! git diff --cached --quiet; then die "there are uncommitted changes"; fi
git fetch --quiet origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "main is not the same as origin/main; push or pull first"
project=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
[[ $project == "$version" ]] || die "the app is $version but project.yml is $project; archive again from this commit"
if gh release view "$tag" >/dev/null 2>&1; then
    die "release $tag already exists; bump MARKETING_VERSION in project.yml"
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
zip="$out/Dottie-$version.zip"
# ditto keeps the bundle's symlinks, permissions and signature intact, unlike zip.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
sum=$(shasum -a 256 "$zip" | cut -d' ' -f1)

# Notes come from release-notes/<version>.md when there is one, and are generated from the commits since the
# previous release otherwise.
notes=release-notes/$version.md
if [[ -f $notes ]]; then notes_flags=(--notes-file "$notes"); else notes_flags=(--generate-notes); fi
gh release create "$tag" "$zip" --target "$(git rev-parse HEAD)" --title "Dottie $version" "${notes_flags[@]}" >/dev/null
echo "Released $tag (build $build): Dottie-$version.zip, sha256 $sum"
gh release view "$tag" --json url -q .url

# The Sparkle appcast, so installed copies update in place; if this fails, `just appcast` retries it.
scripts/appcast.sh "$version"

# The Homebrew cask; if this fails, `just tap` retries it.
scripts/update-tap.sh "$version"
