import XCTest
@testable import DottieKit

final class MotionTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, x: Double, y: Double = 0, kind: ElementKind = .rectangle) throws -> Element {
        try DiagramOps.addShape(&doc, kind: kind, frame: CGRect(x: x, y: y, width: 80, height: 40), at: .zero,
                                text: nil, fill: nil, stroke: nil, roughness: 0)
    }
    private func element(_ doc: DottieDocument, _ id: UUID) -> Element? { doc.elements.first { $0.id == id } }

    func testPolylineFindsPointsByDistance() {
        let line = Polyline([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)])
        XCTAssertEqual(line.length, 200)
        XCTAssertEqual(line.point(at: 0.25), CGPoint(x: 50, y: 0))
        XCTAssertEqual(line.point(at: 0.75), CGPoint(x: 100, y: 50))
        XCTAssertEqual(line.point(at: 2), CGPoint(x: 100, y: 100))
    }

    func testFollowsAConnectorAndStaysAtTheEnd() throws {
        var doc = DottieDocument()
        let a = try box(&doc, x: 0), b = try box(&doc, x: 400)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        let dot = try box(&doc, x: 0, y: 300)
        try doc.addFollow(dot.id, along: c.id, at: 1, duration: 1, ease: .linear)
        let ends = Connector.endpoints(of: c, in: doc)
        XCTAssertEqual(element(doc.resolved(at: 0.5), dot.id)?.y, 300, "before the span it keeps its pose")
        let mid = try XCTUnwrap(element(doc.resolved(at: 1.5), dot.id))
        XCTAssertEqual(mid.frame.midX, (ends.0.x + ends.1.x) / 2, accuracy: 0.5)
        XCTAssertEqual(mid.frame.midY, ends.0.y, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(element(doc.resolved(at: 5), dot.id)).frame.midX, ends.1.x, accuracy: 0.5)
    }

    func testAKeyAfterTheSpanTakesTheElementBack() throws {
        var doc = DottieDocument()
        let a = try box(&doc, x: 0), b = try box(&doc, x: 400)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        let dot = try box(&doc, x: 0, y: 300)
        try doc.addFollow(dot.id, along: c.id, at: 0, duration: 1)
        doc.timeline!.setKey(Keyframe(t: 2, x: 10, y: 20), for: dot.id)
        XCTAssertEqual(element(doc.resolved(at: 2.5), dot.id)?.y, 20)
    }

    func testOrbitsAnOutlineAndFacesAlongIt() throws {
        var doc = DottieDocument()
        let ring = try DiagramOps.addShape(&doc, kind: .ellipse, frame: CGRect(x: 0, y: 0, width: 200, height: 200),
                                           at: .zero, text: nil, fill: nil, stroke: nil, roughness: 1)
        let moon = try box(&doc, x: 500)
        try doc.addFollow(moon.id, along: ring.id, at: 0, duration: 2, ease: .linear, orient: true, laps: 2)
        for t in [0.3, 0.9, 1.6] {
            let m = try XCTUnwrap(element(doc.resolved(at: t), moon.id))
            XCTAssertEqual(hypot(m.frame.midX - 100, m.frame.midY - 100), 100, accuracy: 2, "on the clean outline at \(t)")
            XCTAssertNotNil(m.rotation)
        }
        let once = try XCTUnwrap(element(doc.resolved(at: 0.25), moon.id)).frame.origin
        let twice = try XCTUnwrap(element(doc.resolved(at: 1.25), moon.id)).frame.origin
        XCTAssertEqual(once.x, twice.x, accuracy: 0.5, "the second lap repeats the first")
    }

    func testPacketShowsOnlyWhileTravelling() throws {
        var doc = DottieDocument()
        let a = try box(&doc, x: 0), b = try box(&doc, x: 400)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        let dot = try doc.addPacket(along: c.id, at: 1, duration: 0.5)
        XCTAssertNil(element(doc.resolved(at: 0.9), dot.id))
        XCTAssertNotNil(element(doc.resolved(at: 1.2), dot.id))
        XCTAssertNil(element(doc.resolved(at: 1.6), dot.id))
        XCTAssertThrowsError(try doc.addPacket(along: a.id, at: 0))
    }

    func testBuildRevealsInConnectorOrder() throws {
        var doc = DottieDocument()
        let a = try box(&doc, x: 0), b = try box(&doc, x: 200), c = try box(&doc, x: 400), lone = try box(&doc, x: 0, y: 200)
        _ = try DiagramOps.addConnector(&doc, from: b.id, to: c.id)
        _ = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        try doc.addBuild(.growIn, stagger: 1)
        func shown(_ t: Double) -> Set<UUID> { Set(doc.resolved(at: t).elements.filter { $0.kind != .connector }.map(\.id)) }
        XCTAssertEqual(shown(0.6), [a.id, lone.id])
        XCTAssertEqual(shown(1.6), [a.id, lone.id, b.id])
        XCTAssertEqual(shown(10), [a.id, b.id, c.id, lone.id])
    }

    func testBuildWithPacketsShowsTheArrowAheadOfItsTarget() throws {
        var doc = DottieDocument()
        let a = try box(&doc, x: 0), b = try box(&doc, x: 300)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        try doc.addBuild(.popIn, packets: true, packetDuration: 1)
        // a enters 0...0.4; the packet runs 0.4...1.4 along a visible arrow; b enters at 1.4.
        let during = doc.resolved(at: 0.9).elements.map(\.id)
        XCTAssertTrue(during.contains(c.id))
        XCTAssertFalse(during.contains(b.id))
        XCTAssertEqual(doc.resolved(at: 0.9).elements.count, 3, "a, the arrow and the packet")
        let early = doc.resolved(at: 0.9), late = doc.resolved(at: 3)
        let shown = try XCTUnwrap(early.elements.first { $0.id == c.id })
        XCTAssertEqual(Connector.endpoints(of: shown, in: early).1.x,
                       Connector.endpoints(of: c, in: late).1.x, accuracy: 0.5, "points where its hidden target will be")
        XCTAssertTrue(doc.resolved(at: 1.5).elements.map(\.id).contains(b.id))
    }

    func testBuildSurvivesCyclesAndRejectsEmptyPages() throws {
        var doc = DottieDocument()
        XCTAssertThrowsError(try doc.addBuild())
        let a = try box(&doc, x: 0), b = try box(&doc, x: 300)
        _ = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        _ = try DiagramOps.addConnector(&doc, from: b.id, to: a.id)
        try doc.addBuild(packets: true)
        XCTAssertEqual(doc.resolved(at: 20).elements.filter { $0.kind == .rectangle }.count, 2)
    }
}
