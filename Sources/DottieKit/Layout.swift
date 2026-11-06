import Foundation
import CoreGraphics

/// Simple layered (Sugiyama-lite) layout: longest-path ranks, barycenter ordering, centered ranks. An edge that
/// spans more than one rank gets a lane through each rank between, held open like a node as wide as its label, and
/// the gap between two ranks is deep enough for the labels that cross it, so labels drawn halfway along the
/// connectors stay off the shapes.
public enum Layout {
    /// One edge to lay out: its ends, and the size of its label (`Renderer.labelSize`), if it has one.
    public struct Edge {
        public var from, to: UUID
        public var label: CGSize?
        public init(from: UUID, to: UUID, label: CGSize? = nil) { self.from = from; self.to = to; self.label = label }
    }

    /// Where a laid-out edge runs.
    public struct Lane: Equatable {
        /// The edge goes against the flow, back to a rank before its start (a loop).
        public var reversed: Bool
        /// The edge's ends are in neighboring ranks; with `reversed`, another edge runs the other way between them.
        public var span: Int
        /// The bends through the ranks between its ends, start to end, for an elbow connector (right angles that
        /// turn halfway across each gap) and for a straight or curved one (into and out of each rank along its lane).
        /// Empty when its ends are in neighboring ranks.
        public var elbow: [CGPoint]
        public var direct: [CGPoint]
    }

    /// Space kept between a label and the ranks either side of it.
    static let labelPad = 8.0

    /// Lays out `doc`'s shapes along `edges`, moving them, and returns each edge's lane (nil for one between
    /// unknown shapes, or from a shape to itself).
    @discardableResult
    public static func layered(_ doc: inout DottieDocument, edges: [Edge], direction: LayoutDirection,
                               rankGap: Double = 90, nodeGap: Double = 50) -> [Lane?] {
        let nodeIdx = doc.elements.indices.filter { doc.elements[$0].kind != .connector }
        guard !nodeIdx.isEmpty else { return edges.map { _ in nil } }
        let ids = nodeIdx.map { doc.elements[$0].id }
        let n = ids.count
        let pos = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let tb = direction == .topToBottom

        // Keep edges between known nodes; drop self-loops. A repeated pair shares the first one's lane.
        var unique: [[Int]: Int] = [:]  // pair -> index into `pairs`
        var pairs: [(a: Int, b: Int, label: CGSize?)] = []
        var edgePair = [Int?](repeating: nil, count: edges.count)
        for (k, e) in edges.enumerated() {
            guard let i = pos[e.from], let j = pos[e.to], i != j else { continue }
            if let p = unique[[i, j]] {
                if let l = e.label, pairs[p].label.map({ $0.width * $0.height < l.width * l.height }) ?? true { pairs[p].label = l }
                edgePair[k] = p
                continue
            }
            unique[[i, j]] = pairs.count
            edgePair[k] = pairs.count
            pairs.append((i, j, e.label))
        }
        var out = [[Int]](repeating: [], count: n)
        for p in pairs { out[p.a].append(p.b) }

        // Break cycles with DFS: ignore back edges.
        var state = [Int](repeating: 0, count: n) // 0 new, 1 on stack, 2 done
        var dag = [[Int]](repeating: [], count: n)
        func visit(_ u: Int) {
            state[u] = 1
            for v in out[u] {
                if state[v] == 1 { continue }
                dag[u].append(v)
                if state[v] == 0 { visit(v) }
            }
            state[u] = 2
        }
        for u in 0..<n where state[u] == 0 { visit(u) }

        // Longest-path ranking in topological order.
        var indeg = [Int](repeating: 0, count: n)
        for u in dag.indices { for v in dag[u] { indeg[v] += 1 } }
        var rank = [Int](repeating: 0, count: n)
        var queue = (0..<n).filter { indeg[$0] == 0 }
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            for v in dag[u] {
                rank[v] = max(rank[v], rank[u] + 1)
                indeg[v] -= 1
                if indeg[v] == 0 { queue.append(v) }
            }
        }

        // Items are the nodes, then a dummy for each rank a long edge passes through: its lane.
        func size(_ u: Int) -> (breadth: Double, depth: Double) {
            let f = doc.elements[nodeIdx[u]].frame
            return tb ? (f.width, f.height) : (f.height, f.width)
        }
        var breadth = (0..<n).map { size($0).breadth }
        var itemRank = rank
        var preds = [[Int]](repeating: [], count: n)
        for u in dag.indices { for v in dag[u] where rank[v] == rank[u] + 1 { preds[v].append(u) } }
        var chains = [[Int]](repeating: [], count: pairs.count)  // each pair's dummies, from its lower rank up
        for (p, e) in pairs.enumerated() {
            let (lo, hi) = rank[e.a] < rank[e.b] ? (e.a, e.b) : (e.b, e.a)
            guard rank[hi] - rank[lo] > 1 else {
                if rank[hi] - rank[lo] == 1, !preds[hi].contains(lo) { preds[hi].append(lo) }
                continue
            }
            var prev = lo
            for r in (rank[lo] + 1)..<rank[hi] {
                let d = breadth.count
                breadth.append(max(e.label.map { tb ? $0.width : $0.height } ?? 0, 8))
                itemRank.append(r)
                preds.append([prev])
                chains[p].append(d)
                prev = d
            }
            preds[hi].append(prev)
        }

