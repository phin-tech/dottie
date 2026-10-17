// Clickable elements in a played drawing (Clicks.swift): what a click does, and how an element looks hovered.

import { type DottieFile, type Element, type Marker, type Page, allowedURL } from "./model.ts";
import { expandingSymbols } from "./symbols.ts";

/** Jump to scene `scene` (an index into the page's markers) and play on to the next; open `url` in a new tab; or,
 * in <dottie-player> only, show page `page` (an index into the file's pages), where the element's link points. */
export type Click = { scene: number } | { url: string } | { page: number };

/** The marker called `name`: an exact match, else one that differs only in case. */
export function sceneNamed(name: string, markers: Marker[]): number {
  const exact = markers.findIndex((m) => m.name === name);
  return exact >= 0 ? exact : markers.findIndex((m) => m.name.toLowerCase() === name.toLowerCase());
}

/** The page's clickable elements and what each click does, by element id. A scene named by no marker, or a link
 * that isn't allowed, makes nothing clickable. Given the whole file, an element whose `link` points at an element on
 * another page shows that page (the HTML export holds one page, so it can't). */
export function clickTargets(page: Page, file?: DottieFile): Map<string, Click> {
  const markers = page.timeline?.markers ?? [];
  const out = new Map<string, Click>();
  let pageOf: Map<string, number> | null = null;
  for (const e of page.elements) {
    const c = e.click;
    if (c?.scene) {
      const i = sceneNamed(c.scene, markers);
      if (i >= 0) { out.set(e.id, { scene: i }); continue; }
    }
    const url = c?.url ? allowedURL(c.url) : null;
    if (url) { out.set(e.id, { url }); continue; }
    if (e.link && file && file.pages.length > 1) {
      if (!pageOf) {
        pageOf = new Map();
        file.pages.forEach((p, i) => { for (const x of p.elements) if (!pageOf!.has(x.id)) pageOf!.set(x.id, i); });
      }
      const target = pageOf.get(e.link);
      if (target !== undefined && file.pages[target] !== page) out.set(e.id, { page: target });
    }
  }
  return out;
}

/** `e` as it looks hovered (HoverLook.apply). */
export function hoveredElement(e: Element): Element {
  const h = e.hover;
  if (!h) return e;
  const style = { ...e.style };
  if (h.stroke) style.stroke = h.stroke;
  if (h.fill) style.fill = h.fill;
  if (h.opacity !== null && Number.isFinite(h.opacity)) {
    const o = Math.min(Math.max(h.opacity, 0), 1);
    style.opacity = o >= 1 ? null : o;
  }
  return { ...e, style };
}

/** `page` with `ids` drawn as they look hovered. */
export function hovered(page: Page, ids: Set<string>): Page {
  return { ...page, elements: page.elements.map((e) => (ids.has(e.id) ? hoveredElement(e) : e)) };
}

export function hasHover(e: Element): boolean {
  return !!e.hover && (e.hover.stroke !== null || e.hover.fill !== null || e.hover.opacity !== null);
}

/** What a screen reader calls the element as a button: the first line of its text, else its anchor, else for a
 * symbol's copy the symbol's name, else its kind. */
export function buttonLabel(e: Element, symbolName?: string): string {
  const line = (e.text ?? "").split("\n").find((l) => l.length > 0);
  if (line) return line;
  if (e.anchor) return e.anchor;
  if (symbolName) return symbolName;
  return e.kind;
}

/** For each of `instances`, the ids of every element it can expand to, mapped to it, in drawing order
 * (DottieDocument.parts(of:)). */
export function partsOf(page: Page, instances: Set<string>): Map<string, string> {
  const out = new Map<string, string>();
  for (const e of page.elements) {
    if (!instances.has(e.id) || e.kind !== "symbol") continue;
    const alone: Page = { ...page, layers: [{ id: e.layerID, name: "", visible: true, locked: false }], elements: [e] };
    for (const part of expandingSymbols(alone, 0, false).elements) out.set(part.id, e.id);
  }
  return out;
}

/** How clickable elements look (Exporter.clickStyle): a pointer, their hover look under it or with keyboard focus (a
 * soft glow when they have none), and a small nudge while pressed. */
export const CLICK_STYLE = `
.dottie-a { cursor: pointer; outline: none; }
.dottie-a .dottie-h { display: none; }
.dottie-a:hover .dottie-h, .dottie-a.dottie-hover .dottie-h, .dottie-a:focus-visible .dottie-h { display: inline; }
.dottie-a:hover .dottie-n, .dottie-a.dottie-hover .dottie-n, .dottie-a:focus-visible .dottie-n { display: none; }
.dottie-a:focus-visible { filter: drop-shadow(0 0 3px var(--dottie-focus, #3b82f6)); }
.dottie-a:not(.dottie-b):active, .dottie-a.dottie-press:not(.dottie-b) { transform: translate(1px, 1px); }
.dottie-a .dottie-d { display: none; }
.dottie-b:active .dottie-n, .dottie-b:active .dottie-h, .dottie-b.dottie-press .dottie-n, .dottie-b.dottie-press .dottie-h { display: none; }
.dottie-b:active .dottie-d, .dottie-b.dottie-press .dottie-d { display: inline; }
`;
