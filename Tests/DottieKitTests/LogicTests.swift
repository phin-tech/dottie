import XCTest
@testable import DottieKit

/// Click logic (ADR 0007, step 2): handlers run in dottie.js's QuickJS sandbox, here in JavaScriptCore.
final class LogicTests: XCTestCase {
    private func page(_ logic: String, run: String = "next") throws -> DottieDocument {
        var doc = DottieDocument()
        try doc.setVariable("stage", to: 0)
        try doc.setVariable("count", to: 0)
        doc.logic = logic
        var e = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 50), at: .zero,
                                        text: "next", fill: nil, stroke: nil, roughness: 0)
        e.click = ClickAction(set: ["count": 99], run: run)
        doc.elements[0] = e
        return doc
    }

    func testAHandlerCyclesAStage() throws {
        let doc = try page("function next(s, click) { return { stage: (s.stage + 1) % 3, count: s.count + 1, sawText: click.text === 'next' }; }")
        var sim = try Simulation(doc)
        for _ in 0..<4 { _ = try sim.click("next") }
        XCTAssertEqual(sim.state["stage"], 1)
        XCTAssertEqual(sim.state["count"], 4)
        XCTAssertEqual(sim.state["sawText"], true)
    }

    func testWithoutLogicTheClickFallsBack() throws {
        var sim = try Simulation(try page("function next(s) { return { stage: 2 }; }"))
        sim.allowLogic = false
        _ = try sim.click("next")
        XCTAssertEqual(sim.state["count"], 99)
        XCTAssertEqual(sim.state["stage"], 0)
    }

    func testRunawayAndBrokenHandlersLeaveTheStateAlone() throws {
        for (source, why) in [("function next() { for (;;) {} }", "ran too long"),
                              ("function next() { throw new Error('nope'); }", "nope"),
                              ("function next() { return { stage: 'x' }; }", "finite numbers"),
                              ("function other() {}", "No handler")] {
            let doc = try page(source)
            let (state, problem) = doc.clicked(doc.elements[0], state: ["stage": 1])
            XCTAssertEqual(state, ["stage": 1], source)
            XCTAssertTrue(problem?.contains(why) == true, "\(source): \(problem ?? "no problem")")
        }
    }

    func testTheSandboxHasNothingThatVaries() throws {
        let doc = try page("function next() { return { t: typeof Date === 'undefined', r: typeof Math.random === 'undefined', f: typeof fetch === 'undefined', s: typeof setTimeout === 'undefined' }; }")
        let (state, problem) = doc.clicked(doc.elements[0], state: [:])
        XCTAssertNil(problem)
        XCTAssertEqual(state, ["t": true, "r": true, "f": true, "s": true])
    }

    func testLogicMakesAFileVersionThree() throws {
        let file = DottieFile(pages: [try page("function next() { return {}; }")])
        let json = try JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 3)
        let back = try DottieFile.decode(file.encoded())
        XCTAssertEqual(back.pages[0].elements[0].click?.run, "next")
        XCTAssertNotNil(back.pages[0].logic)
    }

    func testSettingLogicChecksItRunsAndListsItsHandlers() throws {
        var doc = DottieDocument()
        XCTAssertEqual(try DiagramOps.setLogic(&doc, "function next(s) { return {}; }\nconst back = (s) => ({});"), ["next", "back"])
        XCTAssertThrowsError(try DiagramOps.setLogic(&doc, "function next( {")) { e in
            XCTAssertTrue("\(e)".contains("doesn't run"), "\(e)")
        }
        XCTAssertThrowsError(try DiagramOps.setLogic(&doc, "for (;;) {}"))
        try DiagramOps.setLogic(&doc, "")
        XCTAssertNil(doc.logic)
    }

    func testTheWebExportCarriesTheEngineOnlyWhenAllowed() throws {
        let doc = try page("function next(s) { return { stage: 1 }; }")
        let plain = try Exporter.script(doc)
        let allowed = try Exporter.script(doc, options: Exporter.ScriptOptions(allowLogic: true))
        // The engine's own code, and the attribute among the player's options.
        let engine = "Lifetime not alive", attribute = #""allow-logic":"""#
        XCTAssertFalse(plain.contains(engine))
        XCTAssertFalse(plain.contains(attribute))
        XCTAssertTrue(allowed.contains(engine))
        XCTAssertTrue(allowed.contains(attribute))
        XCTAssertGreaterThan(allowed.count - plain.count, 500_000, "the engine went in")
        // A page without logic gets neither, even when allowed.
        let none = try Exporter.script(DottieDocument(), options: Exporter.ScriptOptions(allowLogic: true))
        XCTAssertFalse(none.contains(attribute) || none.contains(engine))
    }
}
