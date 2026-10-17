import CoreGraphics
import Foundation

/// Building a flowchart from the keyboard: ⌘-arrow grows new nodes off a shape, joined to it by elbow connectors,
/// and ⌥-arrow walks from node to node along the connectors.
public enum Flowchart {
    public enum Direction: String, Sendable, CaseIterable {
        case up, right, down, left

        var horizontal: Bool { self == .left || self == .right }
        /// The ports a connector leaves and enters by when it runs this way.
        var ports: (Port, Port) {
            switch self {
            case .up: (.top, .bottom)
            case .right: (.right, .left)
            case .down: (.bottom, .top)
            case .left: (.left, .right)
            }
        }
    }

    /// The gap between a node and its new children, and between children side by side.
    public static let gap = 100.0

    /// Kinds that can grow a flowchart.
    public static func isNode(_ kind: ElementKind) -> Bool {
        kind == .rectangle || kind == .ellipse || kind == .diamond
    }

    /// The next kind Tab turns a node into: rectangle, diamond, ellipse, and round again.
    public static func nextKind(after kind: ElementKind) -> ElementKind? {
        switch kind {
        case .rectangle: .diamond
        case .diamond: .ellipse
        case .ellipse: .rectangle
        default: nil
        }
    }

    /// Adds `count` nodes one gap `direction` of `sourceID`, each a copy of its kind, size and style without its
    /// text, and joins each to it with an elbow connector. The new nodes sit side by side across the direction, as
    /// near to centered on the source as the rest of its flowchart allows; `crossStart` (from a previous call)
    /// keeps nodes already shown in place as the row grows. Returns the new nodes' ids, in order across the row,
    /// and the row's cross-axis start.
    @discardableResult
    public static func addNodes(_ doc: inout DottieDocument, from sourceID: UUID, direction: Direction, count: Int,
                                crossStart: Double? = nil) throws -> (nodes: [UUID], crossStart: Double) {
        guard let source = doc.elements.first(where: { $0.id == sourceID }) else {
            throw OpsError.notFound("No element \(sourceID.uuidString)")
        }
        guard isNode(source.kind) else { throw OpsError.invalid("Only rectangles, ellipses and diamonds grow a flowchart") }
        guard let layer = doc.layers.first(where: { $0.id == source.layerID }), !layer.locked else {
            throw OpsError.invalid("The shape's layer is locked")
        }
        let obstacles = connected(to: sourceID, in: doc).compactMap { doc.elementIndex[$0]?.frame }
        let (origins, start) = place(source.frame, direction: direction, count: max(1, count), obstacles: obstacles,
                                     sticky: crossStart)
        var style = Style()
        style.stroke = source.style.stroke
        style.strokeWidth = source.style.strokeWidth
        style.dash = source.style.dash
        style.roughness = source.style.roughness
        style.opacity = source.style.opacity
        var ids: [UUID] = []
        for origin in origins {
            let node = Element(kind: source.kind, frame: CGRect(origin: origin, size: source.frame.size),
                               style: source.style, layerID: source.layerID)
            doc.elements.append(node)
            let data = ConnectorData(start: .bound(sourceID, port: direction.ports.0),
                                     end: .bound(node.id, port: direction.ports.1), routing: .elbow)
            doc.elements.append(Element(kind: .connector, frame: .zero, style: style, layerID: source.layerID,
                                        connector: data))
            ids.append(node.id)
        }
        return (ids, start)
    }

    /// Every shape joined to `id` by connectors, directly or through others (not `id` itself).
    static func connected(to id: UUID, in doc: DottieDocument) -> [UUID] {
        var links: [UUID: [UUID]] = [:]
        for e in doc.elements where e.kind == .connector {
            guard let a = e.connector?.start.elementID, let b = e.connector?.end.elementID else { continue }
            links[a, default: []].append(b)
            links[b, default: []].append(a)
        }
        var seen: Set<UUID> = [id], queue = [id], found: [UUID] = []
        while let next = queue.popLast() {
            for n in links[next] ?? [] where seen.insert(n).inserted {
                found.append(n)
                queue.append(n)
            }
        }
        return found
    }

