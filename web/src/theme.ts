// Page looks (Theme.swift): the canvas color, the color automatic ink takes on it, and a palette of named colors
// (ADR 0005). A page names a built-in, or has a theme of its own.

import type { Element, Page, PaletteColor, RGBA } from "./model.ts";

export interface Theme { id: string; name: string; background: RGBA; ink: RGBA; palette: PaletteColor[] }

const rgb = (r: number, g: number, b: number): RGBA => ({ r, g, b, a: 1 });

/** RGBA(hex:) for #rrggbb, as Swift reads it. */
function hex(h: string): RGBA {
  const n = parseInt(h.slice(1), 16);
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255, a: 1 };
}

/** The palette names every built-in theme has, in order. */
export const PALETTE_NAMES = ["accent", "muted", "danger", "warning", "success", "info"];
const palette = (colors: string[]): PaletteColor[] => PALETTE_NAMES.map((name, i) => ({ name, color: hex(colors[i]) }));
/** Light pages. */
export const LIGHT_PALETTE = palette(["#2563eb", "#6b7280", "#dc2626", "#d97706", "#16a34a", "#0891b2"]);
const DARK_PALETTE = palette(["#93c5fd", "#cbd5e1", "#fca5a5", "#fcd34d", "#86efac", "#67e8f9"]);

export const themes: Theme[] = [
  { id: "paper", name: "Paper", background: rgb(0.984, 0.980, 0.965), ink: rgb(0.12, 0.12, 0.13), palette: LIGHT_PALETTE },
  { id: "white", name: "White", background: rgb(1, 1, 1), ink: rgb(0.12, 0.12, 0.13), palette: LIGHT_PALETTE },
  { id: "sepia", name: "Sepia", background: rgb(0.953, 0.914, 0.824), ink: rgb(0.23, 0.18, 0.13),
    palette: palette(["#9a3412", "#78716c", "#b91c1c", "#b45309", "#4d7c0f", "#0e7490"]) },
  { id: "blueprint", name: "Blueprint", background: rgb(0.106, 0.227, 0.361), ink: rgb(0.91, 0.945, 0.984), palette: DARK_PALETTE },
  { id: "chalkboard", name: "Chalkboard", background: rgb(0.169, 0.227, 0.2), ink: rgb(0.945, 0.945, 0.918), palette: DARK_PALETTE },
  { id: "midnight", name: "Midnight", background: rgb(0.082, 0.086, 0.102), ink: rgb(0.925, 0.925, 0.94), palette: DARK_PALETTE },
];

/** The theme a page names, or null (white page, black ink) for none or one this version doesn't know. */
export function themeNamed(id: string | null | undefined): Theme | null {
  return themes.find((t) => t.id === id) ?? null;
}

/** The theme `page` is drawn in: its own, else the built-in it names, else null. */
export function pageTheme(page: Pick<Page, "theme" | "customTheme">): Theme | null {
  const c = page.customTheme;
  if (c) return { id: "custom", name: c.name, background: c.background, ink: c.ink, palette: c.palette };
  return themeNamed(page.theme);
}

/** The palette color `name` names on `page`, ignoring case. */
export function paletteColor(page: Pick<Page, "theme" | "customTheme">, name: string): RGBA | null {
  const n = name.trim().toLowerCase();
  return (pageTheme(page)?.palette ?? LIGHT_PALETTE).find((p) => p.name.toLowerCase() === n)?.color ?? null;
}

/** `page` with every named color set from its palette (DottieDocument.resolvingPalette); a name the palette doesn't
 * have keeps the color it had. */
export function resolvingPalette(page: Page): Page {
  const named = (e: Element) => !!e.style.named;
  if (!page.elements.some(named) && !(page.symbols ?? []).some((s) => s.elements.some(named))) return page;
  const resolve = (e: Element): Element => {
    const n = e.style.named;
    if (!n) return e;
    const style = { ...e.style };
    const f = n.fill !== null ? paletteColor(page, n.fill) : null;
    const s = n.stroke !== null ? paletteColor(page, n.stroke) : null;
    const t = n.textColor !== null ? paletteColor(page, n.textColor) : null;
    if (f) style.fill = { ...f };
    if (s) style.stroke = { ...s };
    if (t) style.textColor = { ...t };
    return { ...e, style };
  };
  return {
    ...page,
    elements: page.elements.map(resolve),
    symbols: page.symbols ? page.symbols.map((s) => ({ ...s, elements: s.elements.map(resolve) })) : page.symbols,
  };
}
