import XCTest
@testable import DottieKit

/// The worked examples MCP serves (ScriptExamples) run cleanly, type-check, leave no wiring warnings, and present
/// what they say they do.
final class ScriptExamplesTests: XCTestCase {
    func testEveryExampleRunsCleanlyWithNoWarnings() throws {
        for e in ScriptExamples.all {
            var doc = DottieDocument()
            let r = DottieScript.run(e.code, on: &doc, libraries: [.starter], timeLimit: 10)
            XCTAssertNil(r.error, e.name)
            XCTAssertGreaterThan(doc.elements.count, 8, e.name)
            XCTAssertEqual(DiagramOps.stateWarnings(doc), [], e.name)
            XCTAssertFalse(doc.posed(at: 1).elements.isEmpty, e.name)
        }
    }

    func testEveryExampleTypeChecks() throws {
        guard let tsc = DottieScript.findTypeScript() else { throw XCTSkip("TypeScript isn't installed") }
        for e in ScriptExamples.all {
            XCTAssertEqual(try DottieScript.typeCheck(e.code, compiler: tsc.url, version: tsc.version).diagnostics, [], e.name)
        }
    }

    func testTheExamplesShowTheirScenarios() throws {
        var doc = DottieDocument()
        XCTAssertNil(DottieScript.run(ScriptExamples.named("queue-workers")!.code, on: &doc, libraries: [.starter], timeLimit: 10).error)
        let queue = try XCTUnwrap(doc.elements.first { $0.anchor == "queue" }).id
        XCTAssertEqual(doc.metrics(at: 1).elements[queue]?.backlog, 0)
        XCTAssertEqual(doc.metrics(at: 1, state: .values(["spike": true])).elements[queue]?.backlog, 1)
        // Both at once: 7 a second against 2 + 2 of workers, so 3 a second pile up.
        XCTAssertEqual(doc.metrics(at: 1, state: .values(["spike": true, "degraded": true])).elements[queue]?.backlog, 3)

        var aws = DottieDocument()
        XCTAssertNil(DottieScript.run(ScriptExamples.named("aws-outage")!.code, on: &aws, libraries: [.starter], timeLimit: 10).error)
        let albWest = try XCTUnwrap(aws.elements.first { $0.anchor == "albWest" }).id
        let outage = aws.metrics(at: 1, state: .values(["scenario_normal": false, "scenario_us_east_1_outage": true]))
        XCTAssertEqual(outage.elements[albWest]?.backlog, 4)
        let scaled = aws.metrics(at: 1, state: .values(["scenario_normal": false, "scenario_failover_scaled": true]))
        XCTAssertEqual(scaled.elements[albWest]?.backlog, 0)
    }

    func testWarningsCatchTyposAndDanglingTargets() throws {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const a = dottie.rect({x: 0, y: 0, text: "a", anchor: "workers"});
            dottie.choice("scenario", ["Normal", "Busy"], {x: 0, y: 100});
            dottie.update(a, {when: "scenario_busy"});
            dottie.addOverride(a, {when: "load(worker) > 1", stroke: "#ff0000"});
            dottie.gauge(a, {metric: "load", x: 200, y: 0});
            """, on: &doc, libraries: [.starter], timeLimit: 5)
        XCTAssertNil(r.error)
        let w = DiagramOps.stateWarnings(doc)
        XCTAssertTrue(w.contains { $0.contains("`scenario_busy`") && $0.contains("Did you mean `scenario_Busy`?") }, "\(w)")
        XCTAssertTrue(w.contains { $0.contains("load(worker)") && $0.contains("Did you mean `workers`?") }, "\(w)")
        XCTAssertTrue(DiagramOps.describeVariables(doc).contains { $0.hasPrefix("scenario_Busy (starts false)") })
    }

    func testAddOverrideKeepsTheOthersAndMergesByCondition() throws {
        var doc = DottieDocument()
        let e = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), layerID: doc.layers[0].id)
        doc.elements = [e]
        try DiagramOps.addOverride(&doc, id: e.id, StateOverride(when: "down", opacity: 0.3))
        try DiagramOps.addOverride(&doc, id: e.id, StateOverride(when: "busy", text: "busy"))
        let list = try DiagramOps.addOverride(&doc, id: e.id, StateOverride(when: "down", text: "down"))
        XCTAssertEqual(list.map(\.when), ["down", "busy"])
        XCTAssertEqual(list[0].opacity, 0.3)
        XCTAssertEqual(list[0].text, "down")
    }

    func testResetPutsEveryVariableBackIncludingLaterOnes() throws {
        var doc = DottieDocument()
        try doc.setVariable("a", to: true)
        let reset = try DiagramOps.addReset(&doc, x: 0, y: 0)
        try doc.setVariable("b", to: false)
        let c = try XCTUnwrap(doc.elements.first { $0.id == reset.id }?.click)
        XCTAssertEqual(c.applied(to: ["a": false, "b": true, "extra": true], initial: doc.variables ?? [:]),
                       ["a": true, "b": false, "extra": false])
    }
}
