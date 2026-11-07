import XCTest
@testable import DottieKit

/// Per-state overrides (one element dims, relabels and reroutes instead of being drawn twice) and defineState, which
/// writes a variable's whole story at once.
final class OverrideTests: XCTestCase {
    /// api → east, api → west, and a packet on the east link.
    private func page() throws -> (DottieDocument, api: UUID, east: UUID, west: UUID, eastLink: UUID, westLink: UUID, dot: UUID) {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        let api = Element(kind: .rectangle, frame: CGRect(x: 0, y: 100, width: 80, height: 50), layerID: layer, text: "api")
        let east = Element(kind: .rectangle, frame: CGRect(x: 300, y: 0, width: 80, height: 50), layerID: layer, text: "east")
        let west = Element(kind: .rectangle, frame: CGRect(x: 300, y: 200, width: 80, height: 50), layerID: layer, text: "west")
        let el = Element(kind: .connector, frame: .zero, layerID: layer, connector: ConnectorData(start: .bound(api.id), end: .bound(east.id)))
        let wl = Element(kind: .connector, frame: .zero, layerID: layer, connector: ConnectorData(start: .bound(api.id), end: .bound(west.id)))
        doc.elements = [api, east, west, el, wl]
        let dot = try doc.addPacket(along: el.id, at: 0, duration: 2)
        return (doc, api.id, east.id, west.id, el.id, wl.id, dot.id)
    }

    private func center(_ doc: DottieDocument, _ id: UUID) -> CGPoint? {
        doc.elements.first { $0.id == id }.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }

    func testOverridesRestyleUnderTheirCondition() throws {
        var (doc, _, east, _, _, _, _) = try page()
        let i = doc.elements.firstIndex { $0.id == east }!
        doc.elements[i].style.opacity = 0.5
        doc.elements[i].overrides = [StateOverride(when: "down", fill: RGBA(r: 1, g: 0, b: 0), opacity: 0.4, text: "east (down)"),
                                     StateOverride(when: "down && maint", text: "maintenance")]
        doc.variables = ["down": false]
        let base = doc.posed(at: 1).elements.first { $0.id == east }!
        XCTAssertEqual(base.text, "east")
        let down = doc.posed(at: 1, state: .values(["down": true])).elements.first { $0.id == east }!
        XCTAssertEqual(down.text, "east (down)")
        XCTAssertEqual(down.style.fill, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(down.style.opacity ?? 1, 0.2, accuracy: 1e-9)   // opacity multiplies
        // Later overrides win; the editor (.all) shows the element as it is.
        XCTAssertEqual(doc.posed(at: 1, state: .values(["down": true, "maint": true])).elements.first { $0.id == east }?.text, "maintenance")
        XCTAssertEqual(doc.posed(at: 1, state: .all).elements.first { $0.id == east }?.text, "east")
        // A page without a timeline still applies them to its starting state.
        doc.timeline = nil
        doc.variables = ["down": true]
        XCTAssertEqual(doc.still.elements.first { $0.id == east }?.text, "east (down)")
        XCTAssertTrue(doc.usesState)
    }

    func testRerouteSendsTheSamePacketAlongAnotherConnector() throws {
        var (doc, _, _, west, eastLink, westLink, dot) = try page()
        let i = doc.elements.firstIndex { $0.id == dot }!
        doc.elements[i].overrides = [StateOverride(when: "eastDown", reroute: [eastLink: westLink])]
        let near = try XCTUnwrap(center(doc.posed(at: 1.95), dot))
        let detour = try XCTUnwrap(center(doc.posed(at: 1.95, state: .values(["eastDown": true])), dot))
        XCTAssertLessThan(near.y, 120)   // ends at east, above
        let westCenter = try XCTUnwrap(center(doc, west))
        XCTAssertLessThan(hypot(detour.x - westCenter.x, detour.y - westCenter.y), 60)
    }

    func testDecodingDropsBadRerouteKeysAndCase() throws {
        let to = UUID()
        let json = #"{"when":"down","dash":"wavy","reroute":{"not-an-id":"\#(to.uuidString)","\#(to.uuidString.lowercased())":"\#(to.uuidString)"}}"#
        let o = try JSONDecoder().decode(StateOverride.self, from: Data(json.utf8))
        XCTAssertNil(o.dash)
        XCTAssertEqual(o.reroute, [to.uuidString: to])
    }

    func testDefineStateWritesConditionsOverridesAndClicks() throws {
        var (doc, api, east, west, eastLink, westLink, dot) = try page()
        doc.elements[doc.elements.firstIndex { $0.id == west }!].when = "a || b"
        var spec = StateSpec(name: "eastDown")
        spec.hide = [eastLink]; spec.show = [west]; spec.dim = [east]
        spec.restyle = [east: StateOverride(when: "", text: "east (down)")]
        spec.reroute = [eastLink: westLink]
        spec.toggledBy = [east]; spec.turnedOffBy = [api]
        let summary = try DiagramOps.defineState(&doc, spec)
        XCTAssertEqual(summary, "eastDown (starts false): hides 1, shows 1, dims 1, restyles 1, reroutes 1, changed by 2 clicks")
        let again = doc
        try DiagramOps.defineState(&doc, spec)
        XCTAssertEqual(doc, again)   // idempotent

        func el(_ id: UUID) -> Element { doc.elements.first { $0.id == id }! }
        XCTAssertEqual(doc.variables, ["eastDown": false])
        XCTAssertEqual(el(eastLink).when, "!eastDown")
        XCTAssertEqual(el(west).when, "a && eastDown || b && eastDown")
        XCTAssertEqual(el(east).overrides, [StateOverride(when: "eastDown", opacity: 0.3, text: "east (down)")])
        XCTAssertEqual(el(dot).overrides?.first?.reroute, [eastLink.uuidString: westLink])
        XCTAssertEqual(el(east).click?.toggle, ["eastDown"])
        XCTAssertEqual(el(api).click?.set, ["eastDown": false])

        var bad = StateSpec(name: "x")
        bad.hide = [east]; bad.show = [east]
        XCTAssertThrowsError(try DiagramOps.defineState(&doc, bad))
        bad = StateSpec(name: "x"); bad.reroute = [east: west]
        XCTAssertThrowsError(try DiagramOps.defineState(&doc, bad))
        bad = StateSpec(name: "2x")
        XCTAssertThrowsError(try DiagramOps.defineState(&doc, bad))
    }

    func testCopiesRerouteAlongTheirOwnConnectors() throws {
        var (doc, _, _, _, eastLink, westLink, dot) = try page()
        doc.elements[doc.elements.firstIndex { $0.id == dot }!].overrides = [StateOverride(when: "d", reroute: [eastLink: westLink])]
        let ids = Set(doc.elements.map(\.id))
        let added = doc.duplicate(ids)
        let copyDot = try XCTUnwrap(doc.elements.first { added.contains($0.id) && $0.overrides != nil })
        let r = try XCTUnwrap(copyDot.overrides?.first?.reroute)
        XCTAssertFalse(r.keys.contains(eastLink.uuidString))
        XCTAssertFalse(r.values.contains(westLink))
        XCTAssertTrue(r.values.allSatisfy(added.contains))
    }

    func testScriptDefineStateAndOverrides() {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const api = dottie.rect({x: 0, y: 100, text: "api"});
            const east = dottie.rect({x: 300, y: 0, text: "east"}), west = dottie.rect({x: 300, y: 200, text: "west"});
            const eastLink = dottie.connect(api, east), westLink = dottie.connect(api, west);
            const dot = dottie.packet(eastLink, 0);
            const s = dottie.defineState("eastDown", {dim: east, restyle: [[east, {text: "east (down)", fill: "#ffdddd"}]],
                                                      reroute: [[eastLink, westLink]], toggledBy: east});
            dottie.update(west, {overrides: [{when: "eastDown", stroke: "#ff0000", reroute: {}}]});
            const e = dottie.get(east.id), w = dottie.get(west.id);
            return [s, e.overrides[0].text, e.overrides[0].opacity, e.overrides[0].fill, w.overrides[0].stroke,
                    dottie.get(dot.id).overrides[0].reroute[eastLink.id] === westLink.id, e.click.toggle];
            """, on: &doc, libraries: [.starter], timeLimit: 5)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, ##"["eastDown (starts false): dims 1, restyles 1, reroutes 1, changed by 1 click","east (down)",0.3,"#ffdddd","#ff0000",true,["eastDown"]]"##)
        var d2 = doc
        XCTAssertNil(DottieScript.run("dottie.update(dottie.elements()[2], {overrides: null})", on: &d2, libraries: [.starter], timeLimit: 5).error)
        XCTAssertNil(d2.elements[2].overrides)
    }

    /// A simulation clicks an element by the label it shows now, an override's included.
    func testSimulationFindsTheLabelShownNow() throws {
        var (doc, _, east, _, _, _, _) = try page()
        var spec = StateSpec(name: "down")
        spec.down = [east]; spec.restyle = [east: StateOverride(when: "", text: "east (down)")]; spec.toggledBy = [east]
        try DiagramOps.defineState(&doc, spec)
        var sim = try Simulation(doc)
        try sim.click("east")
        XCTAssertEqual(sim.state["down"], true)
        try sim.click("east (down)")
        XCTAssertEqual(sim.state["down"], false)
    }
}
