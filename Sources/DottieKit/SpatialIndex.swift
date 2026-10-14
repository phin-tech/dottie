import Foundation
import CoreGraphics

/// Uniform-grid index over a document's elements, in draw order. Built once per document state and
/// reused while the view pans and zooms, so drawing, clicking and marquee selection cost what is
/// near the cursor or on screen rather than the whole drawing.
public struct SpatialIndex: Sendable {
    /// Elements back to front (layer order, then array order). Positions returned by queries index this.
    public let ordered: [Element]
    /// Elements by id, for connector endpoint resolution.
    public let byID: [UUID: Element]
    private let bounds: [CGRect]
    private let cell: Double
    private var grid: [Cell: [Int32]] = [:]
    /// Elements too large to bucket: always candidates.
    private var oversize: [Int32] = []

    private struct Cell: Hashable, Sendable { var x: Int32; var y: Int32 }

    /// Bounds are padded for stroke width, arrowheads and labels, so a query that touches an element's
    /// padded box is a candidate (callers still do the exact test).
    public init(_ doc: DottieDocument, cellSize: Double = 256) {
        let byID = doc.elementIndex
        let ordered = doc.orderedElements
        self.ordered = ordered
        self.byID = byID
        self.cell = cellSize
        var boxes: [CGRect] = []
        boxes.reserveCapacity(ordered.count)
        for (i, e) in ordered.enumerated() {
            let raw = e.kind == .connector ? Connector.bounds(of: e, in: doc, index: byID) : e.rotatedBounds
            let pad = e.style.strokeWidth + 60
            let b = raw.insetBy(dx: -pad, dy: -pad)
            boxes.append(b)
            let (x0, x1, y0, y1) = (Self.cellIndex(b.minX, cellSize), Self.cellIndex(b.maxX, cellSize),
                                    Self.cellIndex(b.minY, cellSize), Self.cellIndex(b.maxY, cellSize))
            if (Int(x1) - Int(x0) + 1) * (Int(y1) - Int(y0) + 1) > 400 || !b.width.isFinite || !b.height.isFinite {
                oversize.append(Int32(i)); continue
            }
            for cx in x0...x1 { for cy in y0...y1 { grid[Cell(x: cx, y: cy), default: []].append(Int32(i)) } }
        }
        self.bounds = boxes
    }

    private static func cellIndex(_ v: Double, _ size: Double) -> Int32 {
        Int32(max(min((v / size).rounded(.down), 1_000_000), -1_000_000))
    }

    /// Positions in `ordered` (ascending, so draw order) whose padded bounds intersect `rect`.
    public func candidates(in rect: CGRect) -> [Int] {
        guard !rect.isNull, !rect.isInfinite else { return Array(ordered.indices) }
        let x0 = Self.cellIndex(rect.minX, cell), x1 = Self.cellIndex(rect.maxX, cell)
        let y0 = Self.cellIndex(rect.minY, cell), y1 = Self.cellIndex(rect.maxY, cell)
        var seen = Set<Int32>(oversize)
        if (Int(x1) - Int(x0) + 1) * (Int(y1) - Int(y0) + 1) > grid.count * 2 {
            // A view bigger than the occupied grid: cheaper to walk the buckets than the area.
            for (c, items) in grid where c.x >= x0 && c.x <= x1 && c.y >= y0 && c.y <= y1 { seen.formUnion(items) }
        } else {
            for cx in x0...x1 { for cy in y0...y1 { if let items = grid[Cell(x: cx, y: cy)] { seen.formUnion(items) } } }
        }
        return seen.map(Int.init).filter { bounds[$0].intersects(rect) || bounds[$0].contains(rect.origin) }.sorted()
    }

    /// The topmost element under `point` (within `tolerance`) on a visible, unlocked layer.
    public func element(at point: CGPoint, in doc: DottieDocument) -> Element? {
        let open = Set(doc.layers.filter { $0.visible && !$0.locked }.map(\.id))
        let probe = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        for pos in candidates(in: probe).reversed() {
            let e = ordered[pos]
            guard open.contains(e.layerID) else { continue }
            if e.kind == .connector {
                if Connector.distance(from: point, to: e, in: doc, index: byID) <= 6 { return e }
            } else if e.frame.insetBy(dx: -4, dy: -4).contains(e.unrotated(point)) {
                return e
            }
        }
        return nil
    }

    /// Ids of elements whose bounds intersect `rect`, for marquee selection.
    public func elements(intersecting rect: CGRect, in doc: DottieDocument) -> [UUID] {
        candidates(in: rect).compactMap { pos in
            let e = ordered[pos]
            let b = e.kind == .connector ? Connector.bounds(of: e, in: doc, index: byID) : e.rotatedBounds
            return b.intersects(rect) ? e.id : nil
        }
    }
}
