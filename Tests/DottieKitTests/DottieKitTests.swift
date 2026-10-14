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
        XCTAssertEqual(dark.elements[2].style.stroke, .inkOnDark)       // unfilled: light ink
        XCTAssertEqual(dark.elements[0].style.stroke, .black)           // light yellow fill keeps dark ink
        XCTAssertEqual(dark.elements[1].style.stroke, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(dark.resolvingInk(to: .black).elements[2].style.stroke, .black)
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

    func testRoughLinePreservesEndsAndIsDeterministic() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 300, y: 40)
        func make(preserve: Bool, bowing: Double = 1) -> CGPath {
            var rng = SeededRNG(seed: 7)
            let p = CGMutablePath()
            Rough.line(a, b, rng: &rng, roughness: 2, bowing: bowing, preserveEnds: preserve, into: p)
            return p
        }
        XCTAssertEqual(make(preserve: true), make(preserve: true))
        var starts: [CGPoint] = [], ends: [CGPoint] = []
        make(preserve: true).applyWithBlock { el in
            let e = el.pointee
            if e.type == .moveToPoint { starts.append(e.points[0]) }
            if e.type == .addCurveToPoint { ends.append(e.points[2]) }
        }
        XCTAssertEqual(starts, [a, a])
        XCTAssertEqual(ends, [b, b])
        XCTAssertNotEqual(make(preserve: false), make(preserve: true))
        XCTAssertNotEqual(make(preserve: true, bowing: 0), make(preserve: true, bowing: 1))
    }

    func testStrokeFitIsDeterministicAndCompact() {
        // A noisy-free arc sampled densely, like a mouse drag.
        let raw = (0...2000).map { i -> CGPoint in
            let t = Double(i) / 2000 * .pi
            return CGPoint(x: 100 + 80 * cos(t), y: 100 + 80 * sin(t))
        }
        let a = StrokeFit.fit(raw), b = StrokeFit.fit(raw)
        XCTAssertEqual(a, b)
        XCTAssertEqual((a.count - 1) % 3, 0)
        XCTAssertLessThan(a.count, 40)
        XCTAssertEqual(a.first, raw.first)
        XCTAssertEqual(a.last, raw.last)
        // Every sample stays within tolerance of the fitted chain.
        var chain: [CGPoint] = []
        for s in 0..<((a.count - 1) / 3) {
            let seg = Array(a[(3 * s)...(3 * s + 3)])
            chain += (0...200).map { StrokeFit.point(seg, Double($0) / 200) }
        }
        for p in raw {
            let d = chain.map { hypot($0.x - p.x, $0.y - p.y) }.min()!
            XCTAssertLessThan(d, StrokeFit.tolerance + 0.25)
        }
    }

    func testCommittedStrokeStoresFlatPathAndRoundTrips() throws {
        var doc = DottieDocument()
        let raw = (0...400).map { i -> StrokePoint in
            let t = Double(i) / 400
            return StrokePoint(x: t, y: 0.5 + 0.4 * sin(t * 6))
        }
        var e = Element(kind: .freehand, frame: CGRect(x: 10, y: 10, width: 300, height: 100),
                        layerID: doc.layers[0].id, points: raw)
        e.fitStroke()
        XCTAssertNil(e.points)
        let flat = try XCTUnwrap(e.path)
        XCTAssertEqual((flat.count - 2) % 6, 0)
        XCTAssertLessThan(flat.count, 100)
        doc.elements = [e]
        let round = try DottieDocument.decode(doc.encoded())
        XCTAssertEqual(round.elements[0].path, flat)
        XCTAssertEqual(try doc.encoded(), try round.encoded())
        let box = Renderer.outline(for: round.elements[0]).boundingBoxOfPath
        XCTAssertEqual(box.minX, 10, accuracy: 1)
        XCTAssertEqual(box.maxX, 310, accuracy: 1)
    }

    func testLightInkKeepsDarkInkOnLightFills() {
        var doc = DottieDocument()
        let l = doc.layers[0].id
        var pastel = Style(); pastel.fill = RGBA(r: 1, g: 0.84, b: 0.65)
        var darkFill = Style(); darkFill.fill = RGBA(r: 0.1, g: 0.1, b: 0.3)
        var faint = Style(); faint.fill = RGBA(r: 1, g: 1, b: 1, a: 0.2)
        doc.elements = [
            Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), style: pastel, layerID: l),
            Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), style: darkFill, layerID: l),
            Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), style: faint, layerID: l),
            Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), layerID: l),
        ]
        let shown = doc.resolvingInk(to: .inkOnDark).elements.map(\.style.stroke)
        XCTAssertEqual(shown, [.black, .inkOnDark, .inkOnDark, .inkOnDark])
        // Exporting always resolves to black, whatever the fill.
        XCTAssertTrue(doc.resolvingInk(to: .black).elements.allSatisfy { $0.style.stroke == .black })
    }

    func testLiveKeyAddressesCurrentWindowAndNormalizesPaths() {
        XCTAssertEqual(LiveSocket.key(forPath: "current"), "@current")
        XCTAssertEqual(LiveSocket.key(forPath: "@current"), "@current")
        XCTAssertEqual(LiveSocket.key(forPath: "/tmp/a/../b.dottie"), "/private/tmp/b.dottie")
        XCTAssertEqual(LiveSocket.key(forPath: "/private/tmp/b.dottie"), "/private/tmp/b.dottie")
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

final class PhaseOneTests: XCTestCase {
    func testHachureLinesStayInsideThePolygon() {
        let poly = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 60), CGPoint(x: 0, y: 60)]
        let lines = Hachure.lines(in: poly, gap: 8)
        XCTAssertGreaterThan(lines.count, 8)
        for (a, b) in lines {
            for p in [a, b] {
                XCTAssertGreaterThanOrEqual(p.x, -0.01); XCTAssertLessThanOrEqual(p.x, 100.01)
                XCTAssertGreaterThanOrEqual(p.y, -0.01); XCTAssertLessThanOrEqual(p.y, 60.01)
            }
        }
        // Concave shapes get one segment per crossing pair, not one chord across the notch.
        let u = [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0), CGPoint(x: 90, y: 90), CGPoint(x: 60, y: 90),
                 CGPoint(x: 60, y: 30), CGPoint(x: 30, y: 30), CGPoint(x: 30, y: 90), CGPoint(x: 0, y: 90)]
        XCTAssertGreaterThan(Hachure.lines(in: u, angle: 0, gap: 10).count, Hachure.lines(in: poly, angle: 0, gap: 10).count / 2)
    }

    func testFillStylesAndDashesRenderAndExport() throws {
        var doc = DottieDocument()
        var st = Style(); st.fill = RGBA(r: 0.9, g: 0.5, b: 0.2); st.fillStyle = .crossHatch; st.dash = .dashed
        let a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 120, height: 80), style: st, layerID: doc.layers[0].id)
        doc.elements = [a]
        XCTAssertFalse(Renderer.hachurePath(for: a).isEmpty)
        XCTAssertTrue(Exporter.svg(doc).contains("stroke-dasharray"))
        XCTAssertNotNil(Exporter.png(doc))
        // Same seed, same hatch.
        XCTAssertEqual(Renderer.hachurePath(for: a), Renderer.hachurePath(for: a))
        XCTAssertTrue(Renderer.hachurePath(for: { var s = a; s.style.fillStyle = .solid; return s }()).isEmpty)
    }

    func testArrowheadsAndConnectorLabels() throws {
        var doc = DottieDocument()
        let a = try DiagramOps.addShape(&doc, kind: .rectangle, frame: nil, at: .zero, text: "A", fill: nil, stroke: nil, roughness: 0)
        let b = try DiagramOps.addShape(&doc, kind: .rectangle, frame: nil, at: CGPoint(x: 300, y: 0), text: "B", fill: nil, stroke: nil, roughness: 0)
        var c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id, roughness: 0)
        let i = doc.elements.firstIndex { $0.id == c.id }!
        doc.elements[i].connector?.endHead = .triangle
        doc.elements[i].connector?.startHead = .dot
        doc.elements[i].text = "yes"
        c = doc.elements[i]
        let parts = Renderer.connectorParts(for: c, in: doc)
        XCTAssertFalse(parts.filled.isEmpty)
        let mid = Renderer.midpoint(of: c, in: doc)
        let ends = Connector.endpoints(of: c, in: doc)
        XCTAssertEqual(mid.x, (ends.0.x + ends.1.x) / 2, accuracy: 0.5)
        XCTAssertTrue(Renderer.labelRect(for: c, in: doc).contains(mid))
        XCTAssertTrue(Exporter.svg(doc).contains(">yes</tspan>"))
        // Round trip keeps the heads.
        let round = try DottieDocument.decode(doc.encoded())
        XCTAssertEqual(round.elements[i].connector?.endHead, .triangle)
        XCTAssertEqual(round.elements[i].connector?.startHead, .dot)
    }
}

