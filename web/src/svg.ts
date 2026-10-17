// A page as SVG (SVG.swift and Export.swift): the same paths Dottie's own SVG export writes, so the sketchy look
// is identical, plus the page bounds and an animation's export plan.

import { type Index, connectorBounds, indexOf, midpoint } from "./connector.ts";
import { BAND, isFloor, lineColor, rock } from "./dungeon.ts";
import { angle, frame, resolvingInk, rotatedBounds } from "./element.ts";
import { type Element, type Page, type RGBA, black, orderedElements } from "./model.ts";
import { noteMarkup } from "./note.ts";
import { color, escapeXML } from "./svg-util.ts";
import { Path, type Rect, fmt, inset, midX, midY, union } from "./path.ts";
import { cellSize, connectorParts, dashPattern, fillPath, hachurePath, outline } from "./shapes.ts";
import { expandingSymbols, hasInstances } from "./symbols.ts";
import { textSize } from "./text.ts";
import { themeNamed } from "./theme.ts";
import { cameraView, frameTimes, resolved } from "./timeline.ts";

/** The drawing's extent plus `padding`; a floor's rock hatching reaches past its shape. */
export function bounds(page: Page, padding = 24): Rect {
  if (hasInstances(page)) return bounds(expandingSymbols(page, 0), padding);
  const index = indexOf(page);
  const box = (e: Element): Rect => {
    if (e.kind === "connector") return connectorBounds(e, index);
    const reach = isFloor(e) ? (BAND + 0.25) * cellSize(e) : 0;
    return inset(rotatedBounds(e), -reach, -reach);
  };
  if (page.elements.length === 0) return { x: 0, y: 0, width: 200, height: 200 };
  // Fully transparent elements (an entrance about to fade up) take no room, unless nothing else is there.
  const shown = page.elements.filter((e) => (e.style.opacity ?? 1) > 0);
  let r: Rect | null = null;
  for (const e of shown.length ? shown : page.elements) r = union(r, box(e));
  return inset(r!, -padding, -padding);
}

export interface Plan {
  times: number[];
  /** The part of the page each frame shows. */
  rects: Rect[];
  /** Output size in points. */
  size: { width: number; height: number };
}

/** What an animation shows over time (Exporter.animation): with a camera, its view at each frame, widened to
 * the first key's shape; without, the bounds of the whole animation for every frame. */
export function plan(page: Page): Plan {
  const tl = page.timeline ?? { fps: 12, duration: 0, boil: null, settle: null, poster: null, tracks: [], camera: null, markers: null };
  const times = frameTimes(tl);
  const first = tl.camera?.find((k) => k.width > 1 && k.height > 1);
  if (first) {
    const aspect = first.width / first.height;
    const rects = times.map((t) => cameraView(tl, t) ?? { x: first.x, y: first.y, width: first.width, height: first.height });
    const width = Math.min(Math.max(...rects.map((r) => r.width)), 4096);
    return { times, rects, size: { width, height: width / aspect } };
  }
  let b: Rect | null = null;
  for (const t of times) {
    const f = resolved(page, t);
    if (f.elements.length > 0) b = union(b, bounds(f));
  }
  if (!b) b = bounds(resolved(page, times[0]));
  return { times, rects: times.map(() => b!), size: { width: b.width, height: b.height } };
}


const opacity = (c: RGBA, attr: string): string => (c.a < 1 ? ` ${attr}="${fmt(c.a)}"` : "");

/** The opening `<svg>` tag for `b`, with the page color behind everything when `paint`. */
export function svgOpen(b: Rect, background: RGBA | null, paint: boolean): string {
  let out = `<svg xmlns="http://www.w3.org/2000/svg" width="${fmt(b.width)}" height="${fmt(b.height)}" viewBox="${fmt(b.x)} ${fmt(b.y)} ${fmt(b.width)} ${fmt(b.height)}">\n`;
  if (paint && background) {
    out += `<rect x="${fmt(b.x)}" y="${fmt(b.y)}" width="${fmt(b.width)}" height="${fmt(b.height)}" fill="${color(background)}"/>\n`;
  }
  return out;
}

export interface Part { key: string; markup: string }

