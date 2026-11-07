import XCTest
@testable import DottieKit

/// Volume, capacity, delay, metrics, conditions on metrics and gauges (ADR 0003), on a queue in front of workers.
final class MetricsTests: XCTestCase {
    /// api → queue → workers, and queue → spare.
    private func page() -> (DottieDocument, api: UUID, queue: UUID, workers: UUID, spare: UUID) {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        func box(_ x: Double, _ y: Double, _ t: String) -> Element {
            var e = Element(kind: .rectangle, frame: CGRect(x: x, y: y, width: 80, height: 50), layerID: layer, text: t)
            e.anchor = t
            return e
        }
        let api = box(0, 100, "api"), queue = box(200, 100, "queue"), workers = box(400, 0, "workers"), spare = box(400, 200, "spare")
        func line(_ a: Element, _ b: Element) -> Element {
            Element(kind: .connector, frame: .zero, layerID: layer, connector: ConnectorData(start: .bound(a.id), end: .bound(b.id)))
        }
        doc.elements = [api, queue, workers, spare, line(api, queue), line(queue, workers), line(queue, spare)]
        return (doc, api.id, queue.id, workers.id, spare.id)
    }

    private func set(_ doc: inout DottieDocument, _ id: UUID, _ change: (inout Element) -> Void) {
        change(&doc.elements[doc.elements.firstIndex { $0.id == id }!])
    }

    func testWhatDoesNotFitIsBacklogInFrontOfTheBottleneck() throws {
        var (doc, api, queue, workers, _) = page()
        set(&doc, workers) { $0.capacity = 2 }
        let flow = try DiagramOps.addFlow(&doc, from: api, to: [workers], volume: 3)
        let m = doc.metrics(at: 1)
        XCTAssertEqual(m.flows[flow.id]?.placed, 2)
        XCTAssertEqual(m.flows[flow.id]?.backlog, 1)
        XCTAssertEqual(m.elements[queue]?.backlog, 1, "it waits in the queue, in front of the full workers")
        XCTAssertEqual(m.elements[workers]?.load, 1)
        XCTAssertEqual(m.elements[api]?.throughput, 3)   // the 1 that waits still comes through the API to the queue
        // Backlog piles above the queue.
        let frame = doc.posed(at: 1)
        let piled = frame.elements.filter { $0.kind == .ellipse && $0.frame.maxY < 100 && $0.frame.minX >= 200 && $0.frame.maxX < 290 }
        XCTAssertEqual(piled.count, 1)   // a third of a packet every 0.5s, for 1s
        // It grows while the state holds, and depth counts what has piled up.
        let later = doc.posed(at: 1, state: .initial, since: 4).elements.filter { $0.kind == .ellipse && $0.frame.maxY < 100 && $0.frame.minX >= 200 && $0.frame.maxX < 290 }
        XCTAssertEqual(later.count, 3)
        XCTAssertEqual(try XCTUnwrap(doc.metrics(at: 1, since: 4).elements[queue]?.depth), 4, accuracy: 1e-9)
    }

    func testAQueueDrainsAtTheRoomLeftOnceTheSpikeEnds() throws {
        var (doc, api, queue, workers, _) = page()
        set(&doc, workers) { $0.capacity = 2 }
        try DiagramOps.addFlow(&doc, from: api, to: [workers], volume: 1)
        let spike = try DiagramOps.addFlow(&doc, from: api, to: [workers], when: "spike", volume: 2)
        try doc.setVariable("spike", to: false)
        // In the spike, 1 a second more than the workers take piles up in the queue: 4 after 4s.
        let during = doc.metrics(at: 1, state: .values(["spike": true]), since: 4)
        XCTAssertEqual(try XCTUnwrap(during.carry[DottieDocument.queueKey(shape: queue, flow: spike.id)]), 4, accuracy: 1e-9)
        // After it, the workers have 1 a second of room, so the queue drains at 1 a second, keeping them busy.
        let after = doc.metrics(at: 1, state: .values(["spike": false]), since: 2, carried: during.carry)
        XCTAssertEqual(try XCTUnwrap(after.elements[queue]?.depth), 2, accuracy: 1e-9)
        XCTAssertEqual(after.elements[workers]?.load, 1)
        let empty = doc.metrics(at: 1, state: .values(["spike": false]), since: 5, carried: during.carry)
        XCTAssertEqual(empty.elements[queue]?.depth, 0)
        XCTAssertEqual(empty.elements[workers]?.load, 0.5)
        // The drained messages leave as packets of the spike's flow, though it no longer runs.
        let prefix = String(spike.id.uuidString.prefix(24))
        let drained = doc.posed(at: 1, state: .values(["spike": false]), since: 2, carried: during.carry).elements
            .filter { $0.id.uuidString.hasPrefix(prefix) }
        XCTAssertGreaterThan(drained.count, 2)
        // A simulation carries the queue across the click itself.
        var sim = try Simulation(doc)
        _ = try? sim.click(workers.uuidString)   // no click there: nothing changes
        XCTAssertTrue(sim.carried.isEmpty)
    }

