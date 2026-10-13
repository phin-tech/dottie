import XCTest
import CoreGraphics
@testable import DottieKit

final class DottieKitTests: XCTestCase {
    func sampleDoc() -> DottieDocument {
        var doc = DottieDocument()
        let l = doc.layers[0].id
        var fill = Style(); fill.fill = RGBA(r: 1, g: 0.93, b: 0.6)
        doc.elements = [
            Element(kind: .rectangle, frame: CGRect(x: 40, y: 40, width: 160, height: 90), style: fill, seed: 1, layerID: l, text: "Hello"),
            Element(kind: .ellipse, frame: CGRect(x: 260, y: 50, width: 130, height: 80), seed: 2, layerID: l),
            Element(kind: .diamond, frame: CGRect(x: 120, y: 190, width: 140, height: 100), seed: 3, layerID: l),
            Element(kind: .text, frame: CGRect(x: 300, y: 220, width: 160, height: 30), seed: 4, layerID: l, text: "dottie"),
        ]
        return doc
    }

    func testResolvingInkOnlyTouchesAutomaticInk() {
        var doc = sampleDoc()
        var red = Style(); red.stroke = RGBA(r: 1, g: 0, b: 0)
        doc.elements[1].style = red
        let dark = doc.resolvingInk(to: .inkOnDark)
        XCTAssertEqual(dark.elements[0].style.stroke, .inkOnDark)
        XCTAssertEqual(dark.elements[1].style.stroke, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(dark.resolvingInk(to: .black).elements[0].style.stroke, .black)
        XCTAssertEqual(doc.elements[0].style.stroke, .black) // original untouched
    }

    private func twoBoxesAndArrow() -> (DottieDocument, a: UUID, b: UUID, c: UUID) {
        var doc = DottieDocument()
        let l = doc.layers[0].id
        let a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 50, height: 40), layerID: l)
        let b = Element(kind: .rectangle, frame: CGRect(x: 200, y: 100, width: 80, height: 40), layerID: l)
        let c = Element(kind: .connector, frame: .zero, layerID: l,
                        connector: ConnectorData(start: .bound(a.id), end: .bound(b.id)))
        doc.elements = [a, b, c]
        return (doc, a.id, b.id, c.id)
    }

    func testDuplicateRemapsConnectorBindingsAndOffsets() {
        var (doc, a, b, c) = twoBoxesAndArrow()
        let new = doc.duplicate([a, b, c], offset: CGPoint(x: 10, y: 20))
        XCTAssertEqual(new.count, 3)
        XCTAssertEqual(doc.elements.count, 6)
        let copies = doc.elements.filter { new.contains($0.id) }
        let copyConn = copies.first { $0.kind == .connector }!
        let copyShapeIDs = Set(copies.filter { $0.kind != .connector }.map(\.id))
        XCTAssertTrue(copyShapeIDs.contains(copyConn.connector!.start.elementID!))
        XCTAssertTrue(copyShapeIDs.contains(copyConn.connector!.end.elementID!))
        XCTAssertEqual(copies.first { $0.kind != .connector }!.x, 10)
        XCTAssertFalse(new.contains(c))
    }

    func testCopyingOnlyAConnectorFreezesItsEnds() throws {
        let (doc, _, _, c) = twoBoxesAndArrow()
        let data = try XCTUnwrap(doc.clipboardData(for: [c]))
        var target = DottieDocument()
        let ids = target.paste(data, offset: .zero)
        let conn = try XCTUnwrap(target.elements.first { ids.contains($0.id) }?.connector)
        XCTAssertNil(conn.start.elementID)
        XCTAssertNil(conn.end.elementID)
    }

    func testGroupSelectsTogetherAndSurvivesPasteAsNewGroup() {
        var (doc, a, b, _) = twoBoxesAndArrow()
        XCTAssertNotNil(doc.group([a, b]))
        XCTAssertEqual(doc.expandingGroups([a]), [a, b])
        let new = doc.duplicate([a, b])
        let groups = Set(doc.elements.filter { new.contains($0.id) }.compactMap(\.groupID))
        XCTAssertEqual(groups.count, 1)
        XCTAssertNotEqual(groups.first, doc.elements.first { $0.id == a }?.groupID)
        doc.ungroup([a])
        XCTAssertEqual(doc.expandingGroups([a]), [a])
    }

    func testAlignAndDistribute() {
        var doc = DottieDocument()
        let l = doc.layers[0].id
        let ids = (0..<3).map { _ in UUID() }
        doc.elements = [
            Element(id: ids[0], kind: .rectangle, frame: CGRect(x: 0, y: 5, width: 10, height: 10), layerID: l),
            Element(id: ids[1], kind: .rectangle, frame: CGRect(x: 20, y: 30, width: 10, height: 10), layerID: l),
            Element(id: ids[2], kind: .rectangle, frame: CGRect(x: 100, y: 50, width: 10, height: 10), layerID: l),
        ]
        doc.distribute(Set(ids), along: .horizontal)
        XCTAssertEqual(doc.elements.map(\.x), [0, 50, 100])
        doc.align(Set(ids), to: .top)
        XCTAssertEqual(doc.elements.map(\.y), [5, 5, 5])
    }

    func testReorderKeepsRelativeOrder() {
        var (doc, a, b, c) = twoBoxesAndArrow()
        doc.reorder([a], .toFront)
        XCTAssertEqual(doc.elements.map(\.id), [b, c, a])
        doc.reorder([a], .toBack)
        XCTAssertEqual(doc.elements.map(\.id), [a, b, c])
        doc.reorder([a], .forward)
        XCTAssertEqual(doc.elements.map(\.id), [b, a, c])
    }

    func testOldFilesWithoutNewFieldsStillDecode() throws {
        let json = """
        {"version":1,"layers":[{"id":"00000000-0000-0000-0000-000000000001","name":"L","visible":true,"locked":false}],
         "elements":[{"id":"00000000-0000-0000-0000-000000000002","kind":"rectangle","x":1,"y":2,"width":3,"height":4,
         "seed":7,"layerID":"00000000-0000-0000-0000-000000000001",
         "style":{"stroke":{"r":0.12,"g":0.12,"b":0.13,"a":1},"fill":{"r":0,"g":0,"b":0,"a":0},"strokeWidth":2,"roughness":1,"fontSize":18}}]}
        """
        let doc = try DottieDocument.decode(Data(json.utf8))
        XCTAssertNil(doc.elements[0].groupID)
        XCTAssertNil(doc.elements[0].points)
    }

    func testSnapMovesToAlignedEdgeWithinThreshold() {
        let other = CGRect(x: 100, y: 0, width: 50, height: 50)
        let r = Snap.move(CGRect(x: 103, y: 80, width: 50, height: 40), others: [other], threshold: 6)
        XCTAssertEqual(r.dx, -3)               // left edges line up at x = 100
        XCTAssertEqual(r.dy, 0)                // nothing near on y
        XCTAssertTrue(r.guides.contains { $0.axis == .vertical && $0.position == 100 })
        let far = Snap.move(CGRect(x: 300, y: 80, width: 50, height: 40), others: [other], threshold: 6)
        XCTAssertEqual(far.dx, 0)
    }

    func testSnapFallsBackToGrid() {
        let r = Snap.move(CGRect(x: 23, y: 37, width: 10, height: 10), others: [], threshold: 6, gridSize: 20)
        XCTAssertEqual(r.dx, -3)
        XCTAssertEqual(r.dy, 3)
    }

    func testSVGUsesRendererPathsAndExportsInkAsBlack() {
        var doc = sampleDoc()
        doc.elements[0].style.stroke = .inkOnDark
        let svg = Exporter.svg(doc)
        XCTAssertTrue(svg.hasPrefix("<svg"))
        XCTAssertTrue(svg.contains("stroke=\"#1f1f21\""))
        XCTAssertFalse(svg.contains("#ededf0"))
        XCTAssertTrue(svg.contains(">Hello</tspan>"))
        XCTAssertTrue(svg.contains("<path d=\"M"))
        XCTAssertFalse(Exporter.svg(doc, background: nil).contains("<rect"))
    }

    func testFreehandRendersThroughItsPoints() {
        var doc = DottieDocument()
        let pts = [StrokePoint(x: 0, y: 0), StrokePoint(x: 0.5, y: 1), StrokePoint(x: 1, y: 0)]
        doc.elements = [Element(kind: .freehand, frame: CGRect(x: 10, y: 10, width: 100, height: 50), layerID: doc.layers[0].id, points: pts)]
        let box = Renderer.outline(for: doc.elements[0]).boundingBoxOfPath
        XCTAssertEqual(box.minX, 10, accuracy: 0.5)
        XCTAssertEqual(box.maxX, 110, accuracy: 0.5)
        XCTAssertNotNil(Exporter.png(doc))
        let round = try? DottieDocument.decode(doc.encoded())
        XCTAssertEqual(round?.elements[0].points, pts)
    }

    func testJSONRoundTrip() throws {
        let doc = sampleDoc()
        let back = try DottieDocument.decode(try doc.encoded())
        XCTAssertEqual(doc, back)
    }

    func testJSONIsDeterministic() throws {
        let doc = sampleDoc()
        XCTAssertEqual(try doc.encoded(), try doc.encoded())
    }

    func testSameSeedSamePath() {
        let e = sampleDoc().elements[1]
        XCTAssertEqual(Renderer.outline(for: e), Renderer.outline(for: e))
    }

    func testDifferentSeedDifferentPath() {
        var a = sampleDoc().elements[0], b = a
        b.seed = 99
        XCTAssertNotEqual(Renderer.outline(for: a), Renderer.outline(for: b))
        a.style.roughness = 0
        XCTAssertEqual(Renderer.outline(for: a).boundingBox, a.frame)
    }

    func testHitTestRespectsZOrderAndLocks() {
        var doc = sampleDoc()
        XCTAssertEqual(doc.element(at: CGPoint(x: 50, y: 50))?.kind, .rectangle)
        doc.layers[0].locked = true
        XCTAssertNil(doc.element(at: CGPoint(x: 50, y: 50)))
    }

    func testCleanVersionIsExactGeometry() {
        let clean = sampleDoc().withRoughness(0)
        for e in clean.elements where e.kind != .text {
            XCTAssertEqual(Renderer.outline(for: e).boundingBox, e.frame)
        }
    }

    func testExportPNGAndPDF() throws {
        let doc = sampleDoc()
        let png = try XCTUnwrap(Exporter.png(doc))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertNotNil(Exporter.pdf(doc))
        if let dir = ProcessInfo.processInfo.environment["DOTTIE_OUT"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample.png"))
            let clean = try XCTUnwrap(Exporter.png(doc.withRoughness(0)))
            try clean.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample-clean.png"))
        }
    }

    // MARK: Connectors

    func connectorDoc(routing: Routing = .straight) -> (DottieDocument, UUID, UUID, UUID) {
        var doc = DottieDocument()
        let l = doc.layers[0].id
        let a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 100), seed: 1, layerID: l)
        let b = Element(kind: .ellipse, frame: CGRect(x: 300, y: 0, width: 100, height: 100), seed: 2, layerID: l)
        let c = Element(kind: .connector, frame: .zero, seed: 3, layerID: l,
                        connector: ConnectorData(start: .bound(a.id), end: .bound(b.id), routing: routing))
        doc.elements = [a, b, c]
        return (doc, a.id, b.id, c.id)
    }

    func testEdgePointOnRectEllipseDiamond() {
        let l = UUID()
        let r = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 100), layerID: l)
        let p = Connector.edgePoint(r, toward: CGPoint(x: 300, y: 50))
        XCTAssertEqual(p.x, 100, accuracy: 0.001); XCTAssertEqual(p.y, 50, accuracy: 0.001)
        let el = Element(kind: .ellipse, frame: CGRect(x: 0, y: 0, width: 200, height: 100), layerID: l)
        let q = Connector.edgePoint(el, toward: CGPoint(x: 0, y: 50))
        XCTAssertEqual(q.x, 0, accuracy: 0.001)
        let d = Element(kind: .diamond, frame: CGRect(x: 0, y: 0, width: 100, height: 100), layerID: l)
        let s = Connector.edgePoint(d, toward: CGPoint(x: 50, y: 400))
        XCTAssertEqual(s.y, 100, accuracy: 0.001)
    }

    func testConnectorFollowsMovedShape() {
        var (doc, _, bID, cID) = connectorDoc()
        let c = doc.elements.first { $0.id == cID }!
        let before = Connector.endpoints(of: c, in: doc).1
        let i = doc.elements.firstIndex { $0.id == bID }!
        doc.elements[i].y += 200
        let after = Connector.endpoints(of: c, in: doc).1
        XCTAssertNotEqual(before, after)
    }

    func testPortBinding() {
        let (doc, aID, _, _) = connectorDoc()
        let a = doc.elements.first { $0.id == aID }!
        XCTAssertEqual(Connector.port(near: CGPoint(x: 52, y: 3), of: a), .top)
        XCTAssertNil(Connector.port(near: CGPoint(x: 50, y: 50), of: a))
        var ep = Endpoint.bound(aID, port: .bottom)
        ep.x = 999
        var d2 = doc
        d2.elements[2].connector!.start = ep
        let (s, _) = Connector.endpoints(of: d2.elements[2], in: d2)
        XCTAssertEqual(s, CGPoint(x: 50, y: 100))
    }

    func testElbowRouteIsOrthogonal() {
        var (doc, _, bID, cID) = connectorDoc(routing: .elbow)
        let i = doc.elements.firstIndex { $0.id == bID }!
        doc.elements[i].y = 150
        guard case .polyline(let pts) = Connector.route(of: doc.elements.first { $0.id == cID }!, in: doc) else { return XCTFail() }
        XCTAssertEqual(pts.count, 4)
        for k in 0..<3 { XCTAssertTrue(pts[k].x == pts[k + 1].x || pts[k].y == pts[k + 1].y) }
    }

    func testDeletingShapeFreezesConnector() throws {
        var (doc, aID, bID, cID) = connectorDoc()
        let end = Connector.endpoints(of: doc.elements.first { $0.id == cID }!, in: doc).1
        doc.remove([bID])
        let c = try XCTUnwrap(doc.elements.first { $0.id == cID }?.connector)
        XCTAssertNil(c.end.elementID)
        XCTAssertEqual(c.end.x, end.x, accuracy: 0.001)
        XCTAssertEqual(c.start.elementID, aID)
    }

    func testConnectorRoundTripAndHit() throws {
        let (doc, _, _, cID) = connectorDoc()
        XCTAssertEqual(try DottieDocument.decode(try doc.encoded()), doc)
        XCTAssertEqual(doc.element(at: CGPoint(x: 200, y: 50))?.id, cID)
        XCTAssertNotNil(Exporter.png(doc))
    }
}