final class LayerTests: XCTestCase {
    func testLayerOrderIsZOrderAndDeleteKeepsShapes() throws {
        var doc = DottieDocument()
        let bottom = doc.layers[0].id
        let top = doc.addLayer(name: "Top")
        func box(_ layer: UUID, x: Double) -> Element {
            Element(kind: .rectangle, frame: CGRect(x: x, y: 0, width: 50, height: 50), layerID: layer)
        }
        // Array order says the top-layer box is first, but its layer is in front.
        let a = box(top, x: 0), b = box(bottom, x: 0)
        doc.elements = [a, b]
        XCTAssertEqual(doc.orderedElements.map(\.id), [b.id, a.id])
        XCTAssertEqual(doc.element(at: CGPoint(x: 25, y: 25))?.id, a.id)

        doc.moveLayer(top, by: -1)
        XCTAssertEqual(doc.orderedElements.map(\.id), [a.id, b.id])

        doc.editLayer(bottom) { $0.locked = true }
        XCTAssertEqual(doc.element(at: CGPoint(x: 25, y: 25))?.id, a.id) // locked layers are not hit

        XCTAssertTrue(doc.removeLayer(top))
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertTrue(doc.elements.allSatisfy { $0.layerID == bottom })
        XCTAssertFalse(doc.removeLayer(bottom)) // never the last layer

        let other = doc.addLayer()
        doc.move([a.id], toLayer: other)
        XCTAssertEqual(doc.elements.first { $0.id == a.id }?.layerID, other)
    }
}

