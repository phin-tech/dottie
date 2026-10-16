// Bundles dottie.js with esbuild: the ES module library, the <dottie-player> script (module and classic), and
// type declarations.
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { LOADER } from "./src/compile.ts";

const { version } = JSON.parse(readFileSync(new URL("./package.json", import.meta.url)));
const banner = { js: `/*! dottie.js ${version} | Apache-2.0 | https://github.com/phin-tech/dottie */` };
const common = { bundle: true, target: "es2020", banner, logLevel: "warning", legalComments: "none" };

await Promise.all([
  build({ ...common, entryPoints: ["src/index.ts"], format: "esm", outfile: "dist/dottie.js" }),
  build({ ...common, entryPoints: ["src/player-entry.ts"], format: "esm", outfile: "dist/dottie-player.js" }),
  build({ ...common, entryPoints: ["src/player-entry.ts"], format: "iife", minify: true, outfile: "dist/dottie-player.min.js" }),
  build({ ...common, entryPoints: ["src/compile.ts"], format: "esm", outfile: "dist/compile.js" }),
  build({ ...common, entryPoints: ["src/cli.ts"], format: "esm", platform: "node", outfile: "dist/dottie-compile.mjs",
    banner: { js: "#!/usr/bin/env node\n" + banner.js } }),
]);
// What follows the runtime in a compiled drawing; DottieKit embeds it with the runtime (scripts/update-player-script.py).
writeFileSync("dist/dottie-loader.js", LOADER);
execFileSync("npx", ["tsc", "-p", "tsconfig.build.json"], { stdio: "inherit" });
console.log("built dist/");
