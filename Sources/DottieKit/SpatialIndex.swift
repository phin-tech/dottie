import Foundation
import CoreGraphics

/// Uniform-grid index over a document's elements, in draw order. Built once per document state and
/// reused while the view pans and zooms, so drawing, clicking and marquee selection cost what is
/// near the cursor or on screen rather than the whole drawing. An edit that only changes some
/// elements (a drag, a color change, a rename) is folded in with `update(to:)` instead of a rebuild.
public struct SpatialIndex: Sendable {
    /// Elements back to front (layer order, then array order). Positions returned by queries index this.
    public private(set) var ordered: [Element]
    /// Elements by id, for connector endpoint resolution.
    public private(set) var byID: [UUID: Element]

    private var bounds: [CGRect]
    private let cell: Double
    private var grid: [Cell: [Int32]] = [:]
    /// Elements too large to bucket: always candidates.
    private var oversize: [Int32] = []
    private var position: [UUID: Int32] = [:]
    private var layerOrder: [UUID]
    /// Connector position -> shapes it is bound to, and the reverse, so moving a shape re-bounds its connectors.
    private var refs: [Int32: [UUID]] = [:]
    private var connectorsOf: [UUID: Set<Int32>] = [:]

    private struct Cell: Hashable, Sendable { var x: Int32; var y: Int32 }

    /// Bounds are padded for stroke width, arrowheads and labels, so a query that touches an element's
    /// padded box is a candidate (callers still do the exact test).
    public init(_ doc: DottieDocument, cellSize: Double = 256) {
        let byID = doc.elementIndex
        let ordered = doc.orderedElements
        self.ordered = ordered
        self.byID = byID
        self.cell = cellSize
        self.layerOrder = doc.layers.map(\.id)
        self.bounds = []
        bounds.reserveCapacity(ordered.count)
        for (i, e) in ordered.enumerated() {
            let pos = Int32(i)
            position[e.id] = pos
            let b = Self.paddedBounds(e, in: doc, byID)
            bounds.append(b)
            insert(pos, b)
            track(pos, e)
        }
    }

    // MARK: Maintenance

    /// Folds `doc` into the index when it is the same drawing with some elements edited: same layers,
    /// same elements in the same layer order. Returns false (leaving the index untouched) when anything
    /// structural changed, and the caller should build a fresh index.
    public mutating func update(to doc: DottieDocument) -> Bool {
        guard doc.elements.count == ordered.count, doc.layers.map(\.id) == layerOrder else { return false }
        let rank = Dictionary(uniqueKeysWithValues: layerOrder.enumerated().map { ($1, $0) })
        var last = [Int32](repeating: -1, count: layerOrder.count)
        var changed: [(Int32, Element)] = []
        for e in doc.elements {
            guard let pos = position[e.id], let r = rank[e.layerID] else { return false }
            guard ordered[Int(pos)].layerID == e.layerID, pos > last[r] else { return false }
            last[r] = pos
            if ordered[Int(pos)] != e { changed.append((pos, e)) }
        }
        guard !changed.isEmpty else { return true }

        var dirty = Set<Int32>()
        for (pos, e) in changed {
            ordered[Int(pos)] = e
            byID[e.id] = e
            dirty.insert(pos)
            if let bound = connectorsOf[e.id] { dirty.formUnion(bound) } // their ends moved with the shape
        }
        for pos in dirty {
            remove(pos, bounds[Int(pos)])
            untrack(pos)
        }
        for pos in dirty {
            let e = ordered[Int(pos)]
            let b = Self.paddedBounds(e, in: doc, byID)
            bounds[Int(pos)] = b
            insert(pos, b)
            track(pos, e)
        }
        return true
    }

    private mutating func track(_ pos: Int32, _ e: Element) {
        guard let c = e.connector else { return }
        let ids = [c.start.elementID, c.end.elementID].compactMap { $0 }
        guard !ids.isEmpty else { return }
        refs[pos] = ids
        for id in ids { connectorsOf[id, default: []].insert(pos) }
    }

    private mutating func untrack(_ pos: Int32) {
        guard let ids = refs.removeValue(forKey: pos) else { return }
        for id in ids { connectorsOf[id]?.remove(pos) }
    }

    private static func paddedBounds(_ e: Element, in doc: DottieDocument, _ byID: [UUID: Element]) -> CGRect {
        let raw = e.kind == .connector ? Connector.bounds(of: e, in: doc, index: byID) : e.rotatedBounds
        let pad = e.style.strokeWidth + 60
        return raw.insetBy(dx: -pad, dy: -pad)
    }

    // MARK: Grid

    private static func cellIndex(_ v: Double, _ size: Double) -> Int32 {
        guard v.isFinite else { return 0 }
        return Int32(max(min((v / size).rounded(.down), 1_000_000), -1_000_000))
    }

    /// Cell span of `b`, or nil when it covers too many cells to bucket.
    private func span(_ b: CGRect) -> (x0: Int32, x1: Int32, y0: Int32, y1: Int32)? {
        guard b.width.isFinite, b.height.isFinite else { return nil }
        let x0 = Self.cellIndex(b.minX, cell), x1 = Self.cellIndex(b.maxX, cell)
        let y0 = Self.cellIndex(b.minY, cell), y1 = Self.cellIndex(b.maxY, cell)
        return (Int(x1) - Int(x0) + 1) * (Int(y1) - Int(y0) + 1) > 400 ? nil : (x0, x1, y0, y1)
    }

    private mutating func insert(_ pos: Int32, _ b: CGRect) {
        guard let s = span(b) else { oversize.append(pos); return }
        for cx in s.x0...s.x1 { for cy in s.y0...s.y1 { grid[Cell(x: cx, y: cy), default: []].append(pos) } }
    }

    private mutating func remove(_ pos: Int32, _ b: CGRect) {
        guard let s = span(b) else { oversize.removeAll { $0 == pos }; return }
        for cx in s.x0...s.x1 {
            for cy in s.y0...s.y1 {
                let c = Cell(x: cx, y: cy)
                guard var items = grid[c] else { continue }
                items.removeAll { $0 == pos }
                grid[c] = items.isEmpty ? nil : items
            }
        }
    }

    // MARK: Queries

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

    /// The topmost element under `point` on a visible, unlocked layer.
    /// `skipping` passes clicks through elements the editor isn't showing.
    public func element(at point: CGPoint, in doc: DottieDocument, skipping: Set<UUID> = []) -> Element? {
        let open = Set(doc.layers.filter { $0.visible && !$0.locked }.map(\.id))
        let probe = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        for pos in candidates(in: probe).reversed() {
            let e = ordered[pos]
            guard open.contains(e.layerID), !skipping.contains(e.id) else { continue }
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
