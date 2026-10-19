import XCTest
import CoreGraphics
@testable import DottieKit

/// Bends dragged into connectors (`waypoints`) and hops where lines cross (`hops`).
final class WaypointTests: XCTestCase {
    var doc = DottieDocument()

    func box(_ r: CGRect) -> Element {
        var st = Style(); st.roughness = 0
        let e = Element(kind: .rectangle, frame: r, style: st, layerID: doc.layers[0].id)
        doc.elements.append(e)
        return e
    }

    @discardableResult
    func line(_ start: Endpoint, _ end: Endpoint, routing: Routing = .straight, waypoints: [CGPoint]? = nil, hops: Bool? = nil) -> Element {
        var st = Style(); st.roughness = 0
        var data = ConnectorData(start: start, end: end, routing: routing)
        data.waypoints = waypoints?.map(Waypoint.init)
        data.hops = hops
        let e = Element(kind: .connector, frame: .zero, style: st, layerID: doc.layers[0].id, connector: data)
        doc.elements.append(e)
        return e
    }

    func points(_ e: Element) -> [CGPoint] { Connector.route(of: doc.elements.first { $0.id == e.id }!, in: doc).points }

    // MARK: Routes

    func testAStraightLineRunsThroughItsBendsAndItsEndsAimAtThem() {
        let a = box(CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = box(CGRect(x: 400, y: 0, width: 100, height: 100))
        let c = line(.bound(a.id), .bound(b.id), waypoints: [CGPoint(x: 50, y: 300), CGPoint(x: 450, y: 300)])
        XCTAssertEqual(points(c), [CGPoint(x: 50, y: 100), CGPoint(x: 50, y: 300), CGPoint(x: 450, y: 300), CGPoint(x: 450, y: 100)])
    }

    func testACurvedLinePassesThroughEveryBend() {
        let c = line(.free(CGPoint(x: 0, y: 0)), .free(CGPoint(x: 300, y: 0)), routing: .curved,
                     waypoints: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: -50)])
        guard case .curve(let p) = Connector.route(of: c, in: doc) else { return XCTFail() }
        XCTAssertEqual(p.count, 10) // three segments
        XCTAssertEqual(p[3], CGPoint(x: 100, y: 100))
        XCTAssertEqual(p[6], CGPoint(x: 200, y: -50))
        XCTAssertEqual(p[9], CGPoint(x: 300, y: 0))
        let sampled = Connector.route(of: c, in: doc).points
        XCTAssertEqual(sampled.count, 3 * 24 + 1) // each joint sampled once
    }

    func testACurveWithoutBendsIsTheOneCubicItAlwaysWas() {
        let c = line(.free(CGPoint(x: 0, y: 0)), .free(CGPoint(x: 200, y: 100)), routing: .curved)
        guard case .curve(let p) = Connector.route(of: c, in: doc) else { return XCTFail() }
        XCTAssertEqual(p, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)])
        XCTAssertEqual(Connector.route(of: c, in: doc).points.count, 25)
    }

    func testAnElbowThroughBendsStaysOrthogonalAndArrivesAlongAPinnedPort() {
        let a = box(CGRect(x: 0, y: 0, width: 100, height: 60))
        let b = box(CGRect(x: 400, y: 300, width: 100, height: 60))
        let c = line(.bound(a.id, port: .right), .bound(b.id, port: .top), routing: .elbow,
                     waypoints: [CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 150)])
        let p = points(c)
        for k in 0..<(p.count - 1) { XCTAssertTrue(p[k].x == p[k + 1].x || p[k].y == p[k + 1].y, "\(p)") }
        XCTAssertTrue(p.contains(CGPoint(x: 200, y: 200)))
        XCTAssertTrue(p.contains(CGPoint(x: 300, y: 150)))
        XCTAssertEqual(p[p.count - 2].x, 450) // the last leg comes straight down into the top port
        XCTAssertEqual(p.last, CGPoint(x: 450, y: 300))
    }

    func testBendsThatFallIntoLineDisappearFromAnElbow() {
        let c = line(.free(CGPoint(x: 0, y: 0)), .free(CGPoint(x: 100, y: 100)), routing: .elbow,
                     waypoints: [CGPoint(x: 20, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 0)])
        XCTAssertEqual(points(c), [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100), CGPoint(x: 100, y: 100)])
    }

    // MARK: Saving

    func testBendsAndHopsSurviveSavingAndOldFilesHaveNeither() throws {
        let c = line(.free(.zero), .free(CGPoint(x: 10, y: 0)), waypoints: [CGPoint(x: 5, y: 5)], hops: true)
        let back = try JSONDecoder().decode(Element.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.connector?.waypoints, [Waypoint(x: 5, y: 5)])
        XCTAssertEqual(back.connector?.hops, true)
        let plain = line(.free(.zero), .free(CGPoint(x: 10, y: 0)))
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("waypoints"))
        XCTAssertFalse(json.contains("hops"))
    }

    // MARK: Editing

    func testDraggingTheHalfwayHandleAddsABendInOrder() throws {
        let c = line(.free(CGPoint(x: 0, y: 0)), .free(CGPoint(x: 300, y: 0)), waypoints: [CGPoint(x: 100, y: 50)])
        let handles = Connector.bendHandles(of: c, in: doc)
        XCTAssertEqual(handles.map(\.handle), [.waypoint(0), .insert(0), .insert(1)])
        XCTAssertEqual(handles[2].at, CGPoint(x: 200, y: 25))
        XCTAssertEqual(Connector.bend(c, in: doc, handle: .insert(1), to: CGPoint(x: 200, y: 80)),
                       [Waypoint(x: 100, y: 50), Waypoint(x: 200, y: 80)])
        XCTAssertEqual(Connector.bend(c, in: doc, handle: .waypoint(0), to: CGPoint(x: 90, y: -40)), [Waypoint(x: 90, y: -40)])
    }

    func testDraggingAnElbowsEndSegmentAddsACornerSoTheEndStays() throws {
        // A straight run, end to end: dragging it down makes a U whose ends stay where they were.
        let c = line(.free(CGPoint(x: 0, y: 0)), .free(CGPoint(x: 300, y: 0)), routing: .elbow)
        XCTAssertEqual(Connector.bendHandles(of: c, in: doc).map(\.handle), [.segment(0)])
        var moved = c
        moved.connector?.waypoints = Connector.bend(c, in: doc, handle: .segment(0), to: CGPoint(x: 150, y: 80))
        doc.elements[doc.elements.count - 1] = moved
        XCTAssertEqual(points(moved), [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 80), CGPoint(x: 300, y: 80), CGPoint(x: 300, y: 0)])
    }

    func testMovingTurningAndPastingCarryTheBends() throws {
        let c = line(.free(CGPoint(x: 0, y: 0)), .free(CGPoint(x: 100, y: 0)), waypoints: [CGPoint(x: 50, y: 50)])
        doc.rotate([c.id], by: .pi, about: CGPoint(x: 50, y: 0))
        let turned = try XCTUnwrap(doc.elements.first { $0.id == c.id }?.connector?.waypoints?.first)
        XCTAssertEqual(turned.x, 50, accuracy: 1e-9)
        XCTAssertEqual(turned.y, -50, accuracy: 1e-9)
        let copies = doc.duplicate([c.id], offset: CGPoint(x: 16, y: 16))
        let copy = try XCTUnwrap(doc.elements.first { copies.contains($0.id) }?.connector?.waypoints?.first)
        XCTAssertEqual(copy.x, 66, accuracy: 1e-9)
        XCTAssertEqual(copy.y, -34, accuracy: 1e-9)
    }

    func testSwitchingBetweenElbowAndStraightDropsTheBends() {
        var data = ConnectorData(start: .free(.zero), end: .free(CGPoint(x: 10, y: 10)), routing: .straight)
        data.waypoints = [Waypoint(x: 5, y: 0)]
        data.setRouting(.curved)
        XCTAssertEqual(data.waypoints, [Waypoint(x: 5, y: 0)])
        data.setRouting(.elbow)
        XCTAssertNil(data.waypoints)
    }

    // MARK: Hops

    func testAHoppingLineHopsTheLinesBeneathItOnly() {
        let under = line(.free(CGPoint(x: 0, y: 100)), .free(CGPoint(x: 400, y: 100)))
        let hopper = line(.free(CGPoint(x: 100, y: 0)), .free(CGPoint(x: 100, y: 300)), hops: true)
        line(.free(CGPoint(x: 0, y: 200)), .free(CGPoint(x: 400, y: 200))) // drawn above: no hop
        let crossings = Renderer.hopCrossings(of: hopper, route: Connector.route(of: hopper, in: doc), in: doc, index: nil)
        XCTAssertEqual(crossings, [[100]])
        XCTAssertTrue(Renderer.hopCrossings(of: under, route: Connector.route(of: under, in: doc), in: doc, index: nil).allSatisfy(\.isEmpty))
    }

    func testHopsSkipHiddenLayersAndCrossingsTooNearABend() {
        line(.free(CGPoint(x: 0, y: 150)), .free(CGPoint(x: 400, y: 150))) // beneath, on a layer that gets hidden
        doc.layers[0].visible = false
        let top = doc.addLayer(name: "Top")
        var near = line(.free(CGPoint(x: 0, y: 297)), .free(CGPoint(x: 400, y: 297))) // 3 points from the bend below
        var hopper = line(.free(CGPoint(x: 100, y: 0)), .free(CGPoint(x: 300, y: 300)), waypoints: [CGPoint(x: 100, y: 300)], hops: true)
        near.layerID = top; hopper.layerID = top
        doc.elements[doc.elements.count - 2] = near
        doc.elements[doc.elements.count - 1] = hopper
        XCTAssertEqual(Renderer.hopCrossings(of: hopper, route: Connector.route(of: hopper, in: doc), in: doc, index: nil), [[], []])
        doc.layers[0].visible = true
        XCTAssertEqual(Renderer.hopCrossings(of: hopper, route: Connector.route(of: hopper, in: doc), in: doc, index: nil), [[150], []])
    }

    func testAHopAddsArcsToTheDrawnLine() {
        line(.free(CGPoint(x: 0, y: 100)), .free(CGPoint(x: 400, y: 100)))
        let plain = line(.free(CGPoint(x: 100, y: 0)), .free(CGPoint(x: 100, y: 300)))
        var hopping = plain
        hopping.connector?.hops = true
        doc.elements[doc.elements.count - 1] = hopping
        let box = Renderer.connectorParts(for: hopping, in: doc).line.boundingBoxOfPath
        XCTAssertLessThan(box.minX, 100 - Renderer.hopRadius(2) + 0.5) // the hop bulges out to the left
        XCTAssertEqual(box.minX, 100 - Renderer.hopRadius(2), accuracy: 1)
    }
}