final class StrokeEditTests: XCTestCase {
    private func line(in doc: inout DottieDocument) -> Element {
        let raw = (0...100).map { StrokePoint(x: Double($0) / 100, y: 0.5) }
        var e = Element(kind: .freehand, frame: CGRect(x: 0, y: 0, width: 200, height: 20), layerID: doc.layers[0].id, points: raw)
        e.style.roughness = 0
        e.fitStroke()
        doc.elements = [e]
        return e
    }

    func testErasingTheMiddleSplitsAStrokeInTwo() throws {
        var doc = DottieDocument()
        let e = line(in: &doc)
        XCTAssertNotNil(e.strokeControlPoints)
        XCTAssertTrue(doc.erase(at: CGPoint(x: 100, y: 10), radius: 10))
        XCTAssertEqual(doc.elements.count, 2)
        let xs = doc.elements.map { $0.frame }
        XCTAssertLessThan(xs[0].maxX, 100)
        XCTAssertGreaterThan(xs[1].minX, 100)
        XCTAssertEqual(Set(doc.elements.map(\.id)).count, 2)
        XCTAssertFalse(doc.erase(at: CGPoint(x: 100, y: 10), radius: 10)) // nothing left under the cursor
    }

    func testErasingWholeStrokeAndShapes() {
        var doc = DottieDocument()
        _ = line(in: &doc)
        let l = doc.layers[0].id
        doc.elements.append(Element(kind: .rectangle, frame: CGRect(x: 300, y: 0, width: 40, height: 40), layerID: l))
        XCTAssertTrue(doc.erase(at: CGPoint(x: 320, y: 20), radius: 6))
        XCTAssertEqual(doc.elements.count, 1)
        // A tiny stroke inside the radius disappears entirely.
        XCTAssertTrue(doc.erase(at: CGPoint(x: 100, y: 10), radius: 150))
        XCTAssertTrue(doc.elements.isEmpty)
    }

    func testMovingAnAnchorCarriesItsHandlesAndRefitsTheFrame() throws {
        var doc = DottieDocument()
        var e = line(in: &doc)
        let before = try XCTUnwrap(e.strokeControlPoints)
        e.moveStrokeControlPoint(0, to: CGPoint(x: before[0].x, y: before[0].y - 50))
        let after = try XCTUnwrap(e.strokeControlPoints)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after[0].y, before[0].y - 50, accuracy: 0.01)
        XCTAssertEqual(after[1].y, before[1].y - 50, accuracy: 0.01) // the handle came along
        XCTAssertEqual(after[2], before[2])
        XCTAssertLessThanOrEqual(e.frame.minY, before[0].y - 50 + 0.5)
        XCTAssertNil(e.points)
    }
}

