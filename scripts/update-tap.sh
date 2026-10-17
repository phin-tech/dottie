#!/usr/bin/env bash
# Points the Homebrew cask in phin-tech/homebrew-tap at a published Dottie release (default: the version in
# project.yml). The sha256 comes from the asset as GitHub serves it, which is what brew will check.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "tap: $*" >&2; exit 1; }

version="${1:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)}"
[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "not a version: $version"
asset="Dottie-$version.zip"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh release download "v$version" --repo phin-tech/dottie --pattern "$asset" --dir "$work" \
    || die "release v$version has no $asset"
sha=$(shasum -a 256 "$work/$asset" | cut -d' ' -f1)

gh repo clone phin-tech/homebrew-tap "$work/tap" -- --quiet
mkdir -p "$work/tap/Casks"
cat > "$work/tap/Casks/dottie.rb" <<CASK
cask "dottie" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/phin-tech/dottie/releases/download/v#{version}/Dottie-#{version}.zip"
  name "Dottie"
  desc "Hand-drawn style diagrams that AI agents can draw over MCP"
  homepage "https://github.com/phin-tech/dottie"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Dottie updates itself (Sparkle), so brew upgrade leaves it alone unless given --greedy.
  auto_updates true
  depends_on macos: :sonoma

  app "Dottie.app"
  binary "#{appdir}/Dottie.app/Contents/Helpers/dottie-cli", target: "dottie"

  zap trash: [
    "~/Library/Application Support/Dottie",
    "~/Library/Preferences/tech.phin.dottie.plist",
    "~/Library/Saved Application State/tech.phin.dottie.savedState",
  ]
end
CASK

cd "$work/tap"
if [[ -z $(git status --porcelain) ]]; then
    echo "The tap already has Dottie $version."
    exit 0
fi
git add Casks/dottie.rb
git commit --quiet -m "dottie v$version"
git pull --quiet --rebase
git push --quiet
echo "Tap updated: brew install --cask phin-tech/tap/dottie installs Dottie $version."
