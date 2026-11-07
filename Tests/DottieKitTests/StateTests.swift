import XCTest
@testable import DottieKit

/// Page variables, `when` conditions, clicks that change state, and looping scenes (issues #3 and #4).
final class StateTests: XCTestCase {
    private func run(_ src: String, _ doc: inout DottieDocument) -> ScriptResult {
        DottieScript.run(src, on: &doc, libraries: [.starter], timeLimit: 5)
    }

    func testConditions() {
        let s = ["down": true, "east": false]
        XCTAssertTrue(PageState.holds("down", in: s))
        XCTAssertFalse(PageState.holds("!down", in: s))
        XCTAssertTrue(PageState.holds(" ! east ", in: s))
        XCTAssertTrue(PageState.holds("east || down && !east", in: s))
        XCTAssertFalse(PageState.holds("east && down", in: s))
        // A missing variable is false; a condition that can't be read never holds.
        XCTAssertTrue(PageState.holds("!nobody", in: s))
        XCTAssertFalse(PageState.holds("down |", in: s))
        XCTAssertFalse(PageState.holds("", in: s))
        XCTAssertFalse(PageState.holds("1st", in: s))
        XCTAssertEqual(PageState.names(in: "a && !b || c"), ["a", "b", "c"])
        XCTAssertNil(try PageState.checked(""))
        XCTAssertThrowsError(try PageState.checked("a ||"))
    }