final class RotationAndSnapTests: XCTestCase {
    func testRotationMovesHitAreaPortsAndExportBounds() throws {
        var doc = DottieDocument()
        var e = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 20), layerID: doc.layers[0].id)
        doc.elements = [e]
        XCTAssertNotNil(doc.element(at: CGPoint(x: 95, y: 10)))
        e.rotation = .pi / 2
        doc.elements = [e]
        // A wide bar turned a quarter-turn is tall: the old right end is no longer under the cursor.
        XCTAssertNil(doc.element(at: CGPoint(x: 95, y: 10)))
        XCTAssertNotNil(doc.element(at: CGPoint(x: 50, y: 55)))
        let top = Connector.portPoint(e, .top)
        XCTAssertEqual(top.x, 50 + 10, accuracy: 0.01) // top edge midpoint swings to the right
        XCTAssertEqual(top.y, 10, accuracy: 0.01)
        let edge = Connector.edgePoint(e, toward: CGPoint(x: 50, y: 500))
        XCTAssertEqual(edge.x, 50, accuracy: 0.01)
        XCTAssertEqual(edge.y, 10 + 50, accuracy: 0.01)
        XCTAssertEqual(e.rotatedBounds.height, 100, accuracy: 0.01)
        XCTAssertTrue(Exporter.svg(doc).contains("rotate(90"))
        XCTAssertNotNil(Exporter.png(doc))
        let round = try DottieDocument.decode(doc.encoded())
        XCTAssertEqual(round.elements[0].rotation ?? 0, .pi / 2, accuracy: 1e-9)
    }

    func testResizeSnapsMovingEdgeAndMoveSnapsToEqualSpacing() {
        let other = CGRect(x: 200, y: 0, width: 50, height: 50)
        let r = Snap.resize(CGRect(x: 0, y: 0, width: 197, height: 50), hx: 1, hy: 0, others: [other], threshold: 6)
        XCTAssertEqual(r.dx, 3, accuracy: 0.001)
        XCTAssertFalse(r.guides.isEmpty)
        XCTAssertEqual(Snap.resize(CGRect(x: 0, y: 0, width: 100, height: 50), hx: 1, hy: 0, others: [other], threshold: 6).dx, 0)

        // A at x 0..50, B at 200..250; moving box 40 wide drifting near the middle snaps to equal 55pt gaps.
        let a = CGRect(x: 0, y: 0, width: 50, height: 40), b = CGRect(x: 205, y: 5, width: 50, height: 40)
        let moving = CGRect(x: 104, y: 100, width: 40, height: 40)
        let s = Snap.move(moving, others: [a, b], threshold: 6)
        // Different rows, so no cross-axis overlap and no spacing: nothing should be claimed.
        XCTAssertTrue(s.spacing.isEmpty)
        let inRow = CGRect(x: 104, y: 0, width: 40, height: 40)
        let t = Snap.move(inRow, others: [a, b], threshold: 6)
        XCTAssertFalse(t.spacing.isEmpty)
        let final = inRow.offsetBy(dx: t.dx, dy: 0)
        XCTAssertEqual(final.minX - a.maxX, b.minX - final.maxX, accuracy: 0.01)
    }
}

final class RotatedResizeTests: XCTestCase {
    func testResizingARotatedShapeKeepsTheOppositeCornerFixed() {
        let original = CGRect(x: 100, y: 100, width: 80, height: 40)
        let angle = Double.pi / 6
        var e = Element(kind: .rectangle, frame: original, layerID: UUID()); e.rotation = angle
        let anchorBefore = e.rotated(CGPoint(x: original.minX, y: original.minY)) // top-left, untouched
        // Drag the bottom-right handle 30 wider and 10 taller in the shape's own axes.
        let grown = CGRect(x: original.minX, y: original.minY, width: original.width + 30, height: original.height + 10)
        var moved = e
        moved.frame = Element.reanchored(grown, original: original, angle: angle, fx: 0, fy: 0)
        let anchorAfter = moved.rotated(CGPoint(x: moved.frame.minX, y: moved.frame.minY))
        XCTAssertEqual(anchorAfter.x, anchorBefore.x, accuracy: 0.001)
        XCTAssertEqual(anchorAfter.y, anchorBefore.y, accuracy: 0.001)
        XCTAssertEqual(moved.frame.width, 110, accuracy: 0.001)
    }
}

