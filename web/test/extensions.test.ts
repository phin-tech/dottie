// Extension shapes as dottie.js draws them: connectors at the real outline, through ports, and labels in labelRect.

import assert from "node:assert/strict";
import { test } from "node:test";
import { edgePoint, endpoints, indexOf } from "../src/connector.ts";
import { type Element, parseDottie } from "../src/model.ts";
import { svg } from "../src/svg.ts";

const LAYER = "00000000-0000-0000-0000-0000000000a0";
const id = (n: number): string => `00000000-0000-0000-0000-0000000000${n.toString(16).padStart(2, "0")}`;

/** A one-page drawing holding `elements`, read the way a file is. */
function drawing(elements: object[]) {
  return parseDottie(JSON.stringify({
    version: 2,
    pages: [{ id: id(1), name: "Page", layers: [{ id: LAYER, name: "Layer", visible: true, locked: false }], elements }],
  }));
}

/** A closed triangle at the frame's top middle, bottom left and bottom right, its edges as cubics. */
const TRIANGLE = [1 / 2, 0, 2 / 3, 1 / 3, 5 / 6, 2 / 3, 1, 1, 2 / 3, 1, 1 / 3, 1, 0, 1, 1 / 6, 2 / 3, 1 / 3, 1 / 3, 1 / 2, 0];

test("edgePoint on a path meets its outline, not its bounding box", () => {
  const f = drawing([{ id: id(2), kind: "path", layerID: LAYER, x: 0, y: 0, width: 100, height: 100, subpaths: [{ closed: true, coords: TRIANGLE }] }]);
  const shape = f.pages[0].elements[0];
  // The ray from (50, 50) toward (10, 0) crosses the triangle's left edge (x = 50 - y / 2) at t = 5/13.
  const p = edgePoint(shape, { x: 10, y: 0 });
  assert.ok(Math.abs(p.x - 450 / 13) < 1e-9 && Math.abs(p.y - 400 / 13) < 1e-9, JSON.stringify(p));
  // The bounding box would have put it at the corner (10, 0).
  assert.notDeepEqual(p, { x: 10, y: 0 });
});

test("edgePoint on a rotated path turns the outline with the shape", () => {
  const f = drawing([{ id: id(2), kind: "path", layerID: LAYER, x: 0, y: 0, width: 100, height: 100, rotation: Math.PI / 2, subpaths: [{ closed: true, coords: TRIANGLE }] }]);
  const shape = f.pages[0].elements[0];
  // A quarter turn about (50, 50) maps (x, y) to (100 - y, x). The unrotated hit (450/13, 400/13) turns into (900/13, 450/13).
  const p = edgePoint(shape, { x: 100, y: 10 });
  assert.ok(Math.abs(p.x - 900 / 13) < 1e-9 && Math.abs(p.y - 450 / 13) < 1e-9, JSON.stringify(p));
});

test("a connector to a port attaches to element.ports[portIndex], rotated with the element", () => {
  const f = drawing([
    { id: id(3), kind: "path", layerID: LAYER, x: 10, y: 20, width: 100, height: 40, ports: [{ x: 0, y: 0.5 }, { x: 1, y: 0.5 }], subpaths: [{ closed: true, coords: TRIANGLE }] },
    { id: id(4), kind: "connector", layerID: LAYER, x: 0, y: 0, width: 0, height: 0, connector: {
      start: { elementID: id(3), port: null, portIndex: 1, x: 0, y: 0 }, end: { elementID: null, port: null, portIndex: null, x: 300, y: 300 },
      routing: "straight", startHead: "none", endHead: "none" } },
  ]);
  const [start] = endpoints(f.pages[0].elements[1], indexOf(f.pages[0]));
  assert.deepEqual(start, { x: 110, y: 40 });
});

