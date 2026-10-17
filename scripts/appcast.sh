#!/usr/bin/env bash
# Makes the Sparkle appcast for a published release and uploads it to that release as appcast.xml. The app's feed
# is releases/latest/download/appcast.xml, so the newest release's appcast is what installed copies read, and it
# only needs the newest version. The zip is downloaded from the release and signed there, so the signature is
# for exactly the bytes people get. The private key is in op://Development/Mac App Release/sparkle_private_key.
# Usage: scripts/appcast.sh [version]   (default: the version in project.yml); DRY_RUN=1 prints it instead of uploading
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "appcast: $*" >&2; exit 1; }

version="${1:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)}"
tag="v$version"
item="${NOTARY_OP_ITEM:-op://Development/Mac App Release}"
tools=$(scripts/sparkle-tools.sh)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh release download "$tag" --pattern "Dottie-$version.zip" --dir "$work" || die "release $tag has no Dottie-$version.zip"
zip="$work/Dottie-$version.zip"
ditto -x -k "$zip" "$work/app"
plist="$work/app/Dottie.app/Contents/Info.plist"
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || echo 14.0)
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") == "$version" ]] || die "the zip is not Dottie $version"

# sign_update prints: sparkle:edSignature="..." length="..."
signature=$("$tools/sign_update" --ed-key-file <(op read "$item/sparkle_private_key") "$zip") \
    || die "could not sign; is \`op\` signed in with access to the Development vault?"
[[ $signature == *edSignature=* ]] || die "unexpected sign_update output: $signature"

# The release notes, as GitHub renders them.
body=$(gh release view "$tag" --json body -q .body)
notes=$(gh api markdown -f text="$body" -f mode=gfm -f context=phin-tech/dottie 2>/dev/null) \
    || notes="<pre>$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' <<<"$body")</pre>"
notes=${notes//]]>/]]&gt;}

cat > "$work/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dottie</title>
    <item>
      <title>Dottie $version</title>
      <pubDate>$(date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <link>https://github.com/phin-tech/dottie/releases/tag/$tag</link>
      <description><![CDATA[$notes]]></description>
      <enclosure url="https://github.com/phin-tech/dottie/releases/download/$tag/Dottie-$version.zip" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$work/appcast.xml" || die "the appcast is not valid XML"
edsig=$(sed -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<<"$signature")
"$tools/sign_update" --verify --ed-key-file <(op read "$item/sparkle_private_key") "$zip" "$edsig" >/dev/null \
    || die "the signature does not verify against the zip"

if [[ -n ${DRY_RUN:-} ]]; then cat "$work/appcast.xml"; echo "(dry run: not uploaded)"; exit 0; fi
gh release upload "$tag" "$work/appcast.xml" --clobber
echo "Appcast for $version (build $build) uploaded to $tag."
