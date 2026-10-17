#!/usr/bin/env bash
# Prints the directory holding Sparkle's command-line tools (sign_update, generate_keys), downloading the
# pinned release into build/sparkle on first use. The version matches the Sparkle package in project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

version=2.10.0
sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
dir=build/sparkle/$version

if [[ ! -x $dir/bin/sign_update ]]; then
    rm -rf "$dir"; mkdir -p "$dir"
    gh release download "$version" --repo sparkle-project/Sparkle --pattern "Sparkle-$version.tar.xz" --dir "$dir" >&2
    [[ $(shasum -a 256 "$dir/Sparkle-$version.tar.xz" | cut -d' ' -f1) == "$sha256" ]] \
        || { echo "sparkle-tools: checksum mismatch for Sparkle-$version.tar.xz" >&2; rm -rf "$dir"; exit 1; }
    tar -xf "$dir/Sparkle-$version.tar.xz" -C "$dir"
fi
echo "$PWD/$dir/bin"
