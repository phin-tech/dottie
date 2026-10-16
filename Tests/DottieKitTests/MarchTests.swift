import XCTest
@testable import DottieKit

final class MarchTests: XCTestCase {
    /// Two boxes and a dashed arrow between them, marching at `speed`, on a 2 s timeline at 10 fps.
    private func setup(speed: Double = 40) throws -> (DottieDocument, Element) {
        var doc = DottieDocument()
        let a = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 40),
                                        at: .zero, text: nil, fill: nil, stroke: nil, roughness: 1)
        let b = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 300, y: 0, width: 80, height: 40),
                                        at: .zero, text: nil, fill: nil, stroke: nil, roughness: 1)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        let i = doc.elements.firstIndex { $0.id == c.id }!
        doc.elements[i].style.dash = .dashed
        var tl = Timeline(fps: 10, duration: 2)
        tl.setMarch(speed, for: c.id)
        doc.timeline = tl
        return (doc, doc.elements[i])
    }

    private func dashOffset(in svg: String) -> String? {
        svg.range(of: #"stroke-dashoffset="[^"]*""#, options: .regularExpression).map { String(svg[$0]) }
    }

    func testConsecutiveFramesDifferOnlyInDashPhase() throws {
        let (doc, _) = try setup()
        let one = Exporter.svg(doc.resolved(at: 0.5)), two = Exporter.svg(doc.resolved(at: 0.6))
        XCTAssertNotEqual(one, two)
        XCTAssertNotNil(dashOffset(in: one))
        XCTAssertNotEqual(dashOffset(in: one), dashOffset(in: two))
        func strip(_ s: String) -> String { s.replacingOccurrences(of: #" stroke-dashoffset="[^"]*""#, with: "", options: .regularExpression) }
        XCTAssertEqual(strip(one), strip(two))
    }

    func testDashesTravelForwardAndLoopSeamlessly() throws {
        let (doc, c) = try setup(speed: 41)   // not a whole number of patterns over 2 s: evened out
        let period = Renderer.dashPattern(.dashed, width: c.style.strokeWidth)!.reduce(0, +)
        func offset(_ t: Double) -> Double { doc.resolved(at: t).elements.first { $0.id == c.id }!.style.dashOffset! }
        XCTAssertEqual(offset(0), 0)
        XCTAssertEqual(offset(2), 0, accuracy: 1e-9, "the end matches the start, so a loop doesn't jump")
        // Going forward, the phase falls (wrapping round within one pattern).
        let step = (offset(0.1) - offset(0.2) + period).truncatingRemainder(dividingBy: period)
        XCTAssertEqual(step, 4.2, accuracy: 1e-9, "41 pt/s evens out to 6 patterns of 14 pt over 2 s: 4.2 pt per frame")
        XCTAssertEqual(offset(0.1), 14 - 4.2, accuracy: 1e-9)
        let (backwards, bc) = try setup(speed: -41)
        XCTAssertEqual(backwards.resolved(at: 0.1).elements.first { $0.id == bc.id }?.style.dashOffset ?? 0, 4.2, accuracy: 1e-9)
    }

    func testSolidLinesAndStillsCarryNoPhase() throws {
        var (doc, c) = try setup()
        doc.elements[doc.elements.firstIndex { $0.id == c.id }!].style.dash = .solid
        XCTAssertNil(doc.resolved(at: 0.5).elements.first { $0.id == c.id }?.style.dashOffset)
        doc.timeline?.setMarch(nil, for: c.id)
        XCTAssertNil(doc.timeline?.track(for: c.id), "stopping the march drops the empty track")
    }

    func testScriptMarchMakesASolidLineDashed() throws {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const a = dottie.rect({x: 0, y: 0}), b = dottie.rect({x: 300, y: 0});
            const c = dottie.connect(a, b);
            dottie.timeline({duration: 2});
            dottie.march(c, {speed: 60});
            """, on: &doc, libraries: [.starter])
        XCTAssertNil(r.error)
        let c = doc.elements.first { $0.kind == .connector }!
        XCTAssertEqual(c.style.dash, .dashed)
        XCTAssertEqual(doc.timeline?.track(for: c.id)?.march, 60)
        XCTAssertNotNil(doc.resolved(at: 0.3).elements.first { $0.id == c.id }?.style.dashOffset)
    }

    func testMarchRoundTripsAndClamps() throws {
        let json = #"{"element": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "keys": [], "march": 1e12}"#
        let t = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        XCTAssertEqual(t.march, Track.maxMarch)
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(t)), t)
    }
}
