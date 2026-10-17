import XCTest
import CoreGraphics
@testable import DottieKit

final class FlowchartTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, _ kind: ElementKind = .rectangle, x: Double = 0, y: Double = 0) throws -> UUID {
        try DiagramOps.addShape(&doc, kind: kind, frame: CGRect(x: x, y: y, width: 120, height: 60), at: .zero,
                                text: "Start", fill: RGBA(r: 1, g: 0.9, b: 0.6), stroke: nil, roughness: 2).id
    }

    private func frame(_ id: UUID, _ doc: DottieDocument) -> CGRect { doc.elementIndex[id]!.frame }

    func testANodeCopiesItsSourceOneGapAwayJoinedByAnElbow() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        let (ids, _) = try Flowchart.addNodes(&doc, from: a, direction: .right, count: 1)
        XCTAssertEqual(ids.count, 1)
        let node = doc.elementIndex[ids[0]]!
        XCTAssertEqual(node.frame, CGRect(x: 220, y: 0, width: 120, height: 60))
        XCTAssertEqual(node.kind, .rectangle)
        XCTAssertEqual(node.style, doc.elementIndex[a]!.style)
        XCTAssertNil(node.text)
        let c = try XCTUnwrap(doc.elements.first { $0.kind == .connector }?.connector)
        XCTAssertEqual(c.start, .bound(a, port: .right))
        XCTAssertEqual(c.end, .bound(ids[0], port: .left))
        XCTAssertEqual(c.routing, .elbow)
        XCTAssertTrue(c.endArrow)
    }

    func testEachDirectionPlacesItsNode() throws {
        let expected: [Flowchart.Direction: CGPoint] = [.up: CGPoint(x: 0, y: -160), .down: CGPoint(x: 0, y: 160),
                                                        .left: CGPoint(x: -220, y: 0), .right: CGPoint(x: 220, y: 0)]
        for (direction, origin) in expected {
            var doc = DottieDocument()
            let a = try box(&doc)
            let (ids, _) = try Flowchart.addNodes(&doc, from: a, direction: direction, count: 1)
            XCTAssertEqual(frame(ids[0], doc).origin, origin, "\(direction)")
        }
    }

    func testSeveralNodesSitSideBySideCenteredOnTheSource() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        let (ids, _) = try Flowchart.addNodes(&doc, from: a, direction: .down, count: 3)
        let xs = ids.map { frame($0, doc).minX }
        XCTAssertEqual(xs, [-220, 0, 220])
        XCTAssertEqual(doc.elements.filter { $0.kind == .connector }.count, 3)
    }

    func testANewNodeStaysClearOfTheFlowchartsOtherNodes() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        let first = try Flowchart.addNodes(&doc, from: a, direction: .down, count: 1).nodes[0]
        let second = try Flowchart.addNodes(&doc, from: a, direction: .down, count: 1).nodes[0]
        let f1 = frame(first, doc), f2 = frame(second, doc)
        XCTAssertFalse(f1.intersects(f2))
        XCTAssertGreaterThanOrEqual(abs(f2.minX - f1.minX), 120 + Flowchart.gap)
        XCTAssertEqual(f2.minY, f1.minY)
    }

    func testAGrowingRowKeepsItsNodesInPlace() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var once = doc
        let (one, start) = try Flowchart.addNodes(&once, from: a, direction: .right, count: 1)
        var twice = doc
        let (two, _) = try Flowchart.addNodes(&twice, from: a, direction: .right, count: 2, crossStart: start)
        XCTAssertTrue(two.map { frame($0, twice).origin }.contains(frame(one[0], once).origin))
    }

    func testOnlyShapesOnUnlockedLayersGrow() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        let text = try DiagramOps.addShape(&doc, kind: .text, frame: nil, at: .zero, text: "hi", fill: nil, stroke: nil,
                                           roughness: nil).id
        XCTAssertThrowsError(try Flowchart.addNodes(&doc, from: text, direction: .down, count: 1))
        doc.layers[0].locked = true
        XCTAssertThrowsError(try Flowchart.addNodes(&doc, from: a, direction: .down, count: 1))
    }

    func testTabCyclesTheNodeKinds() {
        XCTAssertEqual(Flowchart.nextKind(after: .rectangle), .diamond)
        XCTAssertEqual(Flowchart.nextKind(after: .diamond), .ellipse)
        XCTAssertEqual(Flowchart.nextKind(after: .ellipse), .rectangle)
        XCTAssertNil(Flowchart.nextKind(after: .note))
    }

    func testNavigationFollowsConnectorsBothWaysAndStepsThroughSiblings() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        let kids = try Flowchart.addNodes(&doc, from: a, direction: .down, count: 2).nodes
        _ = try box(&doc, x: 0, y: 400) // below, but not joined
        var nav = Flowchart.Navigator()
        XCTAssertEqual(nav.step(from: a, toward: .down, in: doc), kids[0])
        XCTAssertEqual(nav.step(from: kids[0], toward: .down, in: doc), kids[1])
        XCTAssertEqual(nav.step(from: kids[1], toward: .down, in: doc), kids[0])
        XCTAssertEqual(nav.step(from: kids[0], toward: .up, in: doc), a) // against the arrow
        XCTAssertNil(nav.step(from: a, toward: .left, in: doc))
        XCTAssertEqual(Flowchart.neighbors(of: a, toward: .down, in: doc), kids)
    }
}
