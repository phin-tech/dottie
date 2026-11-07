import XCTest
@testable import DottieKit

/// dottie.js's simulation, run in JavaScriptCore (`SimulationEngine`, ADR 0004), poses every interactive page it is
/// given: the worked examples and the flow fixtures, across times, states and carried queues, with no failure.
/// What it works out is tested by the behaviour tests (FlowTests, MetricsTests, ControlsTests and others) and by
/// dottie.js's own tests.
final class SimulationEngineTests: XCTestCase {
    func testEveryExampleAndFixtureSimulates() throws {
        var pages: [DottieDocument] = []
        for e in ScriptExamples.all {
            var doc = DottieDocument()
            XCTAssertNil(DottieScript.run(e.code, on: &doc, libraries: [.starter], timeLimit: 10).error, e.name)
            pages.append(doc)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        pages += try JSONDecoder().decode(DottieFile.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/edge/flows.dottie"))).pages
        for doc in pages {
            let names = (doc.variables ?? [:]).keys.sorted().prefix(4)
            for bits in 0..<(1 << names.count) {
                let state = StateChoice.values(Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, bits & (1 << $0) != 0) }))
                let carried = doc.metrics(at: 2).carry
                for t in [0, 0.7, 3.1] {
                    let (frame, metrics) = doc.posedWithMetrics(at: t, state: state, since: 0.4, carried: carried)
                    XCTAssertNil(SimulationEngine.shared.failure, doc.name)
                    if doc.flows?.isEmpty == false { XCTAssertFalse(metrics.elements.isEmpty, doc.name) }
                    XCTAssertFalse(frame.elements.contains { $0.gauge != nil }, "every gauge is drawn as plain elements")
                }
            }
        }
    }

    func testTheEngineFollowsThePageAsItChanges() throws {
        // The page is sent again only when the posed page differs: moving a shape between frames still routes anew.
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        let a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 40, height: 40), layerID: layer)
        let b = Element(kind: .rectangle, frame: CGRect(x: 300, y: 0, width: 40, height: 40), layerID: layer)
        let c = Element(kind: .connector, frame: .zero, layerID: layer, connector: ConnectorData(start: .bound(a.id), end: .bound(b.id)))
        doc.elements = [a, b, c]
        doc.flows = [Flow(from: a.id, to: [b.id])]
        let before = doc.posed(at: 0.5).elements.filter { $0.kind == .ellipse }.map(\.frame.midY)
        doc.elements[1].frame.origin.y = 200
        let after = doc.posed(at: 0.5).elements.filter { $0.kind == .ellipse }.map(\.frame.midY)
        XCTAssertFalse(before.isEmpty)
        XCTAssertNotEqual(before, after)
    }
}
