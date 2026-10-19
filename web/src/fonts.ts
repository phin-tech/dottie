// The bundled handwriting fonts in the browser. dottie.js lays text out with their measurements (metrics.ts)
// whether or not they have loaded; this is what makes the browser draw them. A Playback adds the fonts its page
// uses, from the files that ship beside dottie.js (dist/fonts), or from a compiled drawing, which carries its own.

import type { Element, Page } from "./model.ts";
import { type Face, families } from "./metrics.ts";
import { BUNDLED_FONTS, bundledFamily } from "./text.ts";

const FACES: Face[] = ["bold", "boldItalic", "italic", "regular"];

/** A bundled font file's name in dist/fonts, e.g. "caveat-bold.woff2". */
export function fontFile(family: string, face: Face): string {
  return `${family.toLowerCase().replaceAll(" ", "-")}-${face}.woff2`;
}

/** The faces bundled for `family`. */
export function fontFaces(family: string): Face[] {
  return FACES.filter((f) => families[family]?.faces[f] !== undefined);
}

/** The bundled families text on `page` (and in its symbols) is set in. */
export function usedFonts(page: Page): string[] {
  const used = new Set<string>();
  const add = (es: Element[]): void => { for (const e of es) { const b = bundledFamily(e.style.font); if (b) used.add(b); } };
  add(page.elements);
  for (const s of page.symbols ?? []) add(s.elements);
  return BUNDLED_FONTS.filter((f) => used.has(f));
}

/** Where the font files are: `fonts/` beside the script that loaded dottie.js. */
function defaultBase(): string | null {
  try {
    const script = typeof document === "undefined" ? null : (document.currentScript as HTMLScriptElement | null);
    if (script?.src) return new URL("fonts/", script.src).href;
    const here: string | undefined = import.meta.url;   // undefined in the classic-script build
    return here ? new URL("fonts/", here).href : null;
  } catch {
    return null;
  }
}

let base = defaultBase();
const added = new Set<string>();

/** Serves the font files from `url` (a folder) instead of the one beside dottie.js. */
export function setFontBase(url: string): void {
  base = url.endsWith("/") ? url : `${url}/`;
}

/** Adds `fonts` to the document, once each: from `data` (base64 WOFF2 by family and face) when it has them, else
 * from the font files, which the browser fetches when text first needs them. */
export function addFonts(fonts: string[], data: Record<string, Partial<Record<Face, string>>> = {}): void {
  if (typeof document === "undefined" || typeof FontFace === "undefined" || !document.fonts) return;
  for (const name of fonts) {
    const family = bundledFamily(name);
    if (!family || added.has(family)) continue;
    const own = data[family];
    if (!own && !base) continue;
    added.add(family);
    for (const face of fontFaces(family)) {
      const encoded = own?.[face];
      let source: string | Uint8Array;
      if (encoded) source = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
      else if (!own) source = `url(${JSON.stringify(base + fontFile(family, face))}) format("woff2")`;
      else continue;
      const descriptors = { weight: face.startsWith("bold") ? "bold" : "normal", style: face === "italic" || face === "boldItalic" ? "italic" : "normal" };
      document.fonts.add(new FontFace(family, source as BufferSource | string, descriptors));
    }
  }
}
