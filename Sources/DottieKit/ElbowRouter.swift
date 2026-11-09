import Foundation
import CoreGraphics

/// Elbow connectors that go round shapes (web/src/elbow.ts is the same algorithm, point for point). A connector
/// keeps its plain Z or L when that crosses no other shape, so drawings whose elbows were clear look as they did.
/// When it would cut through one, it is routed over a grid made from the edges of the shapes in the way, padded by
/// `margin`: the shortest way with the fewest bends that crosses none of them, leaving and arriving along the same
/// axes as the plain route. Routes stay worked out at draw time; nothing is stored.
enum ElbowRouter {
    /// How far a route keeps from the shapes it goes round.
    static let margin: CGFloat = 16
    /// What a bend costs, in points of length: a route takes a detour this long to save one.
    static let bend: CGFloat = 24
    /// Shapes smaller than this either way (packets, dots, small icons) aren't in the way.
    static let smallest: CGFloat = 24
    /// More shapes in the way than this, and the plain route is kept.
    static let most = 48

    /// The box of `e` if a route goes round it: not a connector, text, freehand line or plain path, not invisible,
    /// and not small.
    static func obstacle(_ e: Element) -> CGRect? {
        switch e.kind {
        case .connector, .text, .freehand: return nil
        case .path: if e.extension == nil { return nil }
        default: break
        }
        if let o = e.style.opacity, o <= 0 { return nil }
        let r = e.rotatedBounds
        return r.width < smallest || r.height < smallest ? nil : r
    }

    /// Whether the right-angled line through `points` passes through the inside of `r` (not just along its edge).
    static func crosses(_ points: [CGPoint], _ r: CGRect) -> Bool {
        guard points.count >= 2 else { return false }
        for k in 1..<points.count {
            let p = points[k - 1], q = points[k]
            if p.y == q.y {
                if r.minY < p.y && p.y < r.maxY && min(p.x, q.x) < r.maxX && max(p.x, q.x) > r.minX { return true }
            } else if p.x == q.x {
                if r.minX < p.x && p.x < r.maxX && min(p.y, q.y) < r.maxY && max(p.y, q.y) > r.minY { return true }
            }
        }
        return false
    }

    private static func padded(_ r: CGRect) -> CGRect { r.insetBy(dx: -margin, dy: -margin) }

    private static func inside(_ p: CGPoint, _ r: CGRect) -> Bool { r.minX < p.x && p.x < r.maxX && r.minY < p.y && p.y < r.maxY }

    /// `plain` (the Z or L from `a` to `b`), or a way round the shapes of `doc` it crosses, leaving out `except`
    /// (the connector's own ends). `startVertical` and `endVertical` are the axes it leaves and arrives along.
    static func avoiding(_ plain: [CGPoint], from a: CGPoint, to b: CGPoint, startVertical: Bool, endVertical: Bool,
                         in doc: DottieDocument, except: Set<UUID>) -> [CGPoint] {
        // A shape either end sits inside (a frame round both, say) can't be gone round.
        func usable(_ r: CGRect) -> Bool { !inside(a, padded(r)) && !inside(b, padded(r)) }
        var all: [CGRect] = [], crossed: [CGRect] = []
        for e in doc.elements where !except.contains(e.id) {
            guard let r = obstacle(e), usable(r) else { continue }
            all.append(r)
            if crosses(plain, r) { crossed.append(r) }
        }
        // Most elbows cross nothing.
        guard !crossed.isEmpty else { return plain }
        let key = Key(a: a, b: b, startVertical: startVertical, endVertical: endVertical, crossed: crossed, count: all.count)
        if let hit = memo.get(key, all) { return hit }
        let out = route(plain, from: a, to: b, startVertical: startVertical, endVertical: endVertical, usable: all)
        memo.set(key, all, out)
        return out
    }

    static func avoiding(_ plain: [CGPoint], from a: CGPoint, to b: CGPoint, startVertical: Bool, endVertical: Bool,
                         obstacles all: [CGRect]) -> [CGPoint] {
        let usable = all.filter { !inside(a, padded($0)) && !inside(b, padded($0)) }
        return route(plain, from: a, to: b, startVertical: startVertical, endVertical: endVertical, usable: usable)
    }

    private static func route(_ plain: [CGPoint], from a: CGPoint, to b: CGPoint, startVertical: Bool, endVertical: Bool,
                              usable: [CGRect]) -> [CGPoint] {
        var chosen = usable.indices.filter { crosses(plain, usable[$0]) }
        guard !chosen.isEmpty else { return plain }
        for _ in 0..<4 {
            guard chosen.count <= most,
                  let path = grid(from: a, to: b, startVertical: startVertical, endVertical: endVertical,
                                  around: chosen.map { padded(usable[$0]) }) else { return plain }
            // Going round one shape can lead through another: add those, and route again.
            let more = usable.indices.filter { !chosen.contains($0) && crosses(path, usable[$0]) }
            if more.isEmpty { return path }
            chosen = (chosen + more).sorted()
        }
        return plain
    }

