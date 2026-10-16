import XCTest
@testable import DottieKit

final class TimelineRowsTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, _ text: String?, x: Double = 0) throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: x, y: 0, width: 80, height: 40), at: .zero,
                                text: text, fill: nil, stroke: nil, roughness: 0)
    }

    func testOnlyAnimatedElementsGetRowsGroupedByLayer() throws {
        var doc = DottieDocument()
        let a = try box(&doc, "API")
        _ = try box(&doc, "Still", x: 200)
        doc.layers.append(Layer(name: "Notes"))
        let n = try box(&doc, nil, x: 400)
        doc.elements[doc.elements.count - 1].layerID = doc.layers[1].id
        try doc.addTransition(.popIn, to: a.id, at: 0)
        try doc.addTransition(.wiggle, to: n.id, at: 1)
        let rows = TimelineRows(doc)
        XCTAssertEqual(rows.groups.map(\.name), ["Layer 1", "Notes"])
        XCTAssertEqual(rows.groups[0].rows.map(\.label), ["API"])
        XCTAssertEqual(rows.groups[1].rows.map(\.label), ["Rectangle"])
        XCTAssertEqual(TimelineRows(DottieDocument()).groups, [])
    }

    func testMarksSpansAndHiddenStretches() throws {
        var doc = DottieDocument()
        let a = try box(&doc, "A")
        var tl = Timeline(duration: 4)
        tl.setKey(Keyframe(t: 1, x: 0, visible: true), for: a.id)
        tl.setKey(Keyframe(t: 2, x: 100, ease: .hold), for: a.id)
        tl.setKey(Keyframe(t: 3, x: 100, visible: false), for: a.id)
        doc.timeline = tl
        let row = try XCTUnwrap(TimelineRows(doc).groups.first?.rows.first)
        XCTAssertEqual(row.keys.map(\.t), [1, 2, 3])
        XCTAssertEqual(row.keys[0].sets, [.position, .visibility])
        XCTAssertEqual(row.keys[1].ease, .hold)
        XCTAssertEqual(row.spans, [
            .init(start: 0, end: 1, kind: .hidden), .init(start: 3, end: 4, kind: .hidden),
            .init(start: 1, end: 2, kind: .tween), .init(start: 2, end: 3, kind: .hold),
        ])
    }

    func testConnectorsAndPacketsAreLabelledByWhatTheyJoin() throws {
        var doc = DottieDocument()
        let a = try box(&doc, "Web"), b = try box(&doc, "DB", x: 300)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        try doc.addTransition(.drawIn, to: c.id, at: 0)
        let dot = try doc.addPacket(along: c.id, at: 1, duration: 0.5)
        let labels = Dictionary(uniqueKeysWithValues: TimelineRows(doc).groups[0].rows.map { ($0.element, $0) })
        XCTAssertEqual(labels[c.id]?.label, "Web → DB")
        XCTAssertEqual(labels[dot.id]?.label, "Packet · Web → DB")
        XCTAssertTrue(labels[dot.id]?.spans.contains(.init(start: 1, end: 1.5, kind: .follow(path: c.id))) ?? false)
    }
}
