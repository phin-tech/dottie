// dottie-compile: a .dottie file as one script that shows it (see compile.ts).

import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import { type CompileOptions, compile } from "./compile.ts";
import { parseDottie } from "./model.ts";
import { VERSION } from "./index.ts";

const usage = `dottie-compile ${VERSION}: a Dottie drawing as one script that plays it on any page.

USAGE
  dottie-compile <file.dottie> [-o <out.js>] [options]

  Then: <script src="drawing.js"></script> shows a player where the tag is. Add data-target="#id" to put it
  inside another element, and data-* attributes (data-clean, data-no-loop, ...) to set the player's attributes.

OPTIONS
  -o, --output <path>   Where to write it ("-" for stdout); default drawing.js next to the input
  -p, --page <page>     Page name or 1-based number; only that page is included (default the first)
      --at <seconds>    Show that moment as a still
      --clean           Draw precisely instead of sketchy
      --no-controls, --no-autoplay, --no-loop
      --label <text>    The player's accessible name
`;

function fail(message: string, code = 2): never {
  process.stderr.write(`dottie-compile: ${message}\n`);
  process.exit(code);
}

const args = process.argv.slice(2);
const options: CompileOptions = {};
let input: string | undefined, output: string | undefined;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  const value = (): string => (++i < args.length ? args[i] : fail(`${a} needs a value`));
  switch (a) {
    case "-h": case "--help": process.stdout.write(usage); process.exit(0);
    case "-v": case "--version": process.stdout.write(`dottie-compile ${VERSION}\n`); process.exit(0);
    case "-o": case "--output": output = value(); break;
    case "-p": case "--page": options.page = value(); break;
    case "--at": {
      const t = Number(value());
      if (!Number.isFinite(t) || t < 0) fail("--at must be a time in seconds");
      options.at = t;
      break;
    }
    case "--clean": options.clean = true; break;
    case "--no-controls": options.noControls = true; break;
    case "--no-autoplay": options.noAutoplay = true; break;
    case "--no-loop": options.noLoop = true; break;
    case "--label": options.label = value(); break;
    default:
      if (a.startsWith("-") || input) fail(`unknown option ${a}\n\n${usage}`);
      input = a;
  }
}
if (!input) fail(`needs a .dottie file\n\n${usage}`);

let source: string;
try { source = readFileSync(input, "utf8"); } catch { fail(`${input}: cannot read file`, 1); }
try {
  for (const w of parseDottie(source).warnings) process.stderr.write(`dottie-compile: ${input}: ${w}\n`);
  const runtime = readFileSync(new URL("./dottie-player.min.js", import.meta.url), "utf8");
  const js = compile(source, runtime, options);
  if (output === "-") process.stdout.write(js);
  else {
    const target = output ?? input.replace(/\.dottie$/i, "") + ".js";
    writeFileSync(target, js);
    process.stdout.write(`${target} (${Math.round(js.length / 1024)} KB): <script src="${basename(target)}"></script>\n`);
  }
} catch (e) {
  fail(`${input}: ${(e as Error).message}`, 1);
}
