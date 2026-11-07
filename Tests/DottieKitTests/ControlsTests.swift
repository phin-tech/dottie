import XCTest
@testable import DottieKit

/// Controls (ADR 0003): buttons, choices, reset and legend, written as ordinary clicks, variables and overrides.
final class ControlsTests: XCTestCase {
    private func pick(_ doc: DottieDocument, _ id: UUID, _ values: [String: Bool]) -> Element? {
        doc.posed(at: 0, state: .values(values)).elements.first { $0.id == id }
    }

    func testButtonTogglesAndLooksPressed() throws {
        var doc = DottieDocument()
        var spec = ButtonSpec(text: "Take east down")
        spec.toggles = "eastDown"; spec.onText = "Bring east back"
        let b = try DiagramOps.addButton(&doc, spec)
        XCTAssertEqual(doc.variables, ["eastDown": false])
        XCTAssertEqual(b.click?.toggle, ["eastDown"])
        XCTAssertEqual(pick(doc, b.id, ["eastDown": false])?.text, "Take east down")
        let on = try XCTUnwrap(pick(doc, b.id, ["eastDown": true]))
        XCTAssertEqual(on.text, "Bring east back")
        XCTAssertEqual(on.style.fill, DiagramOps.controlColor)
        // Clicking it in a simulation flips the variable, and finds it by the label shown.
        var sim = try Simulation(doc)
        _ = try sim.click("Take east down")
        XCTAssertEqual(sim.state["eastDown"], true)
        _ = try sim.click("Bring east back")
        XCTAssertEqual(sim.state["eastDown"], false)
        // A button that sets values is pressed while they all hold.
        var setter = ButtonSpec(text: "Spike")
        setter.sets = ["spike": true, "calm": false]
        let s = try DiagramOps.addButton(&doc, setter)
        XCTAssertEqual(s.overrides?.first?.when, "!calm && spike")
        XCTAssertThrowsError(try DiagramOps.addButton(&doc, ButtonSpec(text: "Nothing")))
    }

    func testChoiceIsExclusive() throws {
        var doc = DottieDocument()
        let made = try DiagramOps.addChoice(&doc, name: "scenario", options: ["normal", "east out", "spike"], x: 0, y: 0, initial: "spike")
        XCTAssertEqual(made.map(\.variable), ["scenario_normal", "scenario_east_out", "scenario_spike"])
        XCTAssertEqual(doc.variables, ["scenario_normal": false, "scenario_east_out": false, "scenario_spike": true])
        XCTAssertLessThan(made[0].button.frame.maxX, made[1].button.frame.minX)   // a row, not overlapping
        var sim = try Simulation(doc)
        _ = try sim.click("east out")
        XCTAssertEqual(sim.state, ["scenario_normal": false, "scenario_east_out": true, "scenario_spike": false])
        _ = try sim.click("normal")
        XCTAssertEqual(sim.state, ["scenario_normal": true, "scenario_east_out": false, "scenario_spike": false])
        XCTAssertEqual(pick(doc, made[0].button.id, sim.state)?.style.fill, DiagramOps.controlColor)
        XCTAssertNotEqual(pick(doc, made[1].button.id, sim.state)?.style.fill, DiagramOps.controlColor)
        XCTAssertThrowsError(try DiagramOps.addChoice(&doc, name: "x", options: ["a b", "a_b"], x: 0, y: 0))
    }

    func testResetRestoresStartingValues() throws {
        var doc = DottieDocument()
        XCTAssertThrowsError(try DiagramOps.addReset(&doc, x: 0, y: 0))
        try DiagramOps.addChoice(&doc, name: "mode", options: ["a", "b"], x: 0, y: 0)
        let r = try DiagramOps.addReset(&doc, x: 0, y: 100)
        var sim = try Simulation(doc)
        _ = try sim.click("b")
        _ = try sim.click("Reset")
        XCTAssertEqual(sim.state, ["mode_a": true, "mode_b": false])
        XCTAssertEqual(doc.elements.first { $0.id == r.id }?.click?.reset, true)
        // A variable added later is covered with nothing rewritten: reset is an action, not a list of values.
        try doc.setVariable("later", to: true)
        var again = try Simulation(doc)
        _ = try again.click("b")
        _ = try again.click("Reset")
        XCTAssertEqual(again.state, ["mode_a": true, "mode_b": false, "later": true])
        try DiagramOps.addReset(&doc, x: 0, y: 0, replacing: r.id)
        XCTAssertEqual(doc.elements.filter { $0.text == "Reset" }.count, 1)
    }

    func testLegendHidesAFlow() throws {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        let a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 40), layerID: layer, text: "a")
        let b = Element(kind: .rectangle, frame: CGRect(x: 300, y: 0, width: 80, height: 40), layerID: layer, text: "b")
        doc.elements = [a, b, Element(kind: .connector, frame: .zero, layerID: layer,
                                      connector: ConnectorData(start: .bound(a.id), end: .bound(b.id)))]
        try DiagramOps.addFlow(&doc, from: a.id, to: [b.id], every: 0.5, when: nil)
        let rows = try DiagramOps.addLegend(&doc, x: 0, y: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label.text, "a → b")
        XCTAssertEqual(doc.flows?[0].when, "show_1")
        func packets(_ v: [String: Bool]) -> Int {
            doc.posed(at: 1, state: .values(v)).elements.filter { $0.kind == .ellipse && $0.id != rows[0].swatch.id }.count
        }
        XCTAssertGreaterThan(packets(["show_1": true]), 0)
        XCTAssertEqual(packets(["show_1": false]), 0)
        var sim = try Simulation(doc)
        _ = try sim.click("a → b")
        XCTAssertEqual(sim.state["show_1"], false)
        XCTAssertEqual(pick(doc, rows[0].swatch.id, sim.state)?.style.opacity, 0.3)
        // Again: the same variable, not show_1 && show_1.
        try DiagramOps.addLegend(&doc, x: 0, y: 200)
        XCTAssertEqual(doc.flows?[0].when, "show_1")
    }

    func testScriptControls() {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const b = dottie.button({text: "Go", toggles: "go", onText: "Stop"});
            const c = dottie.choice("mode", ["x", "y"], {x: 0, y: 100});
            const reset = dottie.resetButton({x: 0, y: 200});
            const a = dottie.rect({x: 0, y: 300, text: "a"}), z = dottie.rect({x: 300, y: 300, text: "z"});
            dottie.connect(a, z);
            const f = dottie.flow(a, z);
            const legend = dottie.legend({x: 0, y: 400, labels: [[f, "traffic"]]});
            return [b.text, c.map(o => o.variable), reset.text, legend[0].label.text, Object.keys(dottie.variables()).sort()];
            """, on: &doc, libraries: [.starter], timeLimit: 5)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, #"["Go",["mode_x","mode_y"],"Reset","traffic",["go","mode_x","mode_y","show_1"]]"#)
    }
}
