import XCTest
@testable import DottieKit

/// Traffic flows (ADR 0002): packets routed each frame over the connectors drawn, so state reroutes them.
final class FlowTests: XCTestCase {
    /// client → api → east, api → west.
    private func page() -> (DottieDocument, client: UUID, api: UUID, east: UUID, west: UUID) {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        func box(_ x: Double, _ y: Double, _ t: String) -> Element {
            Element(kind: .rectangle, frame: CGRect(x: x, y: y, width: 80, height: 50), layerID: layer, text: t)
        }
        let client = box(0, 100, "client"), api = box(200, 100, "api"), east = box(400, 0, "east"), west = box(400, 200, "west")
        func line(_ a: Element, _ b: Element) -> Element {
            Element(kind: .connector, frame: .zero, layerID: layer, connector: ConnectorData(start: .bound(a.id), end: .bound(b.id)))
        }
        doc.elements = [client, api, east, west, line(client, api), line(api, east), line(api, west)]
        return (doc, client.id, api.id, east.id, west.id)
    }

    private func packets(_ frame: DottieDocument) -> [Element] { frame.elements.filter { $0.kind == .ellipse } }

    func testTrafficFailsOverWhenAStateHidesTheWay() throws {
        var (doc, client, _, east, west) = page()
        let flow = try DiagramOps.addFlow(&doc, from: client, to: [east, west], every: 0.5, speed: 100)
        XCTAssertEqual(doc.timeline?.duration, 4)   // a page with flows plays
        XCTAssertEqual(flow.every, 0.5)
        try DiagramOps.defineState(&doc, { var s = StateSpec(name: "eastDown"); s.hide = [east]; return s }())
        func ys(_ s: StateChoice) -> [CGFloat] { packets(doc.posed(at: 3.9, state: s)).map(\.frame.midY) }
        // Packets near the end of the route sit by east (above), or by west (below) when east is down.
        XCTAssertTrue(ys(.initial).contains { $0 < 100 })
        XCTAssertFalse(ys(.initial).contains { $0 > 150 })
        XCTAssertTrue(ys(.values(["eastDown": true])).contains { $0 > 150 })
        XCTAssertFalse(ys(.values(["eastDown": true])).contains { $0 < 100 })
        // Taken down instead of hidden: still drawn, faded, and the traffic still goes to west.
        var faded = doc
        faded.elements = faded.elements.map { var e = $0; e.when = nil; return e }
        faded.variables = [:]
        try DiagramOps.defineState(&faded, { var s = StateSpec(name: "eastDown"); s.down = [east]; return s }())
        let down = faded.posed(at: 3.9, state: .values(["eastDown": true]))
        XCTAssertNotNil(down.elements.first { $0.id == east })
        XCTAssertTrue(packets(down).allSatisfy { $0.frame.midY > 100 })
        // Nothing to reach: nothing flows.
        var none = doc
        none.flows![0].to = [client]
        XCTAssertTrue(packets(none.posed(at: 1)).isEmpty)
    }

    func testPacketsAreAFunctionOfTimeWithStableIDs() throws {
        var (doc, client, _, east, _) = page()
        try DiagramOps.addFlow(&doc, from: client, to: [east], every: 0.5, speed: 100)
        let a = packets(doc.posed(at: 1.0)), b = packets(doc.posed(at: 1.1))
        XCTAssertFalse(a.isEmpty)
        // Traffic is already in flight at the start, and the same packet keeps its id as it moves on.
        XCTAssertFalse(packets(doc.posed(at: 0)).isEmpty)
        let shared = Set(a.map(\.id)).intersection(b.map(\.id))
        XCTAssertFalse(shared.isEmpty)
        // The pattern repeats every `every` seconds, so the loop is seamless.
        XCTAssertEqual(packets(doc.posed(at: 0)).map(\.frame), packets(doc.posed(at: 4)).map(\.frame))
        XCTAssertEqual(Flow.packetID(doc.flows![0].id, -3).uuidString.prefix(24), doc.flows![0].id.uuidString.prefix(24))
        XCTAssertNotEqual(Flow.packetID(doc.flows![0].id, -3), Flow.packetID(doc.flows![0].id, 3))
        // A frame is a still: posing it again adds nothing.
        XCTAssertNil(doc.posed(at: 1).flows)
    }

    func testEveryIsRoundedToLoopAndConditionsGate() throws {
        var (doc, client, _, east, _) = page()
        doc.timeline = Timeline(duration: 3)
        let f = try DiagramOps.addFlow(&doc, from: client, to: [east], every: 0.7, when: "busy")
        XCTAssertEqual(f.every!, 0.75, accuracy: 1e-9)
        XCTAssertTrue(packets(doc.posed(at: 1)).isEmpty)
        XCTAssertFalse(packets(doc.posed(at: 1, state: .values(["busy": true]))).isEmpty)
        XCTAssertTrue(doc.usesState)
        XCTAssertThrowsError(try DiagramOps.addFlow(&doc, from: client, to: []))
        XCTAssertThrowsError(try DiagramOps.addFlow(&doc, from: UUID(), to: [east]))
        XCTAssertThrowsError(try DiagramOps.addFlow(&doc, from: client, to: [east], when: "a |"))
        doc.remove([east])
        XCTAssertNil(doc.flows)
    }

    func testArrowsSayWhichWayTrafficGoes() {
        var (doc, client, api, _, _) = page()
        // Only client → api exists; api can't send back unless the start has an arrowhead.
        XCTAssertNil(DottieDocument.flowRoute(from: api, to: [client], in: doc))
        doc.elements[4].connector?.startHead = .arrow
        XCTAssertEqual(DottieDocument.flowRoute(from: api, to: [client], in: doc)?.map(\.1), [true])
    }

    func testLenientDecoding() throws {
        let json = #"{"id": 3, "from": "nope", "to": ["\#(UUID().uuidString)", "bad"], "every": "fast"}"#
        let f = try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
        XCTAssertEqual(f.to.count, 1)
        XCTAssertNil(f.every)
        XCTAssertEqual(f.from.uuidString, "00000000-0000-0000-0000-000000000000")
    }

    func testScriptFlows() {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const a = dottie.rect({x: 0, y: 0, text: "a"}), b = dottie.rect({x: 300, y: 0, text: "b"});
            dottie.connect(a, b);
            const f = dottie.flow(a, b, {every: 1, color: "#3366ff"});
            const g = dottie.flow(a, [b], {id: f.id, speed: 50});
            const n = dottie.flows().length;
            return [f.every, f.color, g.speed, g.id === f.id, n, dottie.removeFlow(f), dottie.flows().length];
            """, on: &doc, libraries: [.starter], timeLimit: 5)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, ##"[1,"#3366ff",50,true,1,true,0]"##)
    }
}