    // Every frame draws, measures and hops each connector, each asking for its route: the routes worked out
    // lately, by their ends and every shape a route could go round.
    private struct Key: Hashable {
        var a: CGPoint, b: CGPoint, startVertical: Bool, endVertical: Bool, crossed: [CGRect], count: Int
        func hash(into h: inout Hasher) {
            h.combine(a.x); h.combine(a.y); h.combine(b.x); h.combine(b.y); h.combine(startVertical); h.combine(endVertical)
            h.combine(count)
            for r in crossed { h.combine(r.minX); h.combine(r.minY); h.combine(r.width); h.combine(r.height) }
        }
    }

    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [Key: (all: [CGRect], route: [CGPoint])] = [:]
        func get(_ key: Key, _ all: [CGRect]) -> [CGPoint]? {
            lock.lock(); defer { lock.unlock() }
            guard let hit = routes[key], hit.all == all else { return nil }
            return hit.route
        }
        func set(_ key: Key, _ all: [CGRect], _ route: [CGPoint]) {
            lock.lock(); defer { lock.unlock() }
            if routes.count >= 512 { routes.removeAll() }
            routes[key] = (all, route)
        }
    }
    private static let memo = Memo()

    /// The cheapest right-angled way from `a` to `b` over the lines through the boxes' edges and the ends, crossing
    /// none of `boxes`; nil when there is none.
    private static func grid(from a: CGPoint, to b: CGPoint, startVertical: Bool, endVertical: Bool,
                             around boxes: [CGRect]) -> [CGPoint]? {
        var xs = [a.x, b.x, (a.x + b.x) / 2], ys = [a.y, b.y, (a.y + b.y) / 2]
        for r in boxes { xs += [r.minX, r.maxX]; ys += [r.minY, r.maxY] }
        xs = Array(Set(xs)).sorted(); ys = Array(Set(ys)).sorted()
        let nx = xs.count, ny = ys.count
        guard let ia = xs.firstIndex(of: a.x), let ja = ys.firstIndex(of: a.y),
              let ib = xs.firstIndex(of: b.x), let jb = ys.firstIndex(of: b.y) else { return nil }
        // What each box blocks, marked once: the grid points strictly inside it, and the steps through it. The
        // grid has a line on every box edge, so a step between neighbouring lines is wholly inside a box or outside.
        var at: [CGFloat: Int] = [:], bt: [CGFloat: Int] = [:]
        for (k, x) in xs.enumerated() { at[x] = k }
        for (k, y) in ys.enumerated() { bt[y] = k }
        var inner = [Bool](repeating: false, count: nx * ny)
        var acrossBlocked = [Bool](repeating: false, count: nx * ny), downBlocked = [Bool](repeating: false, count: nx * ny)
        for r in boxes {
            guard let i0 = at[r.minX], let i1 = at[r.maxX], let j0 = bt[r.minY], let j1 = bt[r.maxY] else { continue }
            for i in i0..<i1 {
                for j in j0..<j1 {
                    if j > j0 { acrossBlocked[i * ny + j] = true }       // from (i, j) to (i + 1, j)
                    if i > i0 { downBlocked[i * ny + j] = true }         // from (i, j) to (i, j + 1)
                    if i > i0 && j > j0 { inner[i * ny + j] = true }
                }
            }
        }
        func blocked(_ i: Int, _ j: Int) -> Bool { inner[i * ny + j] }
        func across(_ i0: Int, _ i1: Int, _ j: Int) -> Bool { acrossBlocked[min(i0, i1) * ny + j] }
        func down(_ j0: Int, _ j1: Int, _ i: Int) -> Bool { downBlocked[i * ny + min(j0, j1)] }
        // A state is a grid point and the axis it was reached along (0 across, 1 down).
        let count = nx * ny * 2
        var dist = [CGFloat](repeating: .infinity, count: count), prev = [Int](repeating: -1, count: count)
        var done = [Bool](repeating: false, count: count)
        var heap = Frontier()
        let first = (ia * ny + ja) * 2 + (startVertical ? 1 : 0)
        dist[first] = 0
        heap.push(0, first)
        let want = (ib * ny + jb) * 2 + (endVertical ? 1 : 0)
        while let (cost, s) = heap.pop() {
            if done[s] { continue }
            done[s] = true
            if s == want { break }
            let node = s / 2, axis = s % 2, i = node / ny, j = node % ny
            for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let ni = i + di, nj = j + dj
                guard ni >= 0, ni < nx, nj >= 0, nj < ny, !blocked(ni, nj) else { continue }
                let turn = di != 0 ? 0 : 1
                if di != 0 ? across(i, ni, j) : down(j, nj, i) { continue }
                let length = abs(xs[ni] - xs[i]) + abs(ys[nj] - ys[j])
                let c = cost + length + (turn != axis ? bend : 0)
                let t = (ni * ny + nj) * 2 + turn
                if c < dist[t] { dist[t] = c; prev[t] = s; heap.push(c, t) }
            }
        }
        guard done[want] else { return nil }
        var points: [CGPoint] = []
        var s = want
        while s >= 0 { let node = s / 2; points.append(CGPoint(x: xs[node / ny], y: ys[node % ny])); s = prev[s] }
        return Connector.simplified(points.reversed())
    }

    /// States waiting to be settled, cheapest first, ties to the one queued first (a binary heap).
    private struct Frontier {
        private var heap: [(cost: CGFloat, order: Int, state: Int)] = []
        private var next = 0
        private func less(_ i: Int, _ j: Int) -> Bool {
            heap[i].cost < heap[j].cost || (heap[i].cost == heap[j].cost && heap[i].order < heap[j].order)
        }
        mutating func push(_ cost: CGFloat, _ state: Int) {
            heap.append((cost, next, state)); next += 1
            var i = heap.count - 1
            while i > 0 { let up = (i - 1) / 2; if !less(i, up) { break }; heap.swapAt(i, up); i = up }
        }
        mutating func pop() -> (CGFloat, Int)? {
            guard let top = heap.first else { return nil }
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < heap.count && less(l, m) { m = l }
                    if r < heap.count && less(r, m) { m = r }
                    if m == i { break }
                    heap.swapAt(i, m); i = m
                }
            }
            return (top.cost, top.state)
        }
    }
}