final class OpsTests: XCTestCase {
    func testHexColors() {
        XCTAssertEqual(RGBA(hex: "#ff0000"), RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(RGBA(hex: "0f0"), RGBA(r: 0, g: 1, b: 0))
        XCTAssertNil(RGBA(hex: "nope"))
    }

    func testBuildFlowchartIsLayeredAndConnected() throws {
        var doc = DottieDocument()
        let ids = try DiagramOps.build(&doc, nodes: [
            .init(key: "a", text: "Start", kind: .ellipse),
            .init(key: "b", text: "Check?", kind: .diamond),
            .init(key: "c", text: "Yes path"),
            .init(key: "d", text: "No path"),
            .init(key: "e", text: "End", kind: .ellipse),
        ], edges: [
            .init(from: "a", to: "b"), .init(from: "b", to: "c"), .init(from: "b", to: "d"),
            .init(from: "c", to: "e"), .init(from: "d", to: "e"),
        ])
        func el(_ k: String) -> Element { doc.elements.first { $0.id == ids[k]! }! }
        XCTAssertLessThan(el("a").frame.maxY, el("b").frame.minY)
        XCTAssertLessThan(el("b").frame.maxY, el("c").frame.minY)
        XCTAssertEqual(el("c").frame.minY, el("d").frame.minY, accuracy: 20) // same rank
        XCTAssertLessThan(el("c").frame.maxY, el("e").frame.minY)
        XCTAssertEqual(doc.elements.filter { $0.kind == .connector }.count, 5)
        // No node overlaps another.
        let shapes = doc.elements.filter { $0.kind != .connector }
        for (i, a) in shapes.enumerated() { for b in shapes[(i + 1)...] { XCTAssertFalse(a.frame.intersects(b.frame)) } }
    }

    func testBuildHandlesCyclesAndLeftToRight() throws {
        var doc = DottieDocument()
        let ids = try DiagramOps.build(&doc, nodes: [.init(key: "a", text: "A"), .init(key: "b", text: "B")],
                                       edges: [.init(from: "a", to: "b"), .init(from: "b", to: "a")], direction: .leftToRight)
        let a = doc.elements.first { $0.id == ids["a"]! }!, b = doc.elements.first { $0.id == ids["b"]! }!
        XCTAssertLessThan(a.frame.maxX, b.frame.minX)
    }

    func testBuildRejectsBadReferences() {
        var doc = DottieDocument()
        XCTAssertThrowsError(try DiagramOps.build(&doc, nodes: [.init(key: "a", text: "A")], edges: [.init(from: "a", to: "zzz")]))
        XCTAssertThrowsError(try DiagramOps.build(&doc, nodes: [.init(key: "a", text: "A"), .init(key: "a", text: "B")], edges: []))
    }

    func testBuildAppendsBelowExistingContent() throws {
        var doc = DottieDocument()
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 100), at: .zero,
                                text: nil, fill: nil, stroke: nil, roughness: nil)
        let ids = try DiagramOps.build(&doc, nodes: [.init(key: "n", text: "New")], edges: [])
        let n = doc.elements.first { $0.id == ids["n"]! }!
        XCTAssertGreaterThan(n.frame.minY, 100)
    }

    func testPrimitiveEdits() throws {
        var doc = DottieDocument()
        let a = try DiagramOps.addShape(&doc, kind: .rectangle, frame: nil, at: CGPoint(x: 10, y: 10), text: "A", fill: nil, stroke: nil, roughness: 0)
        let b = try DiagramOps.addShape(&doc, kind: .ellipse, frame: nil, at: CGPoint(x: 300, y: 10), text: "B", fill: RGBA(hex: "#ffeeaa"), stroke: nil, roughness: nil)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id, routing: .curved)
        XCTAssertEqual(doc.elements.first { $0.id == a.id }!.style.roughness, 0)
        try DiagramOps.update(&doc, id: a.id, text: .some("Renamed"), x: 50)
        XCTAssertEqual(doc.elements.first { $0.id == a.id }!.text, "Renamed")
        XCTAssertThrowsError(try DiagramOps.addConnector(&doc, from: a.id, to: c.id)) // connector-to-connector
        try DiagramOps.delete(&doc, id: b.id)
        XCTAssertNil(doc.elements.first { $0.id == c.id }!.connector!.end.elementID) // frozen
        XCTAssertThrowsError(try DiagramOps.delete(&doc, id: UUID()))
        XCTAssertEqual(DiagramOps.summarize(doc).count, 2)
    }

    func testElbowWithPortsLeavesAndArrivesVertically() throws {
        var doc = DottieDocument()
        let l = doc.layers[0].id
        let a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 100), seed: 1, layerID: l)
        let b = Element(kind: .rectangle, frame: CGRect(x: 40, y: 250, width: 100, height: 100), seed: 2, layerID: l)
        let c = Element(kind: .connector, frame: .zero, seed: 3, layerID: l, connector: ConnectorData(
            start: .bound(a.id, port: .bottom), end: .bound(b.id, port: .top), routing: .elbow))
        doc.elements = [a, b, c]
        guard case .polyline(let pts) = Connector.route(of: c, in: doc) else { return XCTFail() }
        XCTAssertEqual(pts.first!.x, pts[1].x, accuracy: 0.001)            // leaves straight down
        XCTAssertEqual(pts[pts.count - 2].x, pts.last!.x, accuracy: 0.001) // arrives straight down
    }
}
