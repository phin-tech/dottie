// Page looks (Theme.swift): the canvas color and the color automatic ink takes on it.

import type { RGBA } from "./model.ts";

export interface Theme { id: string; name: string; background: RGBA; ink: RGBA }

const rgb = (r: number, g: number, b: number): RGBA => ({ r, g, b, a: 1 });

export const themes: Theme[] = [
  { id: "paper", name: "Paper", background: rgb(0.984, 0.980, 0.965), ink: rgb(0.12, 0.12, 0.13) },
  { id: "white", name: "White", background: rgb(1, 1, 1), ink: rgb(0.12, 0.12, 0.13) },
  { id: "sepia", name: "Sepia", background: rgb(0.953, 0.914, 0.824), ink: rgb(0.23, 0.18, 0.13) },
  { id: "blueprint", name: "Blueprint", background: rgb(0.106, 0.227, 0.361), ink: rgb(0.91, 0.945, 0.984) },
  { id: "chalkboard", name: "Chalkboard", background: rgb(0.169, 0.227, 0.2), ink: rgb(0.945, 0.945, 0.918) },
  { id: "midnight", name: "Midnight", background: rgb(0.082, 0.086, 0.102), ink: rgb(0.925, 0.925, 0.94) },
];

/** The theme a page names, or null (white page, black ink) for none or one this version doesn't know. */
export function themeNamed(id: string | null | undefined): Theme | null {
  return themes.find((t) => t.id === id) ?? null;
}
