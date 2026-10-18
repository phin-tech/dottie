import XCTest
@testable import DottieKit

/// Connectors and labels on `.path` shapes follow the outline, and extension ports and label rects are honored.
final class PathOutlineTests: XCTestCase {
    /// A closed contour through `corners` (normalized), each edge a straight cubic: control points one third and two
    /// thirds along it, so the curve is the straight edge.
    private func polygon(_ corners: [(Double, Double)]) -> PathSubpath {
        var coords = [corners[0].0, corners[0].1]
        for i in 0..<corners.count {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            coords += [a.0 + (b.0 - a.0) / 3, a.1 + (b.1 - a.1) / 3, a.0 + 2 * (b.0 - a.0) / 3, a.1 + 2 * (b.1 - a.1) / 3, b.0, b.1]
        }
        return PathSubpath(closed: true, coords: coords)
    }

    private func shape(_ corners: [(Double, Double)], frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> Element {
        var e = Element(kind: .path, frame: frame, layerID: UUID())
        e.subpaths = [polygon(corners)]
        return e
    }

    private func assertPoint(_ p: CGPoint, _ x: CGFloat, _ y: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 0.01, file: file, line: line)
    }

    func testSquareOutlineMatchesItsEdges() {
        let square = shape([(0, 0), (1, 0), (1, 1), (0, 1)])
        assertPoint(Connector.edgePoint(square, toward: CGPoint(x: 50, y: -100)), 50, 0)
        assertPoint(Connector.edgePoint(square, toward: CGPoint(x: 300, y: 50)), 100, 50)
    }

    /// The triangle's outline cuts inside its bounding box, so a ray toward the box's corner meets the slanted edge,
    /// not the box.
    func testEdgeFollowsTheSlantedOutlineNotTheBoundingBox() {
        let triangle = shape([(0.5, 0), (1, 1), (0, 1)])
        // Center (50, 50) toward the top-left corner of the box: the left edge runs from (50, 0) to (0, 100).
        assertPoint(Connector.edgePoint(triangle, toward: CGPoint(x: 0, y: 0)), 100.0 / 3, 100.0 / 3)
    }

    func testRayThatMissesTheOutlineFallsBackToTheBoundingBox() {
        // A shape whose contour is entirely to the left of its center: the ray to the right misses it.
        let sliver = shape([(0, 0), (0.1, 0), (0.1, 1), (0, 1)])
        assertPoint(Connector.edgePoint(sliver, toward: CGPoint(x: 300, y: 50)), 100, 50)
    }

    func testPortIndexPinsTheEndpoint() {
        var box = shape([(0, 0), (1, 0), (1, 1), (0, 1)])
        box.ports = [NormalizedPoint(x: 0.5, y: 0), NormalizedPoint(x: 1, y: 0.25)]
        let pinned = Connector.portPoint(box, index: 1)
        assertPoint(pinned ?? .zero, 100, 25)
        XCTAssertNil(Connector.portPoint(box, index: 5))

        var doc = DottieDocument()
        let layer = doc.layers[0].id
        var end = Element(kind: .connector, frame: .zero, layerID: layer)
        end.connector = ConnectorData(start: .free(CGPoint(x: 300, y: 300)), end: Endpoint(elementID: box.id, port: .left, portIndex: 0))
        doc.elements = [box, end]
        let (_, t) = Connector.endpoints(of: end, in: doc)
        assertPoint(t, 50, 0)
    }

    func testLabelRectPlacesTheText() {
        var e = shape([(0, 0), (1, 0), (1, 1), (0, 1)])
        XCTAssertEqual(e.labelFrame, CGRect(x: 6, y: 6, width: 88, height: 88))
        e.labelRect = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertEqual(e.labelFrame, CGRect(x: 25, y: 25, width: 50, height: 50))
    }
}
