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

test("one page goes in by default; every page with allPages, which gives the player history and the page to start on", () => {
  const file = JSON.parse(read("edge", "clicks.dottie"));
  const data = (out: string) => JSON.parse(out.slice(out.indexOf("var data = ") + 11, out.indexOf(", options = ")));
  const options = (out: string) => JSON.parse(out.slice(out.indexOf("options = ") + 10, out.indexOf(", fonts = ")));
  const one = compile(file, "/* runtime */");
  assert.deepEqual(data(one).pages.map((p: { name: string }) => p.name), ["Overview"]);
  assert.deepEqual(options(one), {});
  const all = compile(file, "/* runtime */", { allPages: true, page: "Details" });
  assert.deepEqual(data(all).pages.map((p: { name: string }) => p.name), ["Overview", "Details"]);
  assert.deepEqual(options(all), { history: "", page: "Details" });
});
