// Compiling a drawing: one classic script holding the <dottie-player> runtime and the drawing, which puts a player
// where its <script> tag is. `dottie-compile` (npm) and `dottie render -f js` (the Mac tool) write the same thing:
// the runtime (dist/dottie-player.min.js), then LOADER with the drawing and the player's attributes filled in.
//
//   <script src="tour.js"></script>                         a player here
//   <script src="tour.js" data-target="#demo"></script>     a player inside #demo
//   <script src="tour.js" data-clean data-no-loop></script>  data-* attributes become the player's attributes

import { fontFaces, usedFonts } from "./fonts.ts";
import type { Face } from "./metrics.ts";
import { DottieFormatError, parseDottie } from "./model.ts";
import { pageIndex } from "./player.ts";

/** What follows the runtime; DOTTIE_DATA and DOTTIE_OPTIONS are replaced with JSON. Plain ES5, unminified. */
export const LOADER = `;(function () {
  var data = DOTTIE_DATA, options = DOTTIE_OPTIONS, fonts = DOTTIE_FONTS;
  var script = document.currentScript;
  if (window.Dottie.addFonts) window.Dottie.addFonts(Object.keys(fonts), fonts);
  function attr(el, name, value) { el.setAttribute(name.replace(/[A-Z]/g, function (c) { return "-" + c.toLowerCase(); }), value); }
  function mount() {
    var player = document.createElement("dottie-player"), k;
    for (k in options) attr(player, k, options[k]);
    if (script) for (k in script.dataset) if (k !== "target") attr(player, k, script.dataset[k]);
    var target = script && script.dataset.target ? document.querySelector(script.dataset.target) : null;
    if (target) target.appendChild(player);
    else if (script && script.parentNode && script.parentNode !== document.head) script.parentNode.insertBefore(player, script);
    else document.body.appendChild(player);
    player.setFile(window.Dottie.parseDottie(data));
  }
  if (document.readyState === "loading" && (!script || script.parentNode === document.head || script.dataset.target)) {
    document.addEventListener("DOMContentLoaded", mount);
  } else {
    mount();
  }
})();
`;

export interface CompileOptions {
  /** Page name or 1-based number; only that page goes in. The first page by default. */
  page?: string | number;
  /** Show this moment (seconds) as a still. */
  at?: number;
  clean?: boolean;
  noControls?: boolean;
  noAutoplay?: boolean;
  noLoop?: boolean;
  label?: string;
  /** A bundled font's file (`fontFile`) as base64, so the drawing carries the fonts it uses; without it the
   * player fetches them from beside itself. dottie-compile reads them from dist/fonts. */
  fontData?: (family: string, face: Face) => string | undefined;
}

/** JSON safe inside a script: it can't close the tag or start a comment. */
export function scriptJSON(value: unknown): string {
  return JSON.stringify(value).replace(/<\//g, "<\\/").replace(/<!--/g, "<\\!--").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
}

/** The player's attributes for `options`, as both compilers write them. */
export function playerAttributes(options: CompileOptions): Record<string, string> {
  const out: Record<string, string> = {};
  if (options.at !== undefined) out.at = String(options.at);
  if (options.clean) out.clean = "";
  if (options.noControls) out["no-controls"] = "";
  if (options.noAutoplay) out["no-autoplay"] = "";
  if (options.noLoop) out["no-loop"] = "";
  if (options.label !== undefined) out.label = options.label;
  return out;
}

/** The compiled script for `source` (a .dottie file's text or parsed JSON). `runtime` is dottie-player.min.js. */
export function compile(source: string | unknown, runtime: string, options: CompileOptions = {}): string {
  let raw: unknown = source;
  if (typeof source === "string") {
    try { raw = JSON.parse(source); } catch (e) { throw new DottieFormatError(`Not JSON: ${(e as Error).message}`); }
  }
  const file = parseDottie(raw);   // refuses what isn't a drawing
  const json = raw as { version: number; pages: unknown[]; images?: Record<string, unknown> };
  const i = pageIndex(file, options.page === undefined ? null : String(options.page));
  const page = json.pages[i];
  // Only the pictures that page shows.
  const refs = new Set<string>();
  JSON.stringify(page, (k, v) => { if (k === "ref" && typeof v === "string") refs.add(v); return v; });
  const images = Object.fromEntries(Object.entries(json.images ?? {}).filter(([k]) => refs.has(k)));
  const data: Record<string, unknown> = { version: json.version, pages: [page] };
  if (Object.keys(images).length) data.images = images;
  // The bundled fonts that page uses, each face as base64.
  const fonts: Record<string, Record<string, string>> = {};
  for (const family of options.fontData ? usedFonts(file.pages[i]) : []) {
    for (const face of fontFaces(family)) {
      const b64 = options.fontData!(family, face);
      if (b64) (fonts[family] ??= {})[face] = b64;
    }
  }
  return runtime.trimEnd() + "\n" + LOADER.replace("DOTTIE_DATA", () => scriptJSON(data))
    .replace("DOTTIE_OPTIONS", () => scriptJSON(playerAttributes(options))).replace("DOTTIE_FONTS", () => scriptJSON(fonts));
}
