"use strict";
// A starting point for a Dottie extension. Build it with ./build.sh, which writes main.js beside manifest.json.
/// <reference path="../dottie-extension.d.ts" />
// A square whose corners are pulled in by `inset` (a fraction of its size). Its lower-right corner is a handle.
extension.shape({
    id: "box",
    name: "Inset box",
    parameters: {
        inset: { type: "number", label: "Inset", min: 0, max: 0.5, default: 0.1 },
        round: { type: "boolean", label: "Round", default: false },
    },
    generate(p) {
        const i = p.inset;
        // A straight edge is a cubic whose control points sit a third and two thirds along it.
        const corners = [[i, i], [1 - i, i], [1 - i, 1 - i], [i, 1 - i]];
        const coords = [corners[0][0], corners[0][1]];
        corners.forEach((a, k) => {
            const b = corners[(k + 1) % corners.length];
            coords.push(a[0] + (b[0] - a[0]) / 3, a[1] + (b[1] - a[1]) / 3, a[0] + (2 * (b[0] - a[0])) / 3, a[1] + (2 * (b[1] - a[1])) / 3, b[0], b[1]);
        });
        return {
            subpaths: [{ closed: true, coords }],
            ports: [{ x: 0.5, y: 0 }, { x: 0.5, y: 1 }],
            labelRect: { x: i, y: i, width: 1 - 2 * i, height: 1 - 2 * i },
        };
    },
    handles: [
        {
            id: "corner",
            position: (p, f) => ({ x: p.inset * f.width, y: p.inset * f.height }),
            drag: (p, f, pt) => ({ ...p, inset: Math.min(0.5, Math.max(0, pt.x / f.width)) }),
        },
    ],
});
// A command that draws a row of boxes on the selected page. It runs with the `dottie` object.
extension.command({
    id: "row",
    name: "Row of boxes",
    category: "Layout",
    parameters: {
        count: { type: "integer", label: "Boxes", min: 1, max: 20, default: 3 },
        gap: { type: "number", label: "Gap", min: 0, max: 200, default: 20 },
    },
    run(p) {
        for (let k = 0; k < p.count; k++) {
            dottie.shape({ extension: { id: "com.example.template", shape: "box" }, params: { inset: 0.1 }, x: k * (100 + p.gap), y: 0, width: 100, height: 100 });
        }
        return p.count;
    },
});
