// compile(): the self-showing script a drawing becomes.

import assert from "node:assert/strict";
import { test } from "node:test";
import { compile } from "../src/compile.ts";
import { read } from "./helpers.ts";

test("text that spells out a placeholder stays text, and every placeholder is filled", () => {
  const file = JSON.parse(read("design", "example.dottie"));
  const words = "see DOTTIE_OPTIONS and DOTTIE_FONTS and DOTTIE_DATA";
  file.pages[0].elements.find((e: { text?: string }) => typeof e.text === "string").text = words;
  const out = compile(file, "/* runtime */", { label: "Example" });
  const loader = out.slice(out.indexOf("\n") + 1);
  // The placeholders appear only inside the drawing's own text, once each.
  assert.equal(loader.split("DOTTIE_OPTIONS").length, 2);
  assert.equal(loader.split("DOTTIE_FONTS").length, 2);
  assert.equal(loader.split("DOTTIE_DATA").length, 2);
  assert.ok(loader.includes(JSON.stringify(words)));
  assert.match(loader, /options = \{"label":"Example"\}, fonts = \{\};/);
});
