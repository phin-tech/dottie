// dottie.js: render and play Dottie (.dottie) drawings in the browser, without pre-rendered frames.

import { type DottieFile, type Page, type RGBA, parseDottie } from "./model.ts";
import { pageIndex, withRoughness } from "./player.ts";
import { svg } from "./svg.ts";
import { posterTime, resolved } from "./timeline.ts";

export * from "./model.ts";
export { inspect, inspectFrame, inspectPage, sampleTimes } from "./inspect.ts";
export { DottiePlayer, Playback, definePlayer, pageIndex, withRoughness } from "./player.ts";
export { bounds, plan, svg, svgParts, type Plan, type Part } from "./svg.ts";
export { themeNamed, themes, type Theme } from "./theme.ts";
export { cameraView, frameTimes, posterTime, resolved, sceneAt, still, transientElements } from "./timeline.ts";

export interface RenderOptions {
  /** Page name or 1-based number; the first page by default. */
  page?: string | number;
  /** Seconds into the animation; its poster frame (the end, unless set) by default. */
  at?: number;
  /** Draw precisely instead of sketchy. */
  clean?: boolean;
  /** Page color behind the drawing; null for transparent. White (or the page's theme) by default. */
  background?: RGBA | null;
}

/** One page of a drawing as an SVG document, as Dottie's own SVG export draws it. */
export function render(source: string | DottieFile | unknown, options: RenderOptions = {}): string {
  const file = isFile(source) ? source : parseDottie(source);
  let page: Page = file.pages[pageIndex(file, options.page === undefined ? null : String(options.page))];
  page = resolved(page, options.at ?? posterTime(page));
  if (options.clean) page = withRoughness(page, 0);
  return svg(page, options.background === undefined ? { r: 1, g: 1, b: 1, a: 1 } : options.background);
}

function isFile(v: unknown): v is DottieFile {
  return typeof v === "object" && v !== null && Array.isArray((v as DottieFile).pages) && Array.isArray((v as DottieFile).warnings);
}

/** The library's version. */
export const VERSION = "0.3.0";