/** The SVG for each thing drawn, back to front, keyed by element id (rock hatching as "rock"). */
export function svgParts(page: Page, background: RGBA | null, fixed?: Rect): { bounds: Rect; parts: Part[] } {
  if (hasInstances(page)) return svgParts(expandingSymbols(page, 0), background, fixed);
  const theme = themeNamed(page.theme);
  const bg = background ? (theme?.background ?? background) : null;
  const ink = theme?.ink ?? black;
  const d: Page = { ...page, elements: page.elements.map((e) => resolvingInk(e, ink)) };
  const b = fixed ?? bounds(d);
  const visible = new Set(d.layers.filter((l) => l.visible).map((l) => l.id));
  const parts: Part[] = [];
  const index = indexOf(d);
  const ordered = orderedElements(d);
  const floors = ordered.filter((e) => visible.has(e.layerID) && isFloor(e));
  const rockMarkup = rock(floors).map((r) =>
    `<path d="${r.path.data()}" fill="none" stroke="${color(r.ink)}"${opacity(r.ink, "stroke-opacity")} stroke-width="${fmt(r.width)}" stroke-linecap="round"/>\n`).join("");
  if (rockMarkup) parts.push({ key: "rock", markup: rockMarkup });
  for (const e of ordered) {
    if (!visible.has(e.layerID)) continue;
    const alpha = Math.min(Math.max(e.style.opacity ?? 1, 0), 1);
    if (alpha <= 0) continue;
    let body = svgElement(e, index, bg);
    if (angle(e) !== 0 && e.kind !== "connector") {
      body = `<g transform="rotate(${fmt((angle(e) * 180) / Math.PI)} ${fmt(midX(frame(e)))} ${fmt(midY(frame(e)))})">\n${body}</g>\n`;
    }
    parts.push({ key: e.id, markup: alpha < 1 ? `<g opacity="${fmt(alpha)}">\n${body}</g>\n` : body });
  }
  return { bounds: b, parts };
}

/** A whole page as an SVG document. Pass `background: null` for a transparent page. */
export function svg(page: Page, background: RGBA | null = { r: 1, g: 1, b: 1, a: 1 }, fixed?: Rect): string {
  const { bounds: b, parts } = svgParts(page, background, fixed);
  return svgOpen(b, themeNamed(page.theme)?.background ?? background, background !== null) + parts.map((p) => p.markup).join("") + "</svg>\n";
}

/** Where a connector's label sits. */
export function labelRect(e: Element, index: Index): Rect {
  const m = midpoint(e, index);
  const text = e.text ?? "";
  const size = textSize(text === "" ? "Label" : text, e.style.fontSize, 200);
  const w = Math.max(size.width + 12, 44), h = size.height + 6;
  return { x: m.x - w / 2, y: m.y - h / 2, width: w, height: h };
}

/** The part of `s` typed out so far. */
function typed(s: string, progress: number): string {
  const chars = [...s];
  return chars.slice(0, Math.floor(chars.length * progress)).join("");
}

function revealProgress(e: Element): number | null {
  return e.reveal !== null && e.reveal < 1 ? Math.max(0, e.reveal) : null;
}

