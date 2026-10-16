// dottie.js goes out at Dottie's version (scripts/bump.sh sets both): package.json, VERSION and DottieVersion agree.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { VERSION } from "../src/index.ts";
import { ROOT } from "./helpers.ts";

test("dottie.js's version is Dottie's", () => {
  const app = /static let current = "([^"]+)"/.exec(readFileSync(join(ROOT, "Sources", "DottieKit", "Version.swift"), "utf8"))?.[1];
  const pkg = JSON.parse(readFileSync(join(ROOT, "web", "package.json"), "utf8")).version;
  assert.equal(pkg, app, "web/package.json against Sources/DottieKit/Version.swift; run just bump, not a hand edit");
  assert.equal(VERSION, app, "VERSION in web/src/index.ts");
});
