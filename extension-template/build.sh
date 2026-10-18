#!/bin/sh
# Compiles src/main.ts to main.js, the one file Dottie loads. Needs TypeScript (npm install -g typescript).
set -e
cd "$(dirname "$0")"
rm -rf build
tsc --target es2023 --lib es2023 --module es2022 --strict --outDir build src/main.ts
cp build/main.js main.js
rm -rf build
echo "wrote $(pwd)/main.js"
