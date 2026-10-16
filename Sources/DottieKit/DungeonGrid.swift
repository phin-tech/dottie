import Foundation
import CoreGraphics

/// The `.grid` fill: a dungeon floor ruled into square cells, and Dyson-style hatching in the rock around
/// every floor on the page. Ported from Guildhall's map renderer (`mapStyle.ts`, `hatch.ts`).
///
/// Both patterns hang off one page-wide lattice anchored at (0, 0), not off each shape, so two rooms placed
/// on the lattice line up cell for cell and moving a room reveals a different part of the same hatching
/// instead of reshuffling it. Everything is a pure function of geometry, so nothing shimmers on redraw.
public enum DungeonGrid {
    // MARK: Floor grid

    /// Grid lines inside `polygons` (even-odd) at world multiples of `cell`. A line lying on the shape's
    /// own edge is left out, so a room snapped to the lattice doesn't draw a second line under its outline.
    public static func lines(in polygons: [[CGPoint]], cell: Double) -> [(CGPoint, CGPoint)] {
        scan(polygons, cell: cell, transposed: false) + scan(polygons, cell: cell, transposed: true)
    }

    /// Horizontal lines (or vertical ones, scanning the transposed polygons).
    private static func scan(_ polygons: [[CGPoint]], cell: Double, transposed: Bool) -> [(CGPoint, CGPoint)] {
        guard cell > 0 else { return [] }
        func flip(_ p: CGPoint) -> CGPoint { transposed ? CGPoint(x: p.y, y: p.x) : p }
        let polys = polygons.filter { $0.count >= 3 }.map { $0.map(flip) }
        let ys = polys.joined().map(\.y)
        guard let minY = ys.min(), let maxY = ys.max() else { return [] }
        var out: [(CGPoint, CGPoint)] = []
        var y = (minY / cell).rounded(.down) * cell
        while y < maxY - 0.5 {
            defer { y += cell }
            guard y > minY + 0.5 else { continue }
            var xs: [Double] = []
            for poly in polys {
                for i in poly.indices {
                    let a = poly[i], b = poly[(i + 1) % poly.count]
                    if (a.y <= y && y < b.y) || (b.y <= y && y < a.y) {
                        xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
                    }
                }
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                if xs[k + 1] - xs[k] > 0.5 { out.append((flip(CGPoint(x: xs[k], y: y)), flip(CGPoint(x: xs[k + 1], y: y)))) }
                k += 2
            }
        }
        return out
    }

    /// The faint pencil the grid is ruled in: a shade darker than a light floor, lighter than a dark one
    /// (Guildhall's parchment and blueprint styles).
    public static func lineColor(for floor: RGBA) -> RGBA {
        if floor.luminance > 0.5 {
            return RGBA(r: floor.r * 0.84, g: floor.g * 0.84, b: floor.b * 0.8, a: floor.a)
        }
        return RGBA(r: floor.r + (1 - floor.r) * 0.25, g: floor.g + (1 - floor.g) * 0.25, b: floor.b + (1 - floor.b) * 0.25, a: floor.a)
    }

    // MARK: Rock hatching

    /// Sub-cells per cell along each axis; one cluster spot per sub-cell.
    static let sub = 2
    /// How far into the rock the hatching reaches, in cells.
    public static let band = 0.75
    /// Clusters grow to this fraction of the distance to their nearest neighbour (Dolya's final variant).
    static let grow = 0.8
    /// How far a spot wanders from its sub-cell's centre.
    static let jitter = 0.6

    /// Whether `e` is a floor: a filled shape with the grid fill.
    public static func isFloor(_ e: Element) -> Bool {
        guard e.style.fillStyle == .grid, e.style.fill.a > 0 else { return false }
        switch e.kind {
        case .rectangle, .ellipse, .diamond, .path: return true
        default: return false
        }
    }

    /// One floor's share of the rock hatching, in the ink of the floor it lies nearest.
    public struct Rock {
        public var ink: RGBA
        public var width: Double
        public var path: CGPath
    }

    private struct Floor {
        var contours: [[CGPoint]]
        var box: CGRect
        var cell: Double
        var element: Element
    }

    /// Hatching for every floor in `floors` (already filtered by `isFloor`, in page coordinates). Spots
    /// inside any floor are dropped, so neighbouring rooms never scribble on each other; the floors are
    /// painted over it, so the strokes run under their edges.
    public static func rock(for floors: [Element]) -> [Rock] {
        guard !floors.isEmpty else { return [] }
        let key = floors.map(FloorKey.init)
        return rockCache.value(key) { computeRock(for: floors) }
    }

