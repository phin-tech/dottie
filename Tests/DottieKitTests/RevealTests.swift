import XCTest
@testable import DottieKit

final class RevealTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, x: Double = 0, text: String? = nil) throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: x, y: 0, width: 100, height: 50), at: .zero,
                                text: text, fill: RGBA(r: 1, g: 0.9, b: 0.5), stroke: nil, roughness: 0)
    }

    func testTrimmedKeepsTheLeadingFractionByLength() {
        let p = CGMutablePath()
        p.move(to: .zero); p.addLine(to: CGPoint(x: 100, y: 0)); p.addLine(to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(Polyline(p.trimmed(to: 0.75).contours[0]).length, 150, accuracy: 1e-9)
        XCTAssertEqual(p.trimmed(to: 0.75).currentPoint, CGPoint(x: 100, y: 50))
        XCTAssertTrue(p.trimmed(to: 0).isEmpty)
        let two = CGMutablePath()
        two.move(to: .zero); two.addLine(to: CGPoint(x: 10, y: 0))
        two.move(to: CGPoint(x: 0, y: 5)); two.addLine(to: CGPoint(x: 10, y: 5))
        XCTAssertEqual(two.trimmed(to: 0.5).contours.count, 1, "contours draw in order")
    }

    func testDrawInSketchesTheOutlineBeforeFillAndLabel() throws {
        var doc = DottieDocument()
        let a = try box(&doc, text: "Hello")
        try doc.addTransition(.drawIn, to: a.id, at: 0)
        XCTAssertTrue(doc.resolved(at: 0).elements.isEmpty == false)
        let half = Exporter.svg(doc.resolved(at: 0.4), background: nil)
        XCTAssertEqual(half.components(separatedBy: "<path").count - 1, 1, "only the partial outline")
        XCTAssertFalse(half.contains("Hello"))
        let done = doc.resolved(at: 0.8)
        XCTAssertNil(done.elements[0].reveal)
        XCTAssertTrue(Exporter.svg(done, background: nil).contains("Hello"))
    }

    func testTextTypesOut() throws {
        var doc = DottieDocument()
        let t = try DiagramOps.addShape(&doc, kind: .text, frame: CGRect(x: 0, y: 0, width: 200, height: 30), at: .zero,
                                        text: "abcdefghij", fill: nil, stroke: nil, roughness: 0)
        var tl = Timeline(duration: 1)
        tl.setKey(Keyframe(t: 0, reveal: 0, ease: .linear), for: t.id)
        tl.setKey(Keyframe(t: 1, reveal: 1), for: t.id)
        doc.timeline = tl
        let svg = Exporter.svg(doc.resolved(at: 0.35), background: nil)
        XCTAssertTrue(svg.contains(">abc<"), svg)
    }

    func testConnectorDrawsOnAndKeepsItsLabelBack() throws {
        var doc = DottieDocument()
        let a = try box(&doc), b = try box(&doc, x: 300)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id, label: "calls")
        try doc.addTransition(.drawIn, to: c.id, at: 1)
        XCTAssertFalse(doc.resolved(at: 0.5).elements.contains { $0.id == c.id }, "hidden before it starts")
        let mid = doc.resolved(at: 1.4)
        XCTAssertEqual(try XCTUnwrap(mid.elements.first { $0.id == c.id }?.reveal), 0.5, accuracy: 1e-9)
        XCTAssertFalse(Exporter.svg(mid, background: nil).contains("calls"))
        XCTAssertTrue(Exporter.svg(doc.resolved(at: 2), background: nil).contains("calls"))
        XCTAssertThrowsError(try doc.addTransition(.popIn, to: c.id, at: 0))
        XCTAssertNotNil(Exporter.png(mid), "the bitmap renderer handles a partial connector")
    }

    func testBuildCanDrawItsArrows() throws {
        var doc = DottieDocument()
        let a = try box(&doc), b = try box(&doc, x: 300)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        try doc.addBuild(.drawIn, drawArrows: true, travel: 1)
        // a draws on 0...0.8, the arrow 0.8...1.8, then b from 1.8.
        let mid = doc.resolved(at: 1.3)
        XCTAssertNotNil(mid.elements.first { $0.id == c.id }?.reveal)
        XCTAssertFalse(mid.elements.contains { $0.id == b.id })
        XCTAssertTrue(doc.resolved(at: 2).elements.contains { $0.id == b.id })
    }
}
