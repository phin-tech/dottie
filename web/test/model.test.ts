// Reading files: the schema and dottie.js agree on the format, and odd files load with warnings, not errors.

import assert from "node:assert/strict";
import { test } from "node:test";
import { DottieFormatError, KINDS, KNOWN_FIELDS, parseDottie } from "../src/model.ts";
import { render } from "../src/index.ts";
import { clickTargets } from "../src/clicks.ts";
import { read } from "./helpers.ts";

const schema = JSON.parse(read("..", "schema", "dottie.schema.json"));

test("dottie.js reads exactly the fields the schema lists", () => {
  for (const [def, fields] of Object.entries(KNOWN_FIELDS)) {
    assert.deepEqual([...fields].sort(), Object.keys(schema.$defs[def].properties).sort(), `${def} in schema/dottie.schema.json`);
  }
  const withProps = Object.entries(schema.$defs).filter(([, d]) => (d as { properties?: object }).properties).map(([k]) => k);
  assert.deepEqual(withProps.sort(), Object.keys(KNOWN_FIELDS).sort(), "every object in the schema");
});

test("dottie.js knows every element kind and enum in the schema", () => {
  const d = schema.$defs;
  assert.deepEqual([...KINDS].sort(), [...d.element.properties.kind.enum].sort());
  const out = parseDottie(read("edge", "shapes.dottie"));
  assert.ok(out.pages[0].elements.length > 10);
  for (const e of [d.style.properties.fillStyle.enum, d.style.properties.dash.enum, d.ease.enum, d.arrowhead.enum,
    d.connector.properties.routing.enum, d.endpoint.properties.port.enum]) assert.ok(e.length > 1);
});

test("files Dottie wrote load without warnings", () => {
  for (const name of ["design/tour", "design/stagger", "edge/connectors", "edge/timeline", "edge/notes"]) {
    const [g, n] = name.split("/");
    assert.deepEqual(parseDottie(read(g, `${n}.dottie`)).warnings, [], name);
  }
});

test("newer files load, with what was skipped in warnings", () => {
  const f = parseDottie(read("js-only", "future.dottie"));
  assert.equal(f.pages[0].elements.length, 3);
  assert.ok(f.warnings.some((w) => /version 99/.test(w)));
  assert.ok(f.warnings.some((w) => /hexagon/.test(w)));
  assert.ok(f.warnings.some((w) => /zigzag/.test(w)));
  assert.ok(f.warnings.some((w) => /wavy/.test(w)));
  const shapes = parseDottie(read("edge", "shapes.dottie"));
  assert.ok(shapes.warnings.some((w) => /futureField/.test(w)));
  assert.ok(shapes.warnings.some((w) => /futureTopLevel/.test(w)));
  assert.match(render(f), /hexagon: unknown kind/);
});

test("what isn't a drawing is refused clearly", () => {
  assert.throws(() => parseDottie("not json"), DottieFormatError);
  assert.throws(() => parseDottie("{}"), /no version/);
  assert.throws(() => parseDottie('{"version":2,"pages":[]}'), /at least one page/);
});

test("render draws a page as SVG at a moment, clean or sketchy", () => {
  const src = read("design", "tour.dottie");
  const a = render(src, { at: 0 }), b = render(src), c = render(src, { clean: true });
  assert.match(a, /^<svg /);
  assert.notEqual(a, b);
  assert.notEqual(b, c);
  assert.equal(render(src, { background: null }).includes('fill="#ffffff"/>'), false);
  assert.match(render(read("edge", "themes.dottie"), { page: "midnight" }), /fill="#15161a"/);
});

test("picture data that isn't base64 is dropped, with a warning", () => {
  const f = parseDottie(read("js-only", "hostile.dottie"));
  const pics = f.pages[0].elements.filter((e) => e.kind === "image");
  assert.deepEqual(pics.map((e) => e.image?.data), ["", ""]);
  assert.ok(f.warnings.some((w) => /base64/.test(w)));
  assert.doesNotMatch(render(f), /<script|<img|<b[ >]|<[^>]*\son\w+=/);
});

test("clicks: scenes by name in any case, safe links only, links to other pages", () => {
  const f = parseDottie(read("edge", "clicks.dottie"));
  const p = f.pages[0];
  const id = (text: string): string => p.elements.find((e) => e.text === text)!.id;
  assert.equal(p.elements.find((e) => e.text === "Script")!.click?.url, null);
  assert.ok(f.warnings.some((w) => /click link/.test(w)));
  const targets = clickTargets(p, f);
  assert.deepEqual(targets.get(id("Auth")), { scene: 1 });
  assert.deepEqual(targets.get(id("Docs")), { url: "https://example.com/docs" });
  assert.deepEqual(targets.get(id("Back")), { scene: 0 });
  assert.deepEqual(targets.get(id("Details")), { page: 1 });
  assert.equal(targets.has(id("Nowhere")), false, "no such scene");
  assert.equal(targets.has(id("Script")), false, "javascript: is never followed");
  assert.equal(clickTargets(p).has(id("Details")), false, "a page link needs the file");
  const hostile = parseDottie(read("js-only", "hostile-clicks.dottie"));
  assert.deepEqual(hostile.pages[0].elements.map((e) => e.click?.url), [null, null, null]);
  assert.equal(clickTargets(hostile.pages[0], hostile).size, 0);
});
