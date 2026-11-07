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
        // Nothing to reach: nothing moves; the volume is backlog, piled above the source (ADR 0003).
        var none = doc
        none.flows![0].to = [client]
        let pile = packets(none.posed(at: 1))
        XCTAssertEqual(pile.count, 2)   // a packet every 0.5s that couldn't leave, for 1s
        XCTAssertEqual(packets(none.posed(at: 1, state: .initial, since: 3)).count, 6)   // it grows while the state holds
        XCTAssertTrue(pile.allSatisfy { $0.frame.maxY < 100 && $0.frame.minX >= 0 && $0.frame.maxX < 80 })
        XCTAssertEqual(none.metrics(at: 1).flows[none.flows![0].id]?.backlog, 1)
        XCTAssertEqual(none.metrics(at: 1).elements[client]?.backlog, 1)
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

    func testTheCheapestRouteWins() throws {
        var (doc, client, _, east, west) = page()
        let layer = doc.layers[0].id
        // A direct line client → east: one hop, so it wins until it costs more than the two-hop way.
        var direct = Element(kind: .connector, frame: .zero, layerID: layer, connector: ConnectorData(start: .bound(client), end: .bound(east)))
        doc.elements.append(direct)
        XCTAssertEqual(DottieDocument.flowRoute(from: client, to: [east], in: doc)?.map(\.0), [direct.id])
        DiagramOps.Look(cost: 2.5).apply(to: &direct)
        XCTAssertEqual(direct.connector?.cost, 2.5)
        doc.elements[doc.elements.count - 1] = direct
        XCTAssertEqual(DottieDocument.flowRoute(from: client, to: [east], in: doc)?.count, 2)
        // A tie goes to the route found first: cost 2 ties, and the direct line was found first.
        doc.elements[doc.elements.count - 1].connector?.cost = 2
        XCTAssertEqual(DottieDocument.flowRoute(from: client, to: [east], in: doc)?.map(\.0), [direct.id])
        // Out of range is clamped; 1 clears it.
        DiagramOps.Look(cost: -4).apply(to: &direct)
        XCTAssertEqual(direct.connector?.cost, 0)
        DiagramOps.Look(cost: 1).apply(to: &direct)
        XCTAssertNil(direct.connector?.cost)
        // The preference order still picks the destination; cost only picks the way there.
        XCTAssertEqual(DottieDocument.flowRoute(from: client, to: [west, east], in: doc)?.count, 2)
        // The fixture: the five-cost direct line loses to the way round.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/edge/flows.dottie")
        let costPage = try DottieFile.decode(Data(contentsOf: url)).pages[2]
        let first = try XCTUnwrap(costPage.flows?.first)
        let route = try XCTUnwrap(DottieDocument.flowRoute(from: first.from, to: first.to, in: costPage))
        XCTAssertEqual(route.count, 2)
    }

    func testFlowsFromOneShapeTakeTurns() throws {
        var (doc, client, _, east, west) = page()
        // Two flows, same source and timing, one failing over onto the other's region: they interleave, never overlap.
        try DiagramOps.addFlow(&doc, from: client, to: [east], every: 0.5, speed: 100)
        try DiagramOps.addFlow(&doc, from: client, to: [west], every: 0.5, speed: 100)
        for t in stride(from: 0.0, through: 2, by: 0.25) {
            let frames = packets(doc.posed(at: t)).map(\.frame)
            XCTAssertEqual(Set(frames.map { "\($0.midX),\($0.midY)" }).count, frames.count, "at \(t)")
        }
    }

    func testSpreadSharesADownedRegionsTraffic() throws {
        var (doc, client, _, east, west) = page()
        let layer = doc.layers[0].id
        let north = Element(kind: .rectangle, frame: CGRect(x: 400, y: 400, width: 80, height: 50), layerID: layer, text: "north")
        doc.elements.append(north)
        doc.elements.append(Element(kind: .connector, frame: .zero, layerID: layer,
                                    connector: ConnectorData(start: .bound(doc.elements[1].id), end: .bound(north.id))))
        try DiagramOps.addFlow(&doc, from: client, to: [east, west, north.id], every: 0.25, speed: 400, spread: true)
        try DiagramOps.defineState(&doc, { var s = StateSpec(name: "eastDown"); s.down = [east]; return s }())
        // Where each packet past api is headed, by the slope of its line from api's center (240, 125).
        func ends(_ s: StateChoice) -> Set<String> {
            Set(stride(from: 3.0, through: 3.9, by: 0.05).flatMap { packets(doc.posed(at: $0, state: s)) }.filter { $0.frame.midX > 300 }.map { p in
                let slope = (p.frame.midY - 125) / (p.frame.midX - 240)
                return slope < 0 ? "east" : slope < 1 ? "west" : "north"
            })
        }
        XCTAssertEqual(ends(.initial), ["east"])                              // first choice up: all of it there
        XCTAssertEqual(ends(.values(["eastDown": true])), ["west", "north"])  // down: shared by the rest
        doc.flows![0].spread = nil
        XCTAssertEqual(ends(.values(["eastDown": true])), ["west"])           // without spread: all to the next
    }

    func testPacketsVanishInsideTheShapesTheyPass() throws {
        var (doc, client, api, east, _) = page()
        try DiagramOps.addFlow(&doc, from: client, to: [east], every: 0.05, speed: 100)
        let box = try XCTUnwrap(doc.elements.first { $0.id == api }).frame.insetBy(dx: 2, dy: 2)
        for t in stride(from: 0.0, through: 4, by: 0.1) {
            XCTAssertFalse(packets(doc.posed(at: t)).contains { box.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }, "at \(t)")
        }
    }

    func testOverridesChangeCostAndBadCostsLoad() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/edge/flows.dottie")
        let costPage = try DottieFile.decode(Data(contentsOf: url)).pages[2]
        let red = try XCTUnwrap(costPage.flows?.first)
        let direct = try XCTUnwrap(costPage.elements.first { $0.connector?.cost == 5 })
        func route(jam: Bool) throws -> [UUID] {
            let frame = costPage.posed(at: 1, state: .values(["jam": jam]))
            let offline = Set<UUID>()
            return try XCTUnwrap(DottieDocument.flowRoute(from: red.from, to: red.to, in: frame, offline: offline)).map(\.0)
        }
        XCTAssertNotEqual(try route(jam: false), [direct.id])
        XCTAssertEqual(try route(jam: true), [direct.id])   // hub → dst jammed at cost 10: the direct line (5) wins
        // cost "high" loaded as no cost.
        XCTAssertEqual(costPage.elements.filter { $0.kind == .connector }.count, 7)
        let json = #"{"start": {"x": 0, "y": 0}, "end": {"x": 1, "y": 1}, "routing": "straight", "startHead": "none", "endHead": "arrow", "cost": "x", "hops": 3}"#
        let c = try JSONDecoder().decode(ConnectorData.self, from: Data(json.utf8))
        XCTAssertNil(c.cost); XCTAssertNil(c.hops)
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
