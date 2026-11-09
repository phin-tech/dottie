// Bundles dottie.js with esbuild: the ES module library, the <dottie-player> script (module and classic), and
// type declarations.
import { build } from "esbuild";
import { execFileSync } from "node:child_process";
import { cpSync, readFileSync, writeFileSync } from "node:fs";
import { LOADER } from "./src/compile.ts";

const { version } = JSON.parse(readFileSync(new URL("./package.json", import.meta.url)));
const banner = { js: `/*! dottie.js ${version} | Apache-2.0 | https://github.com/phin-tech/dottie */` };
const common = { bundle: true, target: "es2020", banner, logLevel: "warning", legalComments: "none" };

await Promise.all([
  build({ ...common, entryPoints: ["src/index.ts"], format: "esm", outfile: "dist/dottie.js" }),
  // The module player plans big animations in a worker running dottie-player.min.js from beside it (planner.ts).
  build({ ...common, entryPoints: ["src/player-entry.ts"], format: "esm", outfile: "dist/dottie-player.js",
    define: { __DOTTIE_WORKER__: '"sibling"' } }),
  // A classic script has no import.meta; it finds its fonts from document.currentScript instead (fonts.ts), and
  // starts its worker from its own source, so it is wrapped in a function that can be read back (below).
  build({ ...common, entryPoints: ["src/player-entry.ts"], format: "iife", minify: true, outfile: "dist/dottie-player.min.js",
    define: { "import.meta.url": "undefined", __DOTTIE_WORKER__: '"self"' } }),
  // The simulation DottieKit runs in JavaScriptCore (scripts/update-player-script.py, SimulationEngine.swift).
  build({ ...common, entryPoints: ["src/sim-entry.ts"], format: "iife", minify: true, outfile: "dist/dottie-sim.min.js" }),
  // Click logic (ADR 0007): the QuickJS engine, loaded only for a page with logic it may run (logic.ts).
  build({ ...common, entryPoints: ["src/logic-entry.ts"], format: "iife", minify: true, outfile: "dist/dottie-logic.min.js" }),
  build({ ...common, entryPoints: ["src/compile.ts"], format: "esm", outfile: "dist/compile.js" }),
  build({ ...common, entryPoints: ["src/cli.ts"], format: "esm", platform: "node", outfile: "dist/dottie-compile.mjs",
    banner: { js: "#!/usr/bin/env node\n" + banner.js } }),
]);
// The classic script as one named function, which planner.ts turns back into source for a worker of itself.
{
  const path = "dist/dottie-player.min.js";
  const [first, ...rest] = readFileSync(path, "utf8").split("\n");
  if (!first.startsWith("/*!")) throw new Error(`${path} doesn't start with its banner`);
  writeFileSync(path, `${first}\n(function dottiePlayerScript(){${rest.join("\n").trimEnd()}})();\n`);
}
// The bundled fonts and their licenses, served from beside the scripts.
cpSync("fonts", "dist/fonts", { recursive: true });
// What follows the runtime in a compiled drawing; DottieKit embeds it with the runtime (scripts/update-player-script.py).
writeFileSync("dist/dottie-loader.js", LOADER);
execFileSync("npx", ["tsc", "-p", "tsconfig.build.json"], { stdio: "inherit" });
console.log("built dist/");
