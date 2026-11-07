// The MCP server's queue-workers example (ScriptExamples.swift), as a demo: its GIF is a recorded run of clicks.
// A queue in front of workers. Two toggles, on alone or together: the spike adds traffic, degraded halves
// workers A. What doesn't fit overflows to workers B; what fits nowhere piles up in the queue, and drains
// once there's room again.
/** @param {number} x @param {number} y @param {string} text @param {object} [more] */
const box = (x, y, text, more = {}) =>
  dottie.rect({x, y, width: 150, height: 64, text, anchor: text, fill: "#ffffff", strokeWidth: 2, ...more});
const producers = dottie.ellipse({x: 20, y: 260, width: 140, height: 70, text: "producers", fill: "#e8f0ff"});
const api = box(210, 263, "API");
const queue = box(420, 263, "queue", {fill: "#fff4d6", delay: 0.4});   // holds each message 0.4s
const a = box(680, 140, "workers A", {capacity: 4});                   // takes 4 a second
const b = box(680, 390, "workers B", {capacity: 2});
dottie.connect(producers, api); dottie.connect(api, queue);
dottie.connect(queue, a); dottie.connect(queue, b, {label: "overflow"});
// Normal traffic (3 a second), and a spike (4 more) only in the spike scenario.
const normal = dottie.flow(producers, [a, b], {volume: 3, every: 0.3, color: "#2f6fdf"});
dottie.flow(producers, [a, b], {volume: 4, every: 0.3, color: "#d97706", when: "spike"});
// addOverride keeps an element's other overrides (update with overrides would replace them).
dottie.addOverride(a, {when: "degraded", capacity: 2, text: "workers A (half down)", dash: "dashed"});
// Saturated workers turn red: an override on each comparing its own load (it changes looks only).
dottie.alarm([a, b]);
dottie.gauge(a, {metric: "load", x: 900, y: 120, width: 170, height: 110, style: "dial", label: "workers A load"});
dottie.gauge(b, {metric: "load", x: 900, y: 370, width: 170, height: 110, style: "dial", label: "workers B load"});
dottie.gauge(queue, {metric: "backlog", x: 420, y: 380, width: 150, height: 70, style: "bar", max: 5,
                     warn: 0.01, alarm: 1, label: "queue growing /s"});
dottie.gauge(queue, {metric: "depth", x: 420, y: 460, width: 150, height: 60, warn: 0.01, alarm: 10,
                     label: "messages waiting"});
dottie.gauge(normal, {metric: "transit", x: 210, y: 380, width: 150, height: 70, label: "transit"});
// Independent toggles rather than a choice, so both can be on at once.
dottie.button({x: 220, y: 60, text: "traffic spike", toggles: "spike", onText: "spike: on"});
dottie.button({x: 400, y: 60, text: "workers degraded", toggles: "degraded", onText: "degraded: on"});
dottie.resetButton({x: 760, y: 60});