    private static func computeRock(for elements: [Element]) -> [Rock] {
        let floors = elements.map { e -> Floor in
            let contours = Renderer.fillPolygons(for: e).map { $0.map(e.rotated) }
            let pts = contours.joined()
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                             height: (ys.max() ?? 0) - (ys.min() ?? 0))
            return Floor(contours: contours, box: box, cell: e.style.cellSize, element: e)
        }
        var strokes = Array(repeating: [(CGPoint, CGPoint, UInt32)](), count: floors.count)
        var seen = Set<SpotKey>()
        for f in floors {
            let subSize = f.cell / Double(sub)
            let around = f.box.insetBy(dx: -f.cell, dy: -f.cell)
            let i0 = Int((around.minX / subSize).rounded(.down)), i1 = Int((around.maxX / subSize).rounded(.up))
            let j0 = Int((around.minY / subSize).rounded(.down)), j1 = Int((around.maxY / subSize).rounded(.up))
            let reach = band * f.cell
            for i in i0..<i1 {
                for j in j0..<j1 {
                    guard seen.insert(SpotKey(cell: f.cell, i: i, j: j)).inserted else { continue }
                    let at = spot(i, j, cell: f.cell)
                    var nearest = Double.infinity, owner = -1
                    for (n, g) in floors.enumerated() where g.box.insetBy(dx: -reach, dy: -reach).contains(at) {
                        if contains(g.contours, at) { nearest = 0; break }
                        let d = distance(from: at, to: g.contours)
                        if d < nearest { nearest = d; owner = n }
                    }
                    guard nearest > 0, nearest <= reach, owner >= 0 else { continue }
                    let angle = hash01(i, j, 3) * Double.pi
                    let size = clusterSize(i, j, at: at, cell: f.cell)
                    let seed = UInt32(truncatingIfNeeded: Int(hash01(i, j, 4) * 4294967296))
                    for (a, b) in clusterStrokes(at: at, angle: angle, size: size) { strokes[owner].append((a, b, seed)) }
                }
            }
        }
        return floors.indices.compactMap { n in
            guard !strokes[n].isEmpty else { return nil }
            let e = floors[n].element
            let path = CGMutablePath()
            for (a, b, seed) in strokes[n] {
                if e.style.roughness <= 0 { path.move(to: a); path.addLine(to: b) }
                else {
                    var rng = SeededRNG(seed: seed)
                    Rough.line(a, b, rng: &rng, roughness: e.style.roughness * 0.35, bowing: 0.2, into: path)
                }
            }
            var ink = e.style.stroke
            ink.a *= 0.6
            return Rock(ink: ink, width: max(0.8, e.style.strokeWidth * 0.45), path: path)
        }
    }

    /// A well-mixed value in [0, 1) from two integers and a salt; the same 32-bit hash as Guildhall's.
    static func hash01(_ i: Int, _ j: Int, _ salt: UInt32) -> Double {
        let ui = UInt32(truncatingIfNeeded: i), uj = UInt32(truncatingIfNeeded: j)
        var h = (ui &* 0x27d4eb2d) ^ (uj &* 0x165667b1) ^ (salt &* 0x9e3779b1)
        h = (h ^ (h >> 15)) &* 0x85ebca6b
        h = (h ^ (h >> 13)) &* 0xc2b2ae35
        h ^= h >> 16
        return Double(h) / 4294967296
    }

    /// Where sub-cell (i, j)'s cluster sits, in page coordinates.
    static func spot(_ i: Int, _ j: Int, cell: Double) -> CGPoint {
        let s = cell / Double(sub)
        return CGPoint(x: (Double(i) + 0.5 + (hash01(i, j, 1) - 0.5) * jitter) * s,
                       y: (Double(j) + 0.5 + (hash01(i, j, 2) - 0.5) * jitter) * s)
    }

    /// Dolya's gap fix: a cluster grows to just reach its nearest neighbouring spot.
    private static func clusterSize(_ i: Int, _ j: Int, at: CGPoint, cell: Double) -> Double {
        var nearest = Double.infinity
        for di in -1...1 {
            for dj in -1...1 where di != 0 || dj != 0 {
                let o = spot(i + di, j + dj, cell: cell)
                nearest = min(nearest, hypot(o.x - at.x, o.y - at.y))
            }
        }
        return nearest * grow
    }

    /// Three parallel strokes, the middle one through the centre, every end within `size` of it.
    static func clusterStrokes(at c: CGPoint, angle: Double, size: Double) -> [(CGPoint, CGPoint)] {
        let dx = cos(angle), dy = sin(angle)
        let half = size * 0.8, gap = size * 0.5
        return [-1.0, 0, 1].map { k in
            let cx = c.x - dy * gap * k, cy = c.y + dx * gap * k
            return (CGPoint(x: cx - dx * half, y: cy - dy * half), CGPoint(x: cx + dx * half, y: cy + dy * half))
        }
    }

    /// Even-odd point-in-polygon over every contour.
    private static func contains(_ contours: [[CGPoint]], _ p: CGPoint) -> Bool {
        var inside = false
        for poly in contours where poly.count >= 3 {
            var k = poly.count - 1
            for i in poly.indices {
                let a = poly[i], b = poly[k]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                k = i
            }
        }
        return inside
    }

    private static func distance(from p: CGPoint, to contours: [[CGPoint]]) -> Double {
        var best = Double.infinity
        for poly in contours where poly.count >= 2 {
            for i in poly.indices {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
                best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
            }
        }
        return best
    }

    // MARK: Cache

    private struct SpotKey: Hashable { var cell: Double; var i, j: Int }

    /// Everything a floor's hatching depends on, as plain values.
    private struct FloorKey: Hashable {
        var kind: ElementKind
        var x, y, w, h, rotation, cell: Double
        var pathHash: Int
        var ink: [Double]
        var roughness, strokeWidth: Double
        init(_ e: Element) {
            kind = e.kind; x = e.x; y = e.y; w = e.width; h = e.height; rotation = e.angle; cell = e.style.cellSize
            pathHash = e.subpaths?.hashValue ?? 0
            ink = [e.style.stroke.r, e.style.stroke.g, e.style.stroke.b, e.style.stroke.a]
            roughness = e.style.roughness; strokeWidth = e.style.strokeWidth
        }
    }

    private final class RockCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [[FloorKey]: [Rock]] = [:]
        func value(_ key: [FloorKey], _ make: () -> [Rock]) -> [Rock] {
            lock.lock()
            if let v = entries[key] { lock.unlock(); return v }
            lock.unlock()
            let v = make()
            lock.lock(); defer { lock.unlock() }
            if entries.count >= 16 { entries.removeAll(keepingCapacity: true) } // a drag makes a new key per event
            entries[key] = v
            return v
        }
    }

    private static let rockCache = RockCache()
}
