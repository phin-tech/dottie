// Text measurement as CoreText does it: advance widths plus kerning, word wrapping, and line heights from rounded
// ascent, descent and leading, for Helvetica Neue and the bundled handwriting fonts (Fonts.swift). Used for
// connector label boxes, packet pills and notes, so they come out the size Dottie makes them.

import { type Face, type FamilyMetrics, families } from "./metrics.ts";

export type { Face };

export const DEFAULT_FAMILY = "Helvetica Neue";
const CSS_FALLBACK = "Helvetica Neue, Helvetica, Arial, sans-serif";

/** The bundled handwriting fonts, by name. */
export const BUNDLED_FONTS: readonly string[] = Object.keys(families).filter((f) => f !== DEFAULT_FAMILY).sort();

/** The bundled family `font` (an element's `style.font`) names, matched without regard to case. */
export function bundledFamily(font: string | null | undefined): string | null {
  if (!font) return null;
  const lower = font.toLowerCase();
  return BUNDLED_FONTS.find((f) => f.toLowerCase() === lower) ?? null;
}

/** The measurements text in `font` is laid out with: a bundled font's own, else Helvetica Neue's (a font of one's
 * own isn't embedded, and dottie.js can't measure it, so it is laid out as Helvetica Neue). */
export function familyMetrics(font: string | null | undefined): FamilyMetrics {
  return families[bundledFamily(font) ?? DEFAULT_FAMILY];
}

/** The face text that is `bold` and `italic` is set in: that face, or regular when the font lacks it. */
export function faceOf(fam: FamilyMetrics, bold: boolean, italic: boolean): Face {
  const want: Face = bold ? (italic ? "boldItalic" : "bold") : italic ? "italic" : "regular";
  return fam.faces[want] ? want : "regular";
}

/** The SVG `font-family` for text in `font`: its name, then the fallbacks (Fonts.cssFamily). */
export function cssFamily(font: string | null | undefined): string {
  if (!font) return CSS_FALLBACK;
  const name = [...(bundledFamily(font) ?? font)].filter((c) => !"\"'<>&;{}\\".includes(c)).join("");
  if (name === "") return CSS_FALLBACK;
  return `${/^[\p{L}\p{N} -]+$/u.test(name) ? name : `'${name}'`}, ${CSS_FALLBACK}`;
}

/** Width of a run of text at `fontSize`, kerned. */
export function measure(s: string, fontSize: number, face: Face = "regular", font?: string | null): number {
  const fam = familyMetrics(font);
  const f = fam.faces[face] ?? fam.faces.regular;
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

/** Height of one line, and what each further line adds, for the regular face: CoreText puts baselines on
 * rounded ascents, descents and leadings, and the frame ends below the last line's descent, rounded up. */
export function lineHeights(fontSize: number, font?: string | null): [number, number] {
  const m = familyMetrics(font).faces.regular;
  const a = Math.round(m.ascent * fontSize), d = Math.round(m.descent * fontSize), l = Math.round(m.leading * fontSize);
  return [a + Math.ceil(m.descent * fontSize - 1e-9), a + d + l];
}

/** Whether a line may break after `ch` when `next` follows (Unicode line breaking as CoreText does it: after
 * a space, and after a slash or hyphen not followed by a digit, a space or another of itself). */
export function breaksAfter(ch: string, next: string): boolean {
  if (ch === " ") return true;
  return (ch === "/" || ch === "-") && next !== "" && !/[\d\s/-]/.test(next);
}

/** `para` cut into pieces that each end where a line may break. */
function pieces(para: string): string[] {
  const chars = [...para];
  const out: string[] = [];
  let cur = "";
  chars.forEach((ch, i) => {
    cur += ch;
    const next = chars[i + 1] ?? "";
    // Spaces stay with the piece they follow, so they hang at the end of a line.
    if (breaksAfter(ch, next) && next !== " ") { out.push(cur); cur = ""; }
  });
  if (cur || out.length === 0) out.push(cur);
  return out;
}

/** Lines `s` wraps into within `maxWidth` (or inside a piece too long for a line). */
export function wrap(s: string, fontSize: number, maxWidth: number, face: Face = "regular", font?: string | null): string[] {
  const width = (t: string): number => measure(t, fontSize, face, font);
  const out: string[] = [];
  for (const para of s.split(/\r\n|\n|\r|\u2028|\u2029/)) {
    let line = "";
    for (const piece of pieces(para)) {
      const candidate = line + piece;
      if (line === "" || width(candidate.trimEnd()) <= maxWidth) { line = candidate; }
      else { out.push(line); line = piece; }
      // A piece wider than the line breaks between characters.
      while (width(line.trimEnd()) > maxWidth && [...line.trimEnd()].length > 1) {
        const chars = [...line];
        let n = chars.length - 1;
        while (n > 1 && width(chars.slice(0, n).join("")) > maxWidth) n--;
        out.push(chars.slice(0, n).join(""));
        line = chars.slice(n).join("");
      }
    }
    out.push(line);
  }
  return out;
}

/** The size CoreText suggests for `s` wrapped at `maxWidth`, rounded up (Renderer.textSize). */
export function textSize(s: string, fontSize: number, maxWidth: number, font?: string | null): { width: number; height: number } {
  if (s === "") return { width: 0, height: 0 };
  const lines = wrap(s, fontSize, maxWidth, "regular", font);
  const width = Math.max(...lines.map((l) => measure(l.trimEnd(), fontSize, "regular", font)));
  const [first, next] = lineHeights(fontSize, font);
  return { width: Math.ceil(width - 1e-9), height: Math.ceil(first + next * (lines.length - 1) - 1e-9) };
}