        let maxRank = rank.max() ?? 0
        var layers = [[Int]](repeating: [], count: maxRank + 1)
        for u in itemRank.indices { layers[itemRank[u]].append(u) }

        // Barycenter sweeps to cut crossings.
        var order = [Int](repeating: 0, count: itemRank.count)
        func reindex() { for l in layers { for (k, u) in l.enumerated() { order[u] = k } } }
        reindex()
        for _ in 0..<4 {
            for r in 1..<max(layers.count, 1) where r < layers.count {
                layers[r].sort { a, b in
                    func bc(_ u: Int) -> Double {
                        preds[u].isEmpty ? Double(order[u]) : preds[u].map { Double(order[$0]) }.reduce(0, +) / Double(preds[u].count)
                    }
                    let (x, y) = (bc(a), bc(b))
                    return x == y ? a < b : x < y
                }
                reindex()
            }
        }

        // Each rank as deep as its deepest node; each gap as deep as the labels crossing it need. A label sits
        // halfway along its route: for a lone hop between neighboring ranks, halfway between the two ends, which is
        // off-center in the gap when a shape is shallower than its rank.
        let layerDepth = layers.map { l in l.filter { $0 < n }.map { size($0).depth }.max() ?? 0 }
        var gaps = [Double](repeating: rankGap, count: max(maxRank, 0))
        for e in pairs {
            guard let l = e.label else { continue }
            let d = (tb ? l.height : l.width) + 2 * labelPad
            let (lo, hi) = rank[e.a] < rank[e.b] ? (e.a, e.b) : (e.b, e.a)
            if rank[hi] - rank[lo] == 1 {
                let slackLo = layerDepth[rank[lo]] - size(lo).depth, slackHi = layerDepth[rank[hi]] - size(hi).depth
                gaps[rank[lo]] = max(gaps[rank[lo]], d + abs(slackLo - slackHi) / 2)
            } else {
                for r in rank[lo]..<rank[hi] {
                    let slack = r == rank[lo] ? layerDepth[r] - size(lo).depth
                        : r == rank[hi] - 1 ? layerDepth[r + 1] - size(hi).depth : 0
                    gaps[r] = max(gaps[r], d + slack / 2)
                }
            }
        }

        // Coordinates: along-rank axis is "breadth", across ranks is "depth".
        let breadths = layers.map { l in l.map { breadth[$0] }.reduce(0, +) + Double(max(l.count - 1, 0)) * nodeGap }
        let widest = breadths.max() ?? 0
        var center = [Double](repeating: 0, count: itemRank.count)  // breadth of each item's middle
        var bandStart = [Double](repeating: 0, count: layers.count)
        var depthCursor = 0.0
        for (r, l) in layers.enumerated() {
            bandStart[r] = depthCursor
            var cursor = (widest - breadths[r]) / 2
            for u in l {
                center[u] = cursor + breadth[u] / 2
                if u < n {
                    let s = size(u)
                    let depth = depthCursor + (layerDepth[r] - s.depth) / 2
                    var f = doc.elements[nodeIdx[u]].frame
                    f.origin = tb ? CGPoint(x: cursor, y: depth) : CGPoint(x: depth, y: cursor)
                    doc.elements[nodeIdx[u]].frame = f
                }
                cursor += breadth[u] + nodeGap
            }
            depthCursor += layerDepth[r] + (r < gaps.count ? gaps[r] : 0)
        }

        func point(_ b: Double, _ d: Double) -> CGPoint { tb ? CGPoint(x: b, y: d) : CGPoint(x: d, y: b) }
        let lanes: [Lane] = pairs.enumerated().map { p, e in
            let reversed = rank[e.b] < rank[e.a]
            let (lo, hi) = reversed ? (e.b, e.a) : (e.a, e.b)
            let span = rank[hi] - rank[lo]
            var elbow: [CGPoint] = [], direct: [CGPoint] = []
            if span > 1 {
                let path = [lo] + chains[p] + [hi]
                for (k, u) in path.enumerated() where k < path.count - 1 {
                    let r = rank[lo] + k
                    let mid = bandStart[r] + layerDepth[r] + gaps[r] / 2
                    elbow.append(point(center[u], mid))
                    elbow.append(point(center[path[k + 1]], mid))
                }
                for d in chains[p] {
                    let r = itemRank[d]
                    direct.append(point(center[d], bandStart[r]))
                    direct.append(point(center[d], bandStart[r] + layerDepth[r]))
                }
                elbow = Connector.simplified(elbow)
                if reversed { elbow.reverse(); direct.reverse() }
            }
            return Lane(reversed: reversed, span: span, elbow: elbow, direct: direct)
        }
        return edgePair.map { $0.map { lanes[$0] } }
    }

    /// The ports a laid-out connector pins (start, end) and the bends it runs through: along the flow, through its
    /// lane. A lone hop back against the flow beside one going forward leaves and enters from the side instead, so
    /// the two don't draw over each other.
    static func route(_ lane: Lane, routing: Routing, direction: LayoutDirection, twin: Bool) -> (Port, Port, [CGPoint]) {
        let tb = direction == .topToBottom
        if lane.reversed && lane.span == 1 && twin { return tb ? (.right, .right, []) : (.bottom, .bottom, []) }
        let forward: (Port, Port) = tb ? (.bottom, .top) : (.right, .left)
        let ports = lane.reversed ? (forward.1, forward.0) : forward
        return (ports.0, ports.1, routing == .elbow ? lane.elbow : lane.direct)
    }
}
