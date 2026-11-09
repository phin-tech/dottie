import XCTest
@testable import DottieKit

/// What makes interactive pages easier to put together (ADR 0003): queues, per-state flow volume, conditions on an
/// element's own metrics and alarms, capacity overrides that combine, and layout for gauges, controls and groups.
final class AuthoringTests: XCTestCase {
    /// api → sqs → worker → table.
    private func pipeline() -> (DottieDocument, api: UUID, sqs: UUID, worker: UUID, table: UUID) {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        func box(_ x: Double, _ t: String) -> Element {
            var e = Element(kind: .rectangle, frame: CGRect(x: x, y: 100, width: 80, height: 50), layerID: layer, text: t)
            e.anchor = t
            return e
        }
        let api = box(0, "api"), sqs = box(200, "sqs"), worker = box(400, "worker"), table = box(600, "table")
        func line(_ a: Element, _ b: Element) -> Element {
            Element(kind: .connector, frame: .zero, layerID: layer, connector: ConnectorData(start: .bound(a.id), end: .bound(b.id)))
        }
        doc.elements = [api, sqs, worker, table, line(api, sqs), line(sqs, worker), line(worker, table)]
        return (doc, api.id, sqs.id, worker.id, table.id)
    }
    private func set(_ doc: inout DottieDocument, _ id: UUID, _ change: (inout Element) -> Void) {
        change(&doc.elements[doc.elements.firstIndex { $0.id == id }!])
    }

    func testBacklogWaitsAtTheNearestQueue() throws {
        var (doc, api, sqs, worker, table) = pipeline()
        set(&doc, table) { $0.capacity = 2 }
        try DiagramOps.addFlow(&doc, from: api, to: [table], volume: 3)
        XCTAssertEqual(doc.metrics(at: 1).elements[worker]?.backlog, 1, "in front of the full table, without a queue")
        try DiagramOps.setQueue(&doc, id: sqs, true)
        let m = doc.metrics(at: 1)
        XCTAssertEqual(m.elements[sqs]?.backlog, 1, "at the queue")
        XCTAssertEqual(m.elements[worker]?.backlog, 0)
        XCTAssertEqual(m.elements[worker]?.throughput, 2, "past the queue, only what gets through")
        XCTAssertEqual(m.elements[api]?.throughput, 3, "up to the queue, all of it")
        XCTAssertThrowsError(try DiagramOps.setQueue(&doc, id: doc.elements[4].id, true))   // a connector
    }

    func testAFlowsVolumeFollowsItsOverrides() throws {
        var (doc, api, sqs, _, table) = pipeline()
        set(&doc, table) { $0.capacity = 4 }
        try DiagramOps.setQueue(&doc, id: sqs, true)
        let f = try DiagramOps.addFlow(&doc, from: api, to: [table], volume: 2,
                                      overrides: [FlowOverride(when: "spike", volume: 6), FlowOverride(when: "peak", volume: 9)])
        try doc.setVariable("spike", to: false); try doc.setVariable("peak", to: false)
        XCTAssertEqual(doc.metrics(at: 1).flows[f.id]?.volume, 2)
        XCTAssertEqual(doc.metrics(at: 1, state: .values(["spike": true])).elements[sqs]?.backlog, 2)
        XCTAssertEqual(doc.metrics(at: 1, state: .values(["spike": true, "peak": true])).flows[f.id]?.volume, 9, "the last that holds")
        XCTAssertThrowsError(try DiagramOps.addFlow(&doc, from: api, to: [table], overrides: [FlowOverride(when: "", volume: 1)]))
    }

    func testCapacityOverridesTakeTheTightestAndAlarmsUseTheirOwnLoad() throws {
        var (doc, api, _, worker, table) = pipeline()
        set(&doc, worker) { $0.capacity = 4 }
        try DiagramOps.addOverride(&doc, id: worker, { var o = StateOverride(when: "slow"); o.capacity = 1; return o }())
        try DiagramOps.addOverride(&doc, id: worker, { var o = StateOverride(when: "scale"); o.capacity = 10; return o }())
        try DiagramOps.addFlow(&doc, from: api, to: [table], volume: 3)
        try doc.setVariable("slow", to: false); try doc.setVariable("scale", to: false)
        func cap(_ v: [String: Var]) -> Double? { doc.posed(at: 1, state: .values(v)).elements.first { $0.id == worker }?.capacity }
        XCTAssertEqual(cap(["scale": true]), 10, "a scale-out alone raises it")
        XCTAssertEqual(cap(["scale": true, "slow": true]), 1, "together the tightest wins, whatever the order")
        // An alarm: red while its own load is at 1.
        let when = try DiagramOps.addAlarm(&doc, ids: [worker, table])
        XCTAssertEqual(when, "load >= 1")
        let red = RGBA(r: 0.86, g: 0.15, b: 0.15)
        XCTAssertNotEqual(doc.posed(at: 1).elements.first { $0.id == worker }?.style.stroke, red)
        XCTAssertEqual(doc.posed(at: 1, state: .values(["slow": true])).elements.first { $0.id == worker }?.style.stroke, red)
        XCTAssertEqual(PageState.metricTerm("load >= 0.9")?.target, "")
        XCTAssertNil(PageState.metricTerm("speed >= 1"))
        XCTAssertEqual(DiagramOps.stateWarnings(doc), [])
    }

    func testLayoutHelpers() throws {
        var (doc, api, sqs, worker, table) = pipeline()
        try DiagramOps.addFlow(&doc, from: api, to: [table])
        let size = CGSize(width: 100, height: 60)
        let right = try DiagramOps.gaugeFrame(doc, near: worker, side: "right", size: size)
        XCTAssertEqual(right, CGRect(x: 496, y: 95, width: 100, height: 60))
        try DiagramOps.addGauge(&doc, metric: "load", of: worker, frame: right)
        let next = try DiagramOps.gaugeFrame(doc, near: worker, side: "right", size: size)
        XCTAssertEqual(next.minY, 95 + 68, "clear of the gauge already there")
        XCTAssertEqual(try DiagramOps.gaugeFrame(doc, near: doc.flows![0].id, side: "above", size: size).minY, 100 - 16 - 60)
        XCTAssertThrowsError(try DiagramOps.gaugeFrame(doc, near: worker, side: "inside", size: size))
        XCTAssertEqual(try DiagramOps.controlOrigin(doc, after: sqs), CGPoint(x: 292, y: 100))
        XCTAssertEqual(try DiagramOps.controlOrigin(doc, after: nil).y, 95 - 60, "above the content, the gauge included")
        let g = try DiagramOps.addGroup(&doc, ids: [sqs, worker], label: "us-east-1")
        XCTAssertEqual(doc.elements.firstIndex { $0.id == g.frame.id }, 1, "behind the first member")
        XCTAssertTrue(g.frame.frame.contains(CGRect(x: 200, y: 100, width: 280, height: 50)))
        XCTAssertEqual(g.label.text, "us-east-1")
    }
}
