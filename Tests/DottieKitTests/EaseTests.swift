import XCTest
@testable import DottieKit

final class EaseTests: XCTestCase {
    func testEveryEaseStartsAtZeroAndEndsAtOne() {
        for ease in Ease.allCases where ease != .hold {
            XCTAssertEqual(ease.apply(0), 0, accuracy: 1e-12, "\(ease)")
            XCTAssertEqual(ease.apply(1), 1, accuracy: 1e-12, "\(ease)")
        }
    }

    func testSpringyCurvesAtAFewPoints() {
        // Values worked out independently from the formulas (spring: a damped spring nudged to end on 1).
        XCTAssertEqual(Ease.bounce.apply(0.2), 0.3025, accuracy: 1e-9)
        XCTAssertEqual(Ease.bounce.apply(0.5), 0.765625, accuracy: 1e-9)
        XCTAssertEqual(Ease.bounce.apply(0.9), 0.988125, accuracy: 1e-9)
        XCTAssertEqual(Ease.elastic.apply(0.1), 1.25, accuracy: 1e-9)
        XCTAssertEqual(Ease.elastic.apply(0.5), 1 + pow(2, -5) * sin(4.25 * 2 * .pi / 3), accuracy: 1e-12)
        XCTAssertEqual(Ease.spring.apply(0.05), 0.12569, accuracy: 1e-4)
        XCTAssertGreaterThan(Ease.spring.apply(0.35), 1.13, "a spring overshoots")
        XCTAssertGreaterThan(Ease.elastic.apply(0.15), 1, "elastic overshoots")
        XCTAssertLessThanOrEqual((0...100).map { Ease.bounce.apply(Double($0) / 100) }.max()!, 1, "a bounce never passes the target")
    }

    func testUnknownEaseNamesPlayLinear() throws {
        let json = #"{"t": 0, "x": 4, "ease": "wobble"}"#
        let k = try JSONDecoder().decode(Keyframe.self, from: Data(json.utf8))
        XCTAssertEqual(k.ease, .linear)
        XCTAssertEqual(k.x, 4)
    }

    func testOvershootIsClampedWhereItCannotGo() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 60),
                                        at: .zero, text: nil, fill: nil, stroke: nil, roughness: 0)
        var tl = Timeline(duration: 1)
        tl.setKey(Keyframe(t: 0, width: 80, strokeWidth: 4, fill: RGBA(r: 0.1, g: 0.9, b: 0.5), ease: .elastic), for: e.id)
        tl.setKey(Keyframe(t: 1, width: 2, strokeWidth: 0.5, fill: RGBA(r: 0.9, g: 0.1, b: 0.5)), for: e.id)
        doc.timeline = tl
        for i in 0...100 {
            let r = doc.resolved(at: Double(i) / 100).elements[0]
            XCTAssertGreaterThanOrEqual(r.width, 0)
            XCTAssertGreaterThanOrEqual(r.style.strokeWidth, 0)
            for c in [r.style.fill.r, r.style.fill.g, r.style.fill.b] { XCTAssert((0...1).contains(c)) }
        }
        XCTAssertEqual(doc.resolved(at: 0.1).elements[0].width, 0, "elastic passes the target on its way, and the width stops at nothing")
    }

    func testDropInBouncesOntoItsRestingPlace() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 100, y: 200, width: 80, height: 40),
                                        at: .zero, text: nil, fill: nil, stroke: nil, roughness: 0)
        try doc.addTransition(.dropIn, to: e.id, at: 0)
        XCTAssertEqual(doc.timeline?.track(for: e.id)?.keys.count, 2)
        XCTAssertEqual(doc.resolved(at: 0.6).elements[0].frame, e.frame)
        let ys = (0...60).map { doc.resolved(at: Double($0) / 100).elements[0].y }
        XCTAssertLessThanOrEqual(ys.max()!, 200, "never falls through the floor")
        for touchdown in [1, 2, 2.5] {   // where the bounce's arcs meet the floor
            XCTAssertEqual(doc.resolved(at: 0.6 * touchdown / 2.75).elements[0].y, 200, accuracy: 1e-6, "touches down at \(touchdown)")
        }
    }
}