function svgElement(e: Element, index: Index, labelBackground: RGBA | null): string {
  const stroke = color(e.style.stroke);
  let strokeAttrs = `stroke="${stroke}" stroke-width="${fmt(e.style.strokeWidth)}" stroke-linecap="round" stroke-linejoin="round"`;
  const dash = dashPattern(e.style.dash, e.style.strokeWidth);
  if (dash) strokeAttrs += ` stroke-dasharray="${dash.map(fmt).join(" ")}"`;
  if (dash && e.style.dashOffset !== null && fmt(e.style.dashOffset) !== "0") strokeAttrs += ` stroke-dashoffset="${fmt(e.style.dashOffset)}"`;
  let text = e.text;
  const r = revealProgress(e);
  if (r !== null) {
    if (e.kind === "text") text = typed(text ?? "", r);
    else if (e.kind === "connector") {
      return `<path d="${connectorParts(e, index)[0].trimmed(r).data()}" fill="none" ${strokeAttrs}/>\n`;
    } else {
      return `<path d="${outline(e).trimmed(r).data()}" fill="none" ${strokeAttrs}/>\n`;
    }
  }
  switch (e.kind) {
    case "connector": {
      const [line, filled] = connectorParts(e, index);
      let s = `<path d="${line.data()}" fill="none" ${strokeAttrs}/>\n`;
      if (!filled.isEmpty) s += `<path d="${filled.data()}" fill="${stroke}" stroke="none"/>\n`;
      if (text) {
        const lr = labelRect(e, index);
        if (labelBackground) s += `<rect x="${fmt(lr.x)}" y="${fmt(lr.y)}" width="${fmt(lr.width)}" height="${fmt(lr.height)}" fill="${color(labelBackground)}"/>\n`;
        s += textElement(text, lr, e, true);
      }
      return s;
    }
    case "text":
      return textElement(text ?? "", frame(e), e, false);
    case "image": {
      const f = frame(e);
      let s = "";
      if (e.image) {
        const mime = e.image.format === "jpeg" ? "image/jpeg" : "image/png";
        s += `<image x="${fmt(f.x)}" y="${fmt(f.y)}" width="${fmt(f.width)}" height="${fmt(f.height)}" preserveAspectRatio="none" href="data:${mime};base64,${e.image.data}"/>\n`;
      }
      if (e.style.stroke.a > 0 && e.style.strokeWidth > 0) s += `<path d="${outline(e).data()}" fill="none" ${strokeAttrs}/>\n`;
      return s;
    }
    case "freehand":
      return `<path d="${outline(e).data()}" fill="none" ${strokeAttrs}/>\n`;
    case "rectangle": case "ellipse": case "diamond": case "path": case "note": {
      let s = "";
      if (e.kind === "note" && e.style.fill.a > 0) {
        s += `<path d="${fillPath(e).translated(2, 3).data()}" fill="#000000" fill-opacity="${fmt(0.14 * e.style.fill.a)}" stroke="none"/>\n`;
      }
      if (e.style.fill.a > 0) {
        const rule = e.evenOdd === true ? ` fill-rule="evenodd"` : "";
        if (e.style.fillStyle === "solid") {
          s += `<path d="${fillPath(e).data()}" fill="${color(e.style.fill)}"${opacity(e.style.fill, "fill-opacity")}${rule} stroke="none"/>\n`;
        } else if (e.style.fillStyle === "grid") {
          const line = lineColor(e.style.fill);
          s += `<path d="${fillPath(e).data()}" fill="${color(e.style.fill)}"${opacity(e.style.fill, "fill-opacity")}${rule} stroke="none"/>\n`;
          s += `<path d="${hachurePath(e).data()}" fill="none" stroke="${color(line)}"${opacity(line, "stroke-opacity")} stroke-width="1" stroke-linecap="round"/>\n`;
        } else {
          s += `<path d="${hachurePath(e).data()}" fill="none" stroke="${color(e.style.fill)}"${opacity(e.style.fill, "stroke-opacity")} stroke-width="${fmt(Math.max(1, e.style.strokeWidth / 2))}" stroke-linecap="round"/>\n`;
        }
      }
      s += `<path d="${outline(e).data()}" fill="none" ${strokeAttrs}/>\n`;
      if (text) s += e.kind === "note" ? noteMarkup(text, e) : textElement(text, frame(e), e, true);
      return s;
    }
    default:
      return placeholder(e, strokeAttrs);
  }
}

/** A kind this version doesn't know: its frame, crossed, with the kind written in it. */
function placeholder(e: Element, strokeAttrs: string): string {
  const f = frame(e);
  const p = Path.rect(f).moveTo({ x: f.x, y: f.y }).lineTo({ x: f.x + f.width, y: f.y + f.height });
  return `<path d="${p.data()}" fill="none" ${strokeAttrs} stroke-opacity="0.5" stroke-dasharray="6 4"/>\n`
    + textElement(`${e.kind}${e.text ? `: ${e.text}` : ""}`, f, { ...e, style: { ...e.style, fontSize: Math.min(e.style.fontSize, 12) } }, true);
}

export function textElement(text: string, f: Rect, e: Element, centered: boolean): string {
  const size = e.style.fontSize;
  const lines = text.split("\n");
  const lineHeight = size * 1.2;
  const total = lineHeight * lines.length;
  const x = centered ? midX(f) : f.x;
  const top = centered ? midY(f) - total / 2 : f.y;
  let s = `<text x="${fmt(x)}" font-family="Helvetica Neue, Helvetica, Arial, sans-serif" font-size="${fmt(size)}" fill="${color(e.style.stroke)}"${centered ? ` text-anchor="middle"` : ""}>`;
  lines.forEach((line, i) => { s += `<tspan x="${fmt(x)}" y="${fmt(top + lineHeight * (i + 0.8))}">${escapeXML(line)}</tspan>`; });
  return s + "</text>\n";
}
export { color, escapeXML };