    func testAQueueDrainsThroughTheOverflowToo() throws {
        var (doc, api, queue, workers, spare) = page()
        set(&doc, workers) { $0.capacity = 2 }
        set(&doc, spare) { $0.capacity = 3 }
        try DiagramOps.addFlow(&doc, from: api, to: [workers, spare], volume: 1)
        let spike = try DiagramOps.addFlow(&doc, from: api, to: [workers, spare], when: "spike", volume: 9)
        try doc.setVariable("spike", to: false)
        // After the spike, 8 queued drains at the workers' spare 1 plus the overflow's 3: 4 a second.
        let carried = [DottieDocument.queueKey(shape: queue, flow: spike.id): 8.0]
        let m = doc.metrics(at: 1, state: .initial, since: 1, carried: carried)
        XCTAssertEqual(try XCTUnwrap(m.elements[queue]?.depth), 4, accuracy: 1e-9)
        XCTAssertEqual(m.elements[workers]?.load, 1)
        XCTAssertEqual(m.elements[spare]?.load, 1)
        XCTAssertEqual(doc.metrics(at: 1, state: .initial, since: 2, carried: carried).elements[queue]?.depth, 0)
    }

    func testOverflowTakesTheNextRouteAndPageOrderIsPriority() throws {
        var (doc, api, _, workers, spare) = page()
        set(&doc, workers) { $0.capacity = 2 }
        let first = try DiagramOps.addFlow(&doc, from: api, to: [workers, spare], volume: 3)
        let second = try DiagramOps.addFlow(&doc, from: api, to: [workers], volume: 1)
        let m = doc.metrics(at: 1)
        XCTAssertEqual(m.elements[workers]?.throughput, 2)
        XCTAssertEqual(m.elements[spare]?.throughput, 1)
        XCTAssertEqual(try XCTUnwrap(m.flows[first.id]?.backup), 1.0 / 3, accuracy: 1e-12)
        // The first flow filled the workers, so the second waits.
        XCTAssertEqual(m.flows[second.id]?.backlog, 1)
    }

