#!/usr/bin/env bash
# Builds a Developer ID signed, notarized, stapled Dottie.app from this checkout, headless: what Xcode's
# Archive ▸ Distribute App ▸ Direct Distribution does by hand. Prints the app's path on its last line, which is
# what `just release <app>` takes.
#
# Notarization credentials come from 1Password, so any Mac signed in to `op` (and holding the Developer ID
# certificate) can release: the Apple ID, team and app-specific password in the item
# op://Development/Mac App Release (fields apple_id, team_id, app_specific_password; its notes explain it all). Override the item with
# NOTARY_OP_ITEM (an op:// prefix, without the field name). Without `op`, it falls back to a notarytool keychain
# profile (NOTARY_PROFILE, default dottie-notary), made with:
#   xcrun notarytool store-credentials dottie-notary --apple-id <you> --team-id J35P7AJDN7
# Override the team with DEVELOPMENT_TEAM.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "notarize: $*" >&2; exit 1; }

profile="${NOTARY_PROFILE:-dottie-notary}"
team="${DEVELOPMENT_TEAM:-J35P7AJDN7}"
version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"$/\1/p' project.yml)
[[ -n $version && -n $build ]] || die "cannot read the version from project.yml"

security find-identity -v -p codesigning | grep -q "Developer ID Application.*($team)" \
    || die "no Developer ID Application certificate for team $team in the keychain"
item="${NOTARY_OP_ITEM:-op://Development/Mac App Release}"
if command -v op >/dev/null && apple_id=$(op read "$item/apple_id" 2>/dev/null) \
    && password=$(op read "$item/app_specific_password" 2>/dev/null); then
    team="$(op read "$item/team_id" 2>/dev/null || echo "$team")"
    auth=(--apple-id "$apple_id" --team-id "$team" --password "$password")  # notarytool does not expand @env:, so this shows in ps while it runs
    echo "Notarizing as $apple_id (credentials from 1Password)."
else
    auth=(--keychain-profile "$profile")
    xcrun notarytool history "${auth[@]}" >/dev/null 2>&1 \
        || die "no 1Password item at $item (is \`op\` signed in?) and no notarytool profile '$profile'; see the top of this script"
fi

out=build/release/$version
rm -rf "$out"
mkdir -p "$out"

xcodegen generate --quiet --use-cache

echo "Archiving Dottie $version ($build)..."
xcodebuild archive -project Dottie.xcodeproj -scheme Dottie -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$out/Dottie.xcarchive" \
    DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates -quiet

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/Dottie.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates -quiet
app="$out/export/Dottie.app"
[[ -d $app ]] || die "export produced no Dottie.app"

echo "Notarizing (usually a few minutes)..."
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/submit.zip"
xcrun notarytool submit "$out/submit.zip" "${auth[@]}" --wait --output-format plist >"$out/notary.plist" || true
status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$out/notary.plist" 2>/dev/null || echo unknown)
if [[ $status != Accepted ]]; then
    id=$(/usr/libexec/PlistBuddy -c 'Print :id' "$out/notary.plist" 2>/dev/null || true)
    [[ -n $id ]] && xcrun notarytool log "$id" "${auth[@]}" >&2 || true
    die "notarization $status"
fi
xcrun stapler staple "$app" >/dev/null
xcrun stapler validate "$app" >/dev/null
rm -f "$out/submit.zip"
echo "Notarized and stapled."
echo "$app"