test("portIndex wins over port, and an invalid index falls back to port", () => {
  const ports = [{ x: 0, y: 0.5 }, { x: 1, y: 0.5 }];
  const at = (portIndex: number, port: "top" | "bottom"): { x: number; y: number } => {
    const f = drawing([
      { id: id(3), kind: "rectangle", layerID: LAYER, x: 10, y: 20, width: 100, height: 40, ports },
      { id: id(4), kind: "connector", layerID: LAYER, x: 0, y: 0, width: 0, height: 0, connector: {
        start: { elementID: id(3), port, portIndex, x: 0, y: 0 }, end: { elementID: null, port: null, portIndex: null, x: 300, y: 300 },
        routing: "straight", startHead: "none", endHead: "none" } },
    ]);
    return endpoints(f.pages[0].elements[1], indexOf(f.pages[0]))[0];
  };
  assert.deepEqual(at(0, "bottom"), { x: 10, y: 40 });
  assert.deepEqual(at(7, "top"), { x: 60, y: 20 });
  assert.deepEqual(at(-1, "bottom"), { x: 60, y: 60 });
});

test("a path label is centered in its labelRect", () => {
  const withRect = drawing([{ id: id(5), kind: "path", layerID: LAYER, x: 10, y: 20, width: 100, height: 50, text: "Hi",
    labelRect: { x: 0.5, y: 0, width: 0.5, height: 1 }, subpaths: [{ closed: true, coords: TRIANGLE }] }]);
  const without = drawing([{ id: id(5), kind: "path", layerID: LAYER, x: 10, y: 20, width: 100, height: 50, text: "Hi",
    subpaths: [{ closed: true, coords: TRIANGLE }] }]);
  // The rect is x 60..110, y 20..70: its center is (85, 45). Without it the label sits at the frame's center (60, 45).
  assert.match(svg(withRect.pages[0]), /<text x="85" [^>]*text-anchor="middle">/);
  assert.match(svg(without.pages[0]), /<text x="60" [^>]*text-anchor="middle">/);
});

test("extension metadata reads without warnings, and is kept on the element", () => {
  const f = drawing([{ id: id(6), kind: "path", layerID: LAYER, x: 0, y: 0, width: 10, height: 10, subpaths: [{ closed: true, coords: TRIANGLE }],
    extension: { id: "dev.example.gear", shape: "gear", version: "1.2.0", params: { teeth: 8, round: true, name: "x" } } }]);
  assert.deepEqual(f.warnings, []);
  const e: Element = f.pages[0].elements[0];
  assert.deepEqual(e.extension, { id: "dev.example.gear", shape: "gear", version: "1.2.0", params: { teeth: 8, round: true, name: "x" } });
});

/** A closed square with open lines across its inside at 20% and 60% of its height, like a database's rims. */
const SQUARE = [0, 0, 1 / 3, 0, 2 / 3, 0, 1, 0, 1, 1 / 3, 1, 2 / 3, 1, 1, 2 / 3, 1, 1 / 3, 1, 0, 1, 0, 2 / 3, 0, 1 / 3, 0, 0];
const RIMS = [0.2, 0.6].map((y) => ({ closed: false, coords: [0, y, 1 / 3, y, 2 / 3, y, 1, y] }));

test("lines inside a path's outline don't catch connectors; a far end inside uses the nearest crossing", () => {
  const f = drawing([{ id: id(2), kind: "path", layerID: LAYER, x: 0, y: 0, width: 100, height: 100, subpaths: [{ closed: true, coords: SQUARE }, ...RIMS] }]);
  const shape = f.pages[0].elements[0];
  // From above, the ray from (50, 50) meets the inside line at y 20 before the top edge: the edge wins.
  assert.deepEqual(edgePoint(shape, { x: 50, y: -100 }), { x: 50, y: 0 });
  assert.deepEqual(edgePoint(shape, { x: 50, y: 300 }), { x: 50, y: 100 });
  // A far end at y 30 is inside: nothing is crossed before it, so the nearest crossing ahead (the line at y 20).
  assert.deepEqual(edgePoint(shape, { x: 50, y: 30 }), { x: 50, y: 20 });
});