final class AgentOpsTests: XCTestCase {
    func testBuildCarriesEdgeLabelsAndLooksApply() throws {
        var doc = DottieDocument()
        let ids = try DiagramOps.build(&doc, nodes: [.init(key: "a", text: "A"), .init(key: "b", text: "B")],
                                       edges: [.init(from: "a", to: "b", label: "yes")], roughness: 0)
        let conn = try XCTUnwrap(doc.elements.first { $0.kind == .connector })
        XCTAssertEqual(conn.text, "yes")
        XCTAssertEqual(DiagramOps.summarize(doc).first { $0.kind == "connector" }?.text, "yes")

        try DiagramOps.update(&doc, id: ids["a"]!, look: .init(fillStyle: .hachure, dash: .dashed, strokeWidth: 4, rotation: 90))
        let a = try XCTUnwrap(doc.elements.first { $0.id == ids["a"] })
        XCTAssertEqual(a.style.fillStyle, .hachure)
        XCTAssertEqual(a.style.dash, .dashed)
        XCTAssertEqual(a.angle, .pi / 2, accuracy: 1e-9)
        try DiagramOps.update(&doc, id: conn.id, look: .init(startHead: .dot, endHead: .bar, rotation: 45))
        let c2 = try XCTUnwrap(doc.elements.first { $0.id == conn.id })
        XCTAssertEqual(c2.connector?.startHead, .dot)
        XCTAssertEqual(c2.connector?.endHead, .bar)
        XCTAssertNil(c2.rotation) // connectors ignore rotation
        XCTAssertEqual(DiagramOps.summarize(doc).first { $0.id == ids["a"]!.uuidString }?.rotation, 90)
    }

    func testAnnotationsMapIdsToPixelBoxesInThePNG() throws {
        var doc = DottieDocument()
        _ = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 50), at: .zero,
                                    text: "Start", fill: nil, stroke: nil, roughness: 0)
        let b = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 200, y: 100, width: 100, height: 50), at: .zero,
                                        text: "End", fill: nil, stroke: nil, roughness: 0)
        let notes = DiagramOps.annotations(doc, scale: 2)
        XCTAssertEqual(notes.count, 2)
        let end = try XCTUnwrap(notes.first { $0.id == b.id.uuidString })
        XCTAssertEqual(end.text, "End")
        // Export pads by 24 around the content, so the first shape starts at 24 * scale.
        XCTAssertEqual(try XCTUnwrap(notes.first { $0.text == "Start" }).x, 48, accuracy: 0.1)
        XCTAssertEqual(end.x, (200 + 24) * 2, accuracy: 0.1)
        XCTAssertEqual(end.width, 200, accuracy: 0.1)
    }
}

final class GroupRotationTests: XCTestCase {
    func testRotatingTwoShapesQuarterTurnOrbitsTheSharedCenter() throws {
        var doc = DottieDocument()
        let l = doc.layers[0].id
        let a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 20, height: 20), layerID: l)
        let b = Element(kind: .rectangle, frame: CGRect(x: 80, y: 0, width: 20, height: 20), layerID: l)
        var free = Element(kind: .connector, frame: .zero, layerID: l,
                           connector: ConnectorData(start: .free(CGPoint(x: 0, y: 0)), end: .bound(a.id)))
        free.seed = 3
        doc.elements = [a, b, free]
        let ids = Set(doc.elements.map(\.id))
        let box = doc.selectionBounds(ids)
        XCTAssertEqual(box, CGRect(x: 0, y: 0, width: 100, height: 20))
        let center = CGPoint(x: box.midX, y: box.midY) // (50, 10)

        doc.rotate(ids, by: .pi / 2, about: center)
        let ra = doc.elements[0], rb = doc.elements[1]
        XCTAssertEqual(ra.angle, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(rb.angle, .pi / 2, accuracy: 1e-9)
        // a's center (10,10) swings to (50, -30); b's (90,10) to (50, 50): the pair is now vertical.
        XCTAssertEqual(ra.frame.midX, 50, accuracy: 1e-6); XCTAssertEqual(ra.frame.midY, -30, accuracy: 1e-6)
        XCTAssertEqual(rb.frame.midX, 50, accuracy: 1e-6); XCTAssertEqual(rb.frame.midY, 50, accuracy: 1e-6)
        // The free connector end orbits with them; the bound end still follows shape a.
        let c = try XCTUnwrap(doc.elements[2].connector)
        XCTAssertEqual(c.start.x, 60, accuracy: 1e-6); XCTAssertEqual(c.start.y, -40, accuracy: 1e-6)
        XCTAssertEqual(c.end.elementID, a.id)

        // Four more quarter turns return everything to the start, and the angle normalises away.
        for _ in 0..<3 { doc.rotate(ids, by: .pi / 2, about: center) }
        XCTAssertNil(doc.elements[0].rotation)
        XCTAssertEqual(doc.elements[0].frame.midX, 10, accuracy: 1e-6)
        XCTAssertEqual(doc.elements[1].frame.midX, 90, accuracy: 1e-6)
    }
}