    func testDelayHoldsPacketsAndAddsToTransit() throws {
        var (doc, api, queue, workers, _) = page()
        try DiagramOps.addFlow(&doc, from: api, to: [workers], every: 0.5, speed: 100)
        let quick = try XCTUnwrap(doc.metrics(at: 1).flows.values.first?.transit)
        set(&doc, queue) { $0.delay = 2 }
        let slow = try XCTUnwrap(doc.metrics(at: 1).flows.values.first?.transit)
        XCTAssertEqual(slow - quick, 2, accuracy: 1e-9)
        XCTAssertEqual(doc.metrics(at: 1).elements[queue]?.delay, 2)
        // A delay of 2s with a packet every 0.5s: no packet is ever drawn inside the queue.
        let box = try XCTUnwrap(doc.elements.first { $0.id == queue }).frame.insetBy(dx: 2, dy: 2)
        for t in stride(from: 0.0, through: 4, by: 0.1) {
            XCTAssertFalse(doc.posed(at: t).elements.contains { $0.kind == .ellipse && box.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
        }
    }

    func testVolumeSetsHowManyPacketsAFlowDraws() throws {
        var (doc, api, _, workers, spare) = page()
        let small = try DiagramOps.addFlow(&doc, from: api, to: [workers], every: 0.4, volume: 1)
        let big = try DiagramOps.addFlow(&doc, from: api, to: [spare], every: 0.4, volume: 3)
        let frame = doc.posed(at: 2)
        func count(_ f: Flow) -> Int { frame.elements.filter { $0.id.uuidString.hasPrefix(f.id.uuidString.prefix(24)) }.count }
        XCTAssertGreaterThan(count(big), 2 * count(small))
    }

    func testConditionsCompareMetricsButOnlyChangeLooks() throws {
        var (doc, api, _, workers, _) = page()
        set(&doc, workers) { e in
            e.capacity = 2
            e.overrides = [StateOverride(when: "load(workers) >= 1", stroke: RGBA(r: 1, g: 0, b: 0), text: "busy"),
                           StateOverride(when: "load(workers) >= 1", offline: true)]
        }
        try DiagramOps.addFlow(&doc, from: api, to: [workers], volume: 1)
        XCTAssertEqual(doc.posed(at: 1).elements.first { $0.id == workers }?.text, "workers")
        doc.flows![0].volume = 2
        let frame = doc.posed(at: 1)
        XCTAssertEqual(frame.elements.first { $0.id == workers }?.text, "busy")
        // The offline override compares a metric, so it does nothing: traffic still reaches the workers.
        XCTAssertEqual(doc.metrics(at: 1).elements[workers]?.throughput, 2)
        // Grammar: comparisons parse, and a `when` may not use them.
        XCTAssertEqual(PageState.names(in: "down && load(x) > 0.5"), ["down"])
        XCTAssertNil(PageState.metricTerm("load(x) > abc"))
        XCTAssertNil(PageState.metricTerm("speed(x) > 1"))
        XCTAssertThrowsError(try PageState.checked("load(x) > 1"))
        XCTAssertEqual(try PageState.checked("load(x) > 1", metrics: true), "load(x) > 1")
        XCTAssertTrue(PageState.holds("backlog(q) > 0", in: [:]) == false)
    }

    func testGaugesEaseFromTheirReadingWhenTheStateChanges() throws {
        var (doc, api, _, workers, _) = page()
        set(&doc, workers) { $0.capacity = 4 }
        try DiagramOps.addFlow(&doc, from: api, to: [workers], volume: 1)
        try DiagramOps.addFlow(&doc, from: api, to: [workers], when: "spike", volume: 3)
        try doc.setVariable("spike", to: false)
        var g = Element(kind: .rectangle, frame: CGRect(x: 600, y: 0, width: 140, height: 80), layerID: doc.layers[0].id)
        g.gauge = Gauge(metric: "load", of: workers)
        doc.elements.append(g)
        func text(_ since: Double, _ carried: [String: Double]) -> String? {
            doc.posed(at: 1, state: .values(["spike": true]), since: since, carried: carried).elements.first { $0.id == g.id }?.text
        }
        // Before the click it read 25%; the spike makes it 100%, reached after a second, halfway after half a second.
        let before = doc.posedWithMetrics(at: 1, state: .initial, since: 3).metrics.carry
        XCTAssertEqual(before[DottieDocument.gaugeKey(g.id)], 0.25)
        XCTAssertEqual(text(0, before), "load workers\n25%")
        XCTAssertEqual(text(0.5, before), "load workers\n63%")
        XCTAssertEqual(text(1, before), "load workers\n100%")
        XCTAssertEqual(text(0.5, [:]), "load workers\n100%")   // nothing carried (an export): no easing
    }

    func testGaugesAreDrawnAsPlainElements() throws {
        var (doc, api, _, workers, _) = page()
        set(&doc, workers) { $0.capacity = 4 }
        try DiagramOps.addFlow(&doc, from: api, to: [workers], volume: 3)
        let layer = doc.layers[0].id
        for (i, style) in Gauge.Style.allCases.enumerated() {
            var g = Element(kind: .rectangle, frame: CGRect(x: 600, y: Double(i) * 100, width: 140, height: 80), layerID: layer)
            g.gauge = Gauge(metric: "load", of: workers, style: style)
            doc.elements.append(g)
        }
        let frame = doc.posed(at: 1)
        let backs = frame.elements.filter { $0.kind == .path && $0.text != nil }
        XCTAssertEqual(backs.count, 3)
        XCTAssertTrue(backs.allSatisfy { $0.text == "load workers\n75%" && $0.gauge == nil })
        XCTAssertEqual(backs[0].style.textColor, DottieDocument.gaugeAmber)   // 0.75: past the 0.7 warning
        XCTAssertEqual(frame.elements.filter { $0.kind == .path }.count, 3 + 2 + 3)   // number; bar track and fill; dial arc, value, needle
        XCTAssertEqual(DottieDocument.formatted("throughput", 12.345), "12.3")
        XCTAssertEqual(DottieDocument.formatted("transit", 0.125), "0.13s")
        XCTAssertEqual(DottieDocument.formatted("load", nil), "–")
        XCTAssertEqual(DottieDocument.number(-0.004, places: 2), "0")
    }
}
