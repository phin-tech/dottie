import XCTest
import CoreGraphics
@testable import DottieKit

final class DungeonGridTests: XCTestCase {
    private func floor(_ frame: CGRect, kind: ElementKind = .rectangle, cell: Double = 25, layer: UUID) -> Element {
        var s = Style()
        s.fill = RGBA(r: 0.93, g: 0.89, b: 0.82)
        s.fillStyle = .grid
        s.gridSize = cell
        return Element(kind: kind, frame: frame, style: s, layerID: layer)
    }

    private func rect(_ r: CGRect) -> [[CGPoint]] {
        [[CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]]
    }

    func testGridLinesSitOnThePageLatticeNotTheShape() {
        // Two rooms off the lattice by different amounts still rule lines at the same page coordinates.
        let a = DungeonGrid.lines(in: rect(CGRect(x: 3, y: 7, width: 100, height: 60)), cell: 25)
        let b = DungeonGrid.lines(in: rect(CGRect(x: 103, y: 7, width: 80, height: 60)), cell: 25)
        let horizontalYs = { (ls: [(CGPoint, CGPoint)]) in Set(ls.filter { $0.0.y == $0.1.y }.map(\.0.y)) }
        XCTAssertEqual(horizontalYs(a), [25, 50])
        XCTAssertEqual(horizontalYs(a), horizontalYs(b))
        let verticalXs = Set(a.filter { $0.0.x == $0.1.x }.map(\.0.x))
        XCTAssertEqual(verticalXs, [25, 50, 75, 100])
    }

    func testNoGridLineIsDrawnOnTheShapesOwnEdge() {
        let ls = DungeonGrid.lines(in: rect(CGRect(x: 0, y: 0, width: 75, height: 50)), cell: 25)
        XCTAssertEqual(ls.count, 1 + 2, "one inner horizontal, two inner verticals")
    }

    func testHatchingStaysOutOfEveryFloorAndNearItsEdge() {
        let layer = UUID()
        let rooms = [floor(CGRect(x: 0, y: 0, width: 100, height: 100), layer: layer),
                     floor(CGRect(x: 100, y: 0, width: 100, height: 100), layer: layer)]
        for e in rooms { XCTAssertTrue(DungeonGrid.isFloor(e)) }
        let rocks = DungeonGrid.rock(for: rooms)
        XCTAssertFalse(rocks.isEmpty)
        // Cluster centres are where the hatching is; spot-check them through the strokes' midpoints.
        let both = CGRect(x: 0, y: 0, width: 200, height: 100)
        for rock in rocks {
            let box = rock.path.boundingBoxOfPath
            XCTAssertTrue(both.insetBy(dx: -40, dy: -40).contains(box), "hatching stays within the band around the floor")
        }
        let shared = CGRect(x: 90, y: 10, width: 20, height: 80) // the wall between the two rooms
        for rock in rocks {
            var crossesShared = false
            rock.path.applyWithBlock { el in
                if el.pointee.type == .moveToPoint, shared.contains(el.pointee.points[0]) { crossesShared = true }
            }
            XCTAssertFalse(crossesShared, "rooms that touch don't hatch each other")
        }
    }

    func testFillsThatAreNotGridAreNotFloors() {
        var e = floor(CGRect(x: 0, y: 0, width: 50, height: 50), layer: UUID())
        e.style.fillStyle = .hachure
        XCTAssertFalse(DungeonGrid.isFloor(e))
        e.style.fillStyle = .grid
        e.kind = .note
        XCTAssertFalse(DungeonGrid.isFloor(e))
    }

    func testHashMatchesGuildhall() {
        // Values from Guildhall's hatch.ts hash01, so the two apps hatch the same lattice the same way.
        XCTAssertEqual(DungeonGrid.hash01(-3, 7, 2), 0.007362572243437171, accuracy: 1e-15)
        XCTAssertEqual(DungeonGrid.hash01(12, -5, 3), 0.076604338362813, accuracy: 1e-15)
        XCTAssertEqual(DungeonGrid.hash01(1, 1, 1), 0.2899224341381341, accuracy: 1e-15)
    }

    func testGridSizeRoundTripsAndOldFilesDecode() throws {
        var s = Style()
        s.fillStyle = .grid
        s.gridSize = 30
        let back = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.fillStyle, .grid)
        XCTAssertEqual(back.cellSize, 30)
        let old = try JSONDecoder().decode(Style.self, from: Data(#"{"fillStyle":"hachure"}"#.utf8))
        XCTAssertNil(old.gridSize)
        XCTAssertEqual(old.cellSize, Style.defaultGridSize)
        s.gridSize = 1
        XCTAssertEqual(s.cellSize, 8, "never so small the lines merge")
    }

    func testSVGHasFloorGridAndHatching() {
        var doc = DottieDocument()
        doc.elements = [floor(CGRect(x: 0, y: 0, width: 100, height: 75), layer: doc.layers[0].id)]
        let svg = Exporter.svg(doc)
        // Rock hatching, the floor fill, the grid lines, the outline.
        XCTAssertGreaterThanOrEqual(svg.components(separatedBy: "<path").count - 1, 4)
        XCTAssertTrue(svg.contains("fill=\"#\(String(format: "%02x%02x%02x", 237, 227, 209))\""), svg)
    }

    func testExportBoundsIncludeTheHatching() {
        var doc = DottieDocument()
        doc.elements = [floor(CGRect(x: 0, y: 0, width: 100, height: 100), cell: 40, layer: doc.layers[0].id)]
        let b = Exporter.bounds(of: doc, padding: 0)
        XCTAssertEqual(b.minX, -40, accuracy: 0.01)
    }
}
