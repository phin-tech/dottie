import Foundation

/// Worked run_script programs for interactive pages, served by the MCP server as `dottie://examples/<name>` and by
/// `script_api` with `example`. Each runs on an empty page; ScriptExamplesTests runs and type-checks every one, so
/// they stay in step with the API. They present scenarios: the numbers are chosen to tell a story, not forecasts.
public enum ScriptExamples {
    public struct Example: Sendable {
        public let name, title, summary, code: String
    }

    public static let all: [Example] = [regionFailover, queueWorkers, awsOutage]

    public static func named(_ name: String) -> Example? { all.first { $0.name == name } }

    static let regionFailover = Example(
        name: "region-failover",
        title: "Region failover with colored traffic",
        summary: "Three regions, each with its own traffic color; clicking a region takes it down and its traffic is "
            + "spread over the others (flow spread, defineState down, legend, reset).",
        code: #"""
        // Region failover: each region's traffic has its own color. Click a region to take it down; its traffic is
        // spread over the regions still up, keeping its color so you can see where it went.
        /** @param {number} y @param {string} name @param {string} color */
        const region = (y, name, color) =>
          dottie.rect({x: 520, y, width: 150, height: 64, text: name, anchor: name, stroke: color, strokeWidth: 3, fill: "#ffffff"});
        const users = dottie.ellipse({x: 40, y: 210, width: 130, height: 70, text: "users", fill: "#e8f0ff"});
        const lb = dottie.rect({x: 260, y: 213, width: 150, height: 64, text: "global load balancer"});
        dottie.connect(users, lb);
        const names = ["us-east-1", "us-east-2", "us-west-2"], colors = ["#2f6fdf", "#16a34a", "#d97706"];
        const regions = names.map((n, i) => region(60 + 153 * i, n, colors[i]));
        for (const r of regions) dottie.connect(lb, r);
        regions.forEach((r, i) => {
          // Aim at this region; while it's down, deal the packets across the others (spread).
          dottie.flow(users, [r, ...regions.filter((x) => x !== r)], {spread: true, color: colors[i], size: 14});
          // One variable per region: down (faded, carrying nothing), relabelled, flipped by clicking the region.
          dottie.defineState(names[i].replace(/-/g, "_") + "_down", {
            down: r, restyle: [[r, {text: names[i] + " (down)", stroke: "#dc2626", dash: "dashed"}]], toggledBy: r,
          });
        });
        dottie.legend({x: 760, y: 150});
        dottie.resetButton({x: 760, y: 60});
        """#)

    static let queueWorkers = Example(
        name: "queue-workers",
        title: "A queue in front of workers",
        summary: "Producers, a queue and two worker pools with capacities; two toggles, which can be on together, add a "
            + "traffic spike and halve the workers, and gauges show load and the queue filling and draining (volume, "
            + "capacity, delay, backlog, depth, metric overrides, gauges, buttons).",
        code: #"""
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
        // An override comparing a metric, by anchor, changes looks only: saturated workers turn red.
        for (const name of ["workers A", "workers B"]) {
          dottie.addOverride(name === "workers A" ? a : b, {when: `load(${name}) >= 1`, stroke: "#dc2626", textColor: "#dc2626"});
        }
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
        """#)

    static let awsOutage = Example(
        name: "aws-outage",
        title: "A multi-region outage",
        summary: "Route 53 in front of two regions (ALB, ECS, DynamoDB); scenarios take us-east-1 down, scale out "
            + "us-west-2, or throttle a table, and a traffic row works as a stepped slider (offline overrides, page-order "
            + "priority, capacity overrides, choices as a slider).",
        code: #"""
        // A multi-region outage. Scenarios: us-east-1 goes down (its users fail over and overload us-west-2),
        // us-west-2 scales out, or east's table is throttled. The traffic row is a slider made of buttons.
        /** @param {number} x @param {number} y @param {string} text @param {string} anchor @param {object} [more] */
        const box = (x, y, text, anchor, more = {}) =>
          dottie.rect({x, y, width: 150, height: 60, text, anchor, fill: "#ffffff", strokeWidth: 2, ...more});
        const outage = "scenario_us_east_1_outage || scenario_failover_scaled";
        // Region frames first, so they sit behind.
        dottie.rect({x: 390, y: 150, width: 610, height: 150, fill: "#f3f6fb", stroke: "#9aa7b8", dash: "dashed", sketchy: false});
        dottie.rect({x: 390, y: 400, width: 610, height: 150, fill: "#f3f6fb", stroke: "#9aa7b8", dash: "dashed", sketchy: false});
        const eastLabel = dottie.text({x: 400, y: 155, width: 300, text: "us-east-1"});
        dottie.text({x: 400, y: 405, text: "us-west-2"});
        const users = dottie.ellipse({x: 20, y: 320, width: 140, height: 70, text: "users", fill: "#e8f0ff"});
        const r53 = box(200, 325, "Route 53", "r53", {fill: "#f3e8ff"});
        const albE = box(420, 195, "ALB", "albEast"), ecsE = box(610, 195, "ECS service", "ecsEast", {capacity: 6});
        const ddbE = box(800, 195, "DynamoDB", "ddbEast", {fill: "#fff4d6", capacity: 8});
        const albW = box(420, 445, "ALB", "albWest"), ecsW = box(610, 445, "ECS service", "ecsWest", {capacity: 4});
        const ddbW = box(800, 445, "DynamoDB", "ddbWest", {fill: "#fff4d6", capacity: 8});
        dottie.connect(users, r53);
        dottie.connect(r53, albE); dottie.connect(albE, ecsE); dottie.connect(ecsE, ddbE);
        dottie.connect(r53, albW); dottie.connect(albW, ecsW); dottie.connect(ecsW, ddbW);
        // A high cost keeps traffic off the replication link unless nothing else is left.
        dottie.connect(ddbE, ddbW, {label: "global table", dash: "dashed", arrow: false, cost: 1000});
        // East users prefer us-east-1, west users us-west-2; each fails over to the other. Earlier flows come first
        // when capacity runs short, so in the outage east users fill us-west-2 and west users queue.
        const east = dottie.flow(users, [ddbE, ddbW], {volume: 5, every: 0.25, color: "#2f6fdf"});
        dottie.flow(users, [ddbW, ddbE], {volume: 3, every: 0.25, color: "#d97706"});
        for (const step of ["traffic_2x || traffic_3x", "traffic_3x"]) {
          dottie.flow(users, [ddbE, ddbW], {volume: 5, every: 0.25, color: "#2f6fdf", when: step});
          dottie.flow(users, [ddbW, ddbE], {volume: 3, every: 0.25, color: "#d97706", when: step});
        }
        // The outage: us-east-1 still drawn, faded, carrying nothing.
        for (const e of [albE, ecsE, ddbE]) dottie.addOverride(e, {when: outage, opacity: 0.35, offline: true, stroke: "#dc2626", dash: "dashed"});
        dottie.addOverride(eastLabel, {when: outage, text: "us-east-1 (outage)", textColor: "#dc2626"});
        dottie.addOverride(ecsW, {when: "scenario_failover_scaled", capacity: 10, text: "ECS service (scaled out)"});
        dottie.addOverride(ddbE, {when: "scenario_DynamoDB_throttling", capacity: 2, text: "DynamoDB (throttled)"});
        for (const [e, anchor] of /** @type {[any, string][]} */ ([[ecsE, "ecsEast"], [ecsW, "ecsWest"], [ddbE, "ddbEast"]])) {
          dottie.addOverride(e, {when: `load(${anchor}) >= 1`, stroke: "#dc2626", textColor: "#dc2626"});
        }
        dottie.addOverride(albW, {when: "backlog(albWest) > 0", stroke: "#dc2626", text: "ALB (requests queuing)"});
        dottie.gauge(ecsE, {metric: "load", x: 1030, y: 160, width: 170, height: 110, style: "dial", label: "us-east-1 load"});
        dottie.gauge(ecsW, {metric: "load", x: 1030, y: 410, width: 170, height: 110, style: "dial", label: "us-west-2 load"});
        dottie.gauge(east, {metric: "backup", x: 200, y: 165, width: 160, height: 70, style: "bar", max: 1, warn: 0.01, alarm: 0.5,
                            label: "east users via west"});
        dottie.gauge(albW, {metric: "backlog", x: 200, y: 450, width: 160, height: 70, style: "bar", max: 12, warn: 0.01, alarm: 1,
                            label: "west queuing /s"});
        dottie.choice("scenario", ["normal", "us-east-1 outage", "failover scaled", "DynamoDB throttling"], {x: 260, y: 60});
        dottie.text({x: 20, y: 110, text: "Traffic:"});
        dottie.choice("traffic", ["1x", "2x", "3x"], {x: 100, y: 105});
        dottie.resetButton({x: 1060, y: 105});
        """#)
}
