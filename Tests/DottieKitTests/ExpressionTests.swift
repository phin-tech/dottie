import XCTest
@testable import DottieKit

/// ADR 0007's expression language against fixtures/expressions.json, which web/test/expression.test.ts checks too,
/// so Dottie and dottie.js agree on every value.
final class ExpressionTests: XCTestCase {
    private struct Table: Decodable {
        struct Case: Decodable { var expr: String; var state: [String: Var]; var value: Var }
        struct Metric: Decodable { var expr: String; var state: [String: Var]; var metrics: [String: Double]; var value: Var }
        var cases: [Case]
        var invalid: [String]
        var metrics: [Metric]
        struct Fill: Decodable { var text: String; var state: [String: Var]; var value: String }
        var fills: [Fill]
    }

    private func table() throws -> Table {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/expressions.json")
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
    }

    func testTheSharedTable() throws {
        let t = try table()
        XCTAssertGreaterThan(t.cases.count, 40)
        for c in t.cases {
            let e = try XCTUnwrap(Expr.parse(c.expr), c.expr)
            XCTAssertEqual(e.value(c.state), c.value, c.expr)
        }
        for s in t.invalid { XCTAssertNil(Expr.parse(s), s) }
        for c in t.metrics {
            let e = try XCTUnwrap(Expr.parse(c.expr), c.expr)
            XCTAssertEqual(e.value(c.state) { c.metrics["\($0.metric)(\($0.target))"] }, c.value, c.expr)
        }
        for f in t.fills { XCTAssertEqual(PageState.filling(f.text, f.state), f.value, f.text) }
    }

    func testOldConditionsMeanWhatTheyDid() {
        let s: [String: Var] = ["down": true, "east": false]
        XCTAssertTrue(PageState.holds("down", in: s))
        XCTAssertTrue(PageState.holds("east && !west || down", in: s))
        XCTAssertEqual(PageState.names(in: "east && !west || maint"), ["east", "west", "maint"])
        XCTAssertEqual(PageState.metricTerm("load(workers) >= 0.9"), PageState.MetricTerm(metric: "load", target: "workers", op: ">=", value: 0.9))
        XCTAssertEqual(PageState.metricTerm("load < -1")?.value, -1)
        XCTAssertNil(PageState.metricTerm("down"))
        XCTAssertTrue(PageState.mentionsMetric("down && load(x) > 1"))
        XCTAssertNil(PageState.names(in: "down &&"))
    }

    func testClicksComputeFromTheStateBefore() throws {
        let click = ClickAction(set: ["count": "count + 1", "stage": "(stage + 1) % 3", "seen": true], toggle: ["open"])
        var state: [String: Var] = ["count": 0, "stage": 2]
        for _ in 0..<3 { state = click.applied(to: state) }
        XCTAssertEqual(state, ["count": 3, "stage": 2, "seen": true, "open": true]) // stage 2, 0, 1, 2
        // Each is worked out from before any is given.
        let swap = ClickAction(set: ["a": "b", "b": "a"])
        XCTAssertEqual(swap.applied(to: ["a": 1, "b": 2]), ["a": 2, "b": 1])
        // A reset puts the starting values back first.
        let reset = ClickAction(set: ["count": "count + 1"], reset: true)
        XCTAssertEqual(reset.applied(to: ["count": 9], initial: ["count": 0]), ["count": 1])
    }

    func testVersionThreeOnlyWhenNeeded() throws {
        var file = DottieFile()
        try file.pages[0].setVariable("down", to: true)
        func version(_ f: DottieFile) throws -> Int {
            (try JSONSerialization.jsonObject(with: f.encoded()) as? [String: Any])?["version"] as? Int ?? 0
        }
        XCTAssertEqual(try version(file), 2)
        try file.pages[0].setVariable("count", to: 0)
        XCTAssertEqual(try version(file), 3)
        let back = try DottieFile.decode(try file.encoded())
        XCTAssertEqual(back.pages[0].variables, ["down": true, "count": 0])
    }
}

/// The counters fixture played as the web player would.
final class CounterSimulationTests: XCTestCase {
    func testClickingCountsUntilTheThresholdShows() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/edge/counters.dottie")
        let page = try DottieFile.decode(Data(contentsOf: url)).pages[0]
        var sim = try Simulation(page, scene: nil)
        let shown = { (s: Simulation) in s.picture.elements.contains { $0.text == "three or more" } }
        XCTAssertFalse(shown(sim))
        for _ in 0..<3 { _ = try sim.click("+1") }
        XCTAssertEqual(sim.state["count"], 3)
        XCTAssertTrue(shown(sim), sim.summary)
        XCTAssertTrue(sim.summary.contains("count=3") || sim.summary.contains("count = 3"), sim.summary)
        _ = try sim.click("next stage")
        XCTAssertEqual(sim.state["stage"], 1)
        XCTAssertEqual(sim.state["open"], false)
    }
}
