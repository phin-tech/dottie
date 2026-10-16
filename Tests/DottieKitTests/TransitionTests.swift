import XCTest
@testable import DottieKit

final class TransitionTests: XCTestCase {
    private func setup() throws -> (DottieDocument, Element) {
        var doc = DottieDocument()
        let e = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 80, height: 40),
                                        at: .zero, text: nil, fill: nil, stroke: nil, roughness: 0)
        return (doc, e)
    }

    func testPopInIsHiddenFirstOvershootsAndRests() throws {
        var (doc, e) = try setup()
        try doc.addTransition(.popIn, to: e.id, at: 1)
        XCTAssertEqual(doc.timeline?.duration ?? 0, 1.4, accuracy: 1e-9, "the timeline is made to fit")
        XCTAssertTrue(doc.resolved(at: 0.9).elements.isEmpty)
        let peak = doc.resolved(at: 1.24).elements[0]
        XCTAssertGreaterThan(peak.width, 80)
        XCTAssertEqual(peak.frame.midX, e.frame.midX, accuracy: 1e-6, "scales about its center")
        XCTAssertEqual(doc.resolved(at: 2).elements[0].frame, e.frame)
    }

    func testExitsHideTheElementAfterwards() throws {
        for tr in [Transition.popOut, .shrinkOut, .wipeOut] {
            var (doc, e) = try setup()
            try doc.addTransition(tr, to: e.id, at: 1)
            XCTAssertEqual(doc.resolved(at: 0.5).elements.first?.frame, e.frame, "\(tr)")
            XCTAssertTrue(doc.resolved(at: 1 + tr.defaultDuration).elements.isEmpty, "\(tr)")
        }
    }

    func testEveryEntranceEndsInTheRestingPose() throws {
        for tr in Transition.allCases where tr.isEntrance {
            var (doc, e) = try setup()
            try doc.addTransition(tr, to: e.id, at: 0.5)
            XCTAssertTrue(doc.resolved(at: 0.4).elements.isEmpty, "\(tr)")
            XCTAssertEqual(doc.resolved(at: 3).elements[0].frame, e.frame, "\(tr)")
        }
    }

    func testEmphasisReturnsToRest() throws {
        var (doc, e) = try setup()
        try doc.addTransition(.pulse, to: e.id, at: 0)
        try doc.addTransition(.wiggle, to: e.id, at: 1)
        XCTAssertGreaterThan(doc.resolved(at: 0.25).elements[0].width, 80)
        XCTAssertNotEqual(doc.resolved(at: 1.125).elements[0].angle, 0)
        let end = doc.resolved(at: 2).elements[0]
        XCTAssertEqual(end.frame, e.frame)
        XCTAssertEqual(end.angle, 0, accuracy: 1e-9)
    }

    func testEntranceRestsWhereEarlierKeysPutTheElement() throws {
        var (doc, e) = try setup()
        var tl = Timeline(duration: 2)
        tl.setKey(Keyframe(t: 0, x: 400), for: e.id)
        doc.timeline = tl
        try doc.addTransition(.growIn, to: e.id, at: 1)
        XCTAssertEqual(doc.resolved(at: 2).elements[0].x, 400)
    }

    func testConnectorsCannotTransition() throws {
        var (doc, a) = try setup()
        let b = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 300, y: 0, width: 80, height: 40),
                                        at: .zero, text: nil, fill: nil, stroke: nil, roughness: 0)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        XCTAssertThrowsError(try doc.addTransition(.popIn, to: c.id, at: 0))
    }
}