    /// The starting values pick what a still and a frame show; connectors go with a shape the state hides, even
    /// one with visible keys of its own; `.all` (the editor) keeps everything.
    func testStateHidesElementsAndTheirConnectors() {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        var a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 50, height: 50), layerID: layer)
        var b = Element(kind: .rectangle, frame: CGRect(x: 200, y: 0, width: 50, height: 50), layerID: layer)
        a.when = "!down"; b.when = "down"
        let line = Element(kind: .connector, frame: .zero, layerID: layer,
                           connector: ConnectorData(start: .bound(a.id), end: .bound(b.id)))
        doc.elements = [a, b, line]
        doc.variables = ["down": false]
        XCTAssertEqual(doc.still.elements.map(\.id), [a.id])
        XCTAssertEqual(doc.posed(at: 0, state: .values(["down": true])).elements.map(\.id), [b.id])
        XCTAssertEqual(doc.posed(at: 0, state: .all).elements.count, 3)

        var tl = Timeline(duration: 2)
        tl.setKey(Keyframe(t: 0, visible: true), for: line.id)
        doc.timeline = tl
        XCTAssertEqual(doc.resolved(at: 1).elements.map(\.id), [a.id])
    }

    func testClickDecodingAndApplying() throws {
        let one = try JSONDecoder().decode(ClickAction.self, from: Data(#"{"toggle":"down","set":{"maint":true,"9bad":true}}"#.utf8))
        XCTAssertEqual(one.toggle, ["down"])
        XCTAssertEqual(one.set, ["maint": true])
        XCTAssertTrue(one.changesState)
        XCTAssertEqual(one.applied(to: ["down": true, "maint": false]), ["down": false, "maint": true])
        XCTAssertEqual(ClickAction(set: [:], toggle: []).isEmpty, true)
    }

    /// Item 4 of #3: dottie.scene returns the name a click takes; and loop, variables, when and click state.
    func testScriptAPI() {
        var doc = DottieDocument()
        let r = run("""
            const region = dottie.rect({x: 0, y: 0, text: "east"});
            const other = dottie.rect({x: 200, y: 0, text: "west", when: "!down"});
            const live = dottie.scene(0, {loop: true});
            const out = dottie.scene(2, "Outage");
            dottie.variable("down");
            dottie.variable("maint", true);
            dottie.update(region, {click: {toggle: "down", scene: out}});
            const line = dottie.connect(region, other);
            dottie.packet(line, 0, {when: "!down"});
            dottie.loopScene("Outage");
            const v = dottie.variables(), c = dottie.get(region.id).click;
            return [live, out, v.down, v.maint, c.scene, c.toggle, dottie.get(other.id).when];
            """, &doc)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, ##"["Scene 1","Outage",false,true,"Outage",["down"],"!down"]"##)
        XCTAssertEqual(doc.timeline?.markers?.map(\.loop), [true, true])
        XCTAssertEqual(doc.elements.last?.when, "!down")
        XCTAssertTrue(doc.usesState)
    }

    /// Item 3 of #3: a lookup that found nothing names the snapshot trap instead of "Missing required argument".
    func testStaleLookupExplainsSnapshots() {
        var doc = DottieDocument()
        let r = run("""
            dottie.rect({x: 0, y: 0, text: "old"});
            const all = dottie.elements();
            dottie.update(all[0], {text: "new"});
            const found = dottie.elements().find((e) => e.text === "old");
            dottie.update(found, {fill: "#ff0000"});
            """, &doc)
        XCTAssertTrue(r.error?.contains("snapshots") == true, r.error ?? "no error")
    }

    func testBadNamesAndConditionsAreRefused() {
        var doc = DottieDocument()
        XCTAssertNotNil(run(#"dottie.variable("2fast", true)"#, &doc).error)
        XCTAssertNotNil(run(#"const a = dottie.rect({x: 0, y: 0}); dottie.update(a, {when: "a |"})"#, &doc).error)
        XCTAssertNotNil(run(#"const a = dottie.rect({x: 0, y: 0}); dottie.update(a, {click: {toggle: "no way"}})"#, &doc).error)
    }

    /// Item 6 of #3: build's edges take look fields, a stroke and a condition.
    func testBuildEdgesTakeLooks() {
        var doc = DottieDocument()
        let r = run("""
            dottie.build({nodes: [{key: "a", text: "A"}, {key: "b", text: "B"}],
                          edges: [{from: "a", to: "b", dash: "dashed", strokeWidth: 4, endHead: "dot", stroke: "#888888", when: "future"}]});
            """, &doc)
        XCTAssertNil(r.error)
        let c = doc.elements.first { $0.kind == .connector }
        XCTAssertEqual(c?.style.dash, .dashed)
        XCTAssertEqual(c?.style.strokeWidth, 4)
        XCTAssertEqual(c?.connector?.endHead, .dot)
        XCTAssertEqual(c?.style.stroke, RGBA(hex: "#888888"))
        XCTAssertEqual(c?.when, "future")
    }

    /// Pages with state and pages with looping scenes both export as dottie.js's player.
    func testHTMLExports() throws {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        var a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 50, height: 50), layerID: layer)
        a.click = ClickAction(toggle: ["down"])
        doc.elements = [a]
        let stateful = try XCTUnwrap(Exporter.player(doc))
        XCTAssertTrue(stateful.contains("dottie-player"))
        XCTAssertFalse(stateful.contains("</script></script>"))

        a.click = ClickAction(scene: "Live")
        doc.elements = [a]
        var tl = Timeline(duration: 2)
        tl.setKey(Keyframe(t: 0, x: 0), for: a.id)
        tl.setKey(Keyframe(t: 2, x: 100), for: a.id)
        tl.addMarker(at: 0, name: "Live", loop: true)
        doc.timeline = tl
        let looping = try XCTUnwrap(Exporter.player(doc))
        XCTAssertTrue(looping.contains("dottie-player"))
        XCTAssertTrue(looping.contains(#""loop":true"#), "the loop travels with the drawing")
    }

    func testEditSceneLoops() throws {
        var doc = DottieDocument()
        var tl = Timeline(duration: 3)
        tl.addMarker(at: 1, name: "A")
        doc.timeline = tl
        XCTAssertEqual(try DiagramOps.editScene(&doc, scene: "a", moveTo: 2, loop: true), "Scene moved to 2.0s, loops")
        XCTAssertEqual(doc.timeline?.markers, [Marker(t: 2, name: "A", loop: true)])
        try DiagramOps.editScene(&doc, scene: "A", loop: false)
        XCTAssertNil(doc.timeline?.markers?.first?.loop)
    }
}
