import XCTest
@testable import DottieKit

final class PosingTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, _ text: String? = nil, x: Double = 0) throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: x, y: 0, width: 80, height: 40), at: .zero,
                                text: text, fill: nil, stroke: nil, roughness: 0)
    }
    private func at(_ doc: DottieDocument, _ t: Double, _ id: UUID) -> Element? {
        doc.resolved(at: t).elements.first { $0.id == id }
    }

    func testMovingAStillShapeKeysItFromWhereItWas() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        doc.startAnimation(duration: 2)
        var frame = doc.resolved(at: 1)
        frame.elements[0].x = 300
        let posed = doc.applyingPose(frame, at: 1)
        XCTAssertEqual(posed.elements[0].x, 0, "the page itself is untouched")
        XCTAssertEqual(at(posed, 0, a.id)?.x, 0)
        XCTAssertEqual(at(posed, 0.5, a.id)?.x ?? 0, 150, accuracy: 1e-9)
        XCTAssertEqual(at(posed, 1, a.id)?.x, 300)
        XCTAssertEqual(posed.timeline?.track(for: a.id)?.keys.map(\.t), [0, 1])
    }

    func testPosingAgainAddsToTheKeysThatAreThere() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var tl = Timeline(duration: 2)
        tl.setKey(Keyframe(t: 0, x: 0), for: a.id)
        tl.setKey(Keyframe(t: 2, x: 200), for: a.id)
        doc.timeline = tl
        var frame = doc.resolved(at: 1)
        frame.elements[0].y = 50
        frame.elements[0].style.fill = RGBA(r: 1, g: 0, b: 0)
        let posed = doc.applyingPose(frame, at: 1)
        XCTAssertEqual(at(posed, 2, a.id)?.x, 200, "x keys are left alone")
        XCTAssertEqual(at(posed, 1, a.id)?.y, 50)
        XCTAssertEqual(at(posed, 0, a.id)?.y, 0, "y is pinned at 0 the first time it is keyed")
        XCTAssertEqual(at(posed, 1, a.id)?.style.fill, RGBA(r: 1, g: 0, b: 0))
    }

    func testTextAndLookApplyToTheElementNotKeys() throws {
        var doc = DottieDocument()
        let a = try box(&doc, "old")
        doc.startAnimation()
        var frame = doc.resolved(at: 1)
        frame.elements[0].text = "new"
        frame.elements[0].style.dash = .dashed
        let posed = doc.applyingPose(frame, at: 1)
        XCTAssertEqual(posed.elements[0].text, "new")
        XCTAssertEqual(posed.elements[0].style.dash, .dashed)
        XCTAssertNil(posed.timeline?.track(for: a.id))
    }

    func testDrawnShapesAppearAndDeletedOnesHideFromThePlayhead() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        doc.startAnimation()
        var frame = doc.resolved(at: 1)
        frame.elements.removeAll()
        var drawn = frame
        let b = try box(&drawn, x: 200)
        let posed = doc.applyingPose(drawn, at: 1)
        XCTAssertEqual(doc.resolved(at: 0.5).elements.count, 1)
        XCTAssertEqual(posed.resolved(at: 0.5).elements.map(\.id), [a.id])
        XCTAssertEqual(posed.resolved(at: 1).elements.map(\.id), [b.id])
        XCTAssertEqual(posed.elements.count, 2, "both stay on the page")
        // At 0 a delete is a delete.
        var start = doc.resolved(at: 0)
        start.elements.removeAll()
        XCTAssertTrue(doc.applyingPose(start, at: 0).elements.isEmpty)
    }

    func testAnUnchangedFrameChangesNothing() throws {
        var doc = DottieDocument()
        let a = try box(&doc), b = try box(&doc, x: 300)
        _ = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        try doc.addTransition(.popIn, to: b.id, at: 0.5)
        doc.timeline?.boil = 2
        XCTAssertEqual(doc.applyingPose(doc.resolved(at: 0.7), at: 0.7), doc,
                       "boiled seeds, pinned arrows and mid-tween frames are not edits")
    }

    func testStaggeredTransitionsAndClearing() throws {
        var doc = DottieDocument()
        let a = try box(&doc), b = try box(&doc, x: 200)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        XCTAssertEqual(try doc.addTransition(.popIn, to: [a.id, c.id, b.id], at: 1, stagger: 0.5), 2, "popIn skips arrows")
        XCTAssertEqual(doc.timeline?.track(for: b.id)?.keys.first?.t, 1.5)
        XCTAssertEqual(try doc.addTransition(.drawIn, to: [c.id], at: 2), 1)
        doc.clearAnimation(of: [a.id, c.id])
        XCTAssertEqual(doc.timeline?.tracks.map(\.element), [b.id])
    }
}
