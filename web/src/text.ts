// Text measurement as CoreText does it for Helvetica Neue: advance widths plus kerning, word wrapping, and line
// heights from rounded ascent, descent and leading. Used for connector label boxes and packet pills, so they come
// out the size Dottie makes them.

import { ascent, descent, fonts, leading } from "./metrics.ts";

export type Face = "regular" | "bold" | "italic" | "boldItalic";

/** Width of a run of text at `fontSize`, kerned. */
export function measure(s: string, fontSize: number, face: Face = "regular"): number {
  const f = fonts[face];
  const fallback = f.w["n"];
  let w = 0;
  let prev = "";
  for (const ch of s) {
    w += f.w[ch] ?? fallback;
    if (prev) w += f.k[prev + ch] ?? 0;
    prev = ch;
  }
  return (w * fontSize) / 1000;
}

/** First line's height, and each further line's, for the regular face (CoreText rounds each metric). */
export function lineHeights(fontSize: number): [number, number] {
  const a = Math.round(ascent * fontSize), d = Math.round(descent * fontSize), l = Math.round(leading * fontSize);
  return [a + d, a + d + l];
}

/** Lines `s` wraps into within `maxWidth`, breaking at spaces (or inside a word too long for a line). */
export function wrap(s: string, fontSize: number, maxWidth: number, face: Face = "regular"): string[] {
  const out: string[] = [];
  for (const para of s.split(/\r\n|\n|\r|\u2028|\u2029/)) {
    const words = para.match(/\S+\s*|\s+/g) ?? [""];
    let line = "";
    for (const word of words) {
      const candidate = line + word;
      if (line === "" || measure(candidate.trimEnd(), fontSize, face) <= maxWidth) { line = candidate; }
      else { out.push(line); line = word; }
      // A word wider than the line breaks between characters.
      while (measure(line.trimEnd(), fontSize, face) > maxWidth && [...line.trimEnd()].length > 1) {
        const chars = [...line];
        let n = chars.length - 1;
        while (n > 1 && measure(chars.slice(0, n).join(""), fontSize, face) > maxWidth) n--;
        out.push(chars.slice(0, n).join(""));
        line = chars.slice(n).join("");
      }
    }
    out.push(line);
  }
  return out;
}

/** The size CoreText suggests for `s` wrapped at `maxWidth`, rounded up (Renderer.textSize). */
export function textSize(s: string, fontSize: number, maxWidth: number): { width: number; height: number } {
  if (s === "") return { width: 0, height: 0 };
  const lines = wrap(s, fontSize, maxWidth);
  const width = Math.max(...lines.map((l) => measure(l.trimEnd(), fontSize)));
  const [first, next] = lineHeights(fontSize);
  return { width: Math.ceil(width - 1e-9), height: Math.ceil(first + next * (lines.length - 1) - 1e-9) };
}
