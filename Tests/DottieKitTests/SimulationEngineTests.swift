import XCTest
@testable import DottieKit

/// dottie.js's simulation, run in JavaScriptCore (`SimulationEngine`), poses every frame exactly as Swift's
/// `flowFrame` does, over the worked examples and the flow fixtures, across times, states and carried queues.
final class SimulationEngineTests: XCTestCase {
    private func pages() throws -> [(String, DottieDocument)] {
        var out: [(String, DottieDocument)] = []
        for e in ScriptExamples.all {
            var doc = DottieDocument()
            XCTAssertNil(DottieScript.run(e.code, on: &doc, libraries: [.starter], timeLimit: 10).error, e.name)
            out.append((e.name, doc))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try JSONDecoder().decode(DottieFile.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/edge/flows.dottie")))
        for (i, p) in file.pages.enumerated() { out.append(("flows.dottie p\(i + 1)", p)) }
        return out
    }

    /// Every combination of the page's variables, up to 64.
    private func states(_ doc: DottieDocument) -> [StateChoice] {
        let names = (doc.variables ?? [:]).keys.sorted()
        let n = min(names.count, 6)
        return (0..<(1 << n)).map { bits in
            .values(Dictionary(uniqueKeysWithValues: names.prefix(n).enumerated().map { ($1, bits & (1 << $0) != 0) }))
        }
    }

    private func pose(_ doc: DottieDocument, js: Bool, _ t: Double, _ s: StateChoice, _ since: Double?,
                      _ carried: [String: Double]) -> (frame: DottieDocument, metrics: FrameMetrics) {
        DottieDocument.simulatesInJavaScript = js
        defer { DottieDocument.simulatesInJavaScript = false }
        return doc.posedWithMetrics(at: t, state: s, since: since, carried: carried)
    }

    func testTheJavaScriptSimulationPosesWhatSwiftDoes() throws {
        var frames = 0
        let before = SimulationEngine.shared.calls
        for (name, doc) in try pages() {
            for s in states(doc) {
                // What the queues held when the state last changed: the starting state, two seconds in.
                let carried = pose(doc, js: false, 2, .initial, nil, [:]).metrics.carry
                for t in stride(from: 0.0, through: 9, by: 0.37) {
                    for since in [nil, 0.25, 1.7] as [Double?] {
                        let a = pose(doc, js: false, t, s, since, carried), b = pose(doc, js: true, t, s, since, carried)
                        XCTAssertEqual(a.metrics, b.metrics, "\(name) \(s) t=\(t) since=\(String(describing: since))")
                        XCTAssertEqual(a.frame.elements, b.frame.elements, "\(name) \(s) t=\(t) since=\(String(describing: since))")
                        frames += 1
                    }
                }
            }
        }
        XCTAssertEqual(SimulationEngine.shared.calls - before, frames, "every frame went through JavaScript")
        XCTAssertNil(SimulationEngine.shared.failure)
        print("compared \(frames) frames")
    }

    func testTiming() throws {
        for (name, doc) in try pages() {
            let s = states(doc).last ?? .initial
            func time(_ js: Bool) -> Double {
                _ = pose(doc, js: js, 0, s, nil, [:])
                let start = Date()
                for i in 0..<120 { _ = pose(doc, js: js, Double(i) / 60, s, nil, [:]) }
                return Date().timeIntervalSince(start) / 120 * 1000
            }
            print(String(format: "%@: %d elements, swift %.3f ms/frame, js %.3f ms/frame", name, doc.elements.count, time(false), time(true)))
        }
    }
}