    /// Top-left corners for `count` nodes the size of `parent`, in a row one gap `direction` of it. Along the row
    /// the nodes take the free stretch nearest to centered on the parent, keeping a gap from every obstacle that
    /// overlaps the row's band.
    static func place(_ parent: CGRect, direction: Direction, count: Int, obstacles: [CGRect],
                      sticky: Double?) -> ([CGPoint], Double) {
        let h = direction.horizontal
        let primarySize = h ? parent.width : parent.height
        let crossSize = h ? parent.height : parent.width
        let primaryStart = switch direction {
        case .right: parent.maxX + gap
        case .down: parent.maxY + gap
        case .left: parent.minX - gap - primarySize
        case .up: parent.minY - gap - primarySize
        }
        let center = h ? parent.midY : parent.midX
        let occupied = merge(obstacles.filter { r in
            let (lo, hi) = h ? (r.minX, r.maxX) : (r.minY, r.maxY)
            return lo < primaryStart + primarySize && hi > primaryStart
        }.map { r in h ? (r.minY - gap, r.maxY + gap) : (r.minX - gap, r.maxX + gap) })
        let step = crossSize + gap
        let size = Double(count) * crossSize + Double(count - 1) * gap
        func free(_ s: Double) -> Bool { occupied.allSatisfy { s + size <= $0.0 || s >= $0.1 } }
        // A growing row keeps its nodes where they were, adding at whichever end stays nearer the center.
        let anchored = sticky.flatMap { s in
            [s, s - step].filter(free).min { abs($0 + size / 2 - center) < abs($1 + size / 2 - center) }
        }
        let start = anchored ?? nearestFree(center - size / 2, size: size, occupied: occupied)
        let origins = (0..<count).map { i -> CGPoint in
            let cross = start + Double(i) * step
            return h ? CGPoint(x: primaryStart, y: cross) : CGPoint(x: cross, y: primaryStart)
        }
        return (origins, start)
    }

    private static func merge(_ intervals: [(Double, Double)]) -> [(Double, Double)] {
        var merged: [(Double, Double)] = []
        for i in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, i.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, i.1) } else { merged.append(i) }
        }
        return merged
    }

    /// The start nearest `ideal` for a stretch of `size` clear of every occupied interval; ties go positive.
    private static func nearestFree(_ ideal: Double, size: Double, occupied: [(Double, Double)]) -> Double {
        let starts = [-Double.infinity] + occupied.map(\.1), ends = occupied.map(\.0) + [Double.infinity]
        var best = ideal, distance = Double.infinity
        for (lo, hi) in zip(starts, ends) where hi - lo >= size {
            let s = min(max(ideal, lo), hi - size)
            if abs(s - ideal) <= distance { best = s; distance = abs(s - ideal) }
        }
        return best
    }

    /// The shapes joined to `id` by a connector (either way) that lie `direction` of it, judged center to center,
    /// ordered left to right or top to bottom across the direction.
    public static func neighbors(of id: UUID, toward direction: Direction, in doc: DottieDocument) -> [UUID] {
        let index = doc.elementIndex
        guard let from = index[id]?.frame else { return [] }
        var seen: Set<UUID> = []
        var found: [(UUID, CGRect)] = []
        for e in doc.elements where e.kind == .connector {
            guard let c = e.connector, let a = c.start.elementID, let b = c.end.elementID else { continue }
            let other = a == id ? b : b == id ? a : nil
            guard let other, other != id, let r = index[other]?.frame, seen.insert(other).inserted else { continue }
            let dx = r.midX - from.midX, dy = r.midY - from.midY
            let toward = switch direction {
            case .right: dx > 0 && abs(dx) >= abs(dy)
            case .left: dx < 0 && abs(dx) >= abs(dy)
            case .down: dy > 0 && abs(dy) >= abs(dx)
            case .up: dy < 0 && abs(dy) >= abs(dx)
            }
            if toward { found.append((other, r)) }
        }
        return found.sorted { direction.horizontal ? $0.1.midY < $1.1.midY : $0.1.midX < $1.1.midX }.map(\.0)
    }

    /// ⌥-arrow from node to node. The first press in a direction goes to the first neighbor that way (leftmost or topmost); pressing
    /// it again while still there steps through that neighbor's siblings, so a decision's branches are one key
    /// apart. Another direction, or a node chosen some other way, starts over from where the selection is.
    public struct Navigator: Sendable {
        private var direction: Direction?
        private var siblings: [UUID] = []
        private var index = 0

        public init() {}

        public mutating func step(from current: UUID, toward direction: Direction, in doc: DottieDocument) -> UUID? {
            if direction == self.direction, siblings.count > 1, siblings.indices.contains(index), siblings[index] == current {
                index = (index + 1) % siblings.count
                return siblings[index]
            }
            let found = Flowchart.neighbors(of: current, toward: direction, in: doc)
            guard let first = found.first else { return nil }
            self.direction = direction
            siblings = found
            index = 0
            return first
        }
    }
}
