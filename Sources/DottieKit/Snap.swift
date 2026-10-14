import Foundation
import CoreGraphics

/// Smart guides and grid snapping. All distances are in model units; callers divide screen
/// points by zoom so the snap distance feels constant on screen.
public enum Snap {
    public struct Guide: Equatable, Sendable {
        public enum Axis: Sendable { case vertical, horizontal }
        public var axis: Axis
        /// x for a vertical guide, y for a horizontal one.
        public var position: Double
        public var from: Double
        public var to: Double
    }

    /// Equal-gap marker: the gaps (as `from`..`to` spans along `axis`) drawn at `cross` on the other axis.
    public struct SpacingGuide: Equatable, Sendable {
        public var axis: Guide.Axis
        public var cross: Double
        public var spans: [ClosedRange<Double>]
    }

    public struct Result: Equatable, Sendable {
        public var dx: Double = 0
        public var dy: Double = 0
        public var guides: [Guide] = []
        public var spacing: [SpacingGuide] = []
    }

    public static func grid(_ v: Double, size: Double) -> Double { size > 0 ? (v / size).rounded() * size : v }

    /// Offset that aligns `moving`'s edges or center with `others`' edges or centers within
    /// `threshold`; falls back to the grid on an axis with no object match.
    public static func move(_ moving: CGRect, others: [CGRect], threshold: Double, gridSize: Double? = nil,
                            guidesX: [Double] = [], guidesY: [Double] = []) -> Result {
        var result = Result()
        func xs(_ r: CGRect) -> [Double] { [r.minX, r.midX, r.maxX] }
        func ys(_ r: CGRect) -> [Double] { [r.minY, r.midY, r.maxY] }

        func best(_ mine: [Double], _ theirs: (CGRect) -> [Double]) -> (delta: Double, target: Double, other: CGRect)? {
            var found: (Double, Double, CGRect)?
            for o in others {
                for t in theirs(o) {
                    for m in mine {
                        let d = t - m
                        if abs(d) <= threshold, found == nil || abs(d) < abs(found!.0) { found = (d, t, o) }
                    }
                }
            }
            return found.map { (delta: $0.0, target: $0.1, other: $0.2) }
        }

        /// Offset that puts one of `mine` on a ruler guide, if any is within the threshold.
        func onGuide(_ mine: [Double], _ guides: [Double]) -> Double? {
            guides.flatMap { g in mine.map { g - $0 } }.filter { abs($0) <= threshold }.min { abs($0) < abs($1) }
        }
        let gx = onGuide(xs(moving), guidesX), gy = onGuide(ys(moving), guidesY)

        if let hit = best(xs(moving), xs) {
            result.dx = hit.delta
            if let g = gx, abs(g) < abs(hit.delta) { result.dx = g }
        } else if let g = gx {
            result.dx = g
        } else if let g = gridSize, g > 0 {
            result.dx = grid(moving.minX, size: g) - moving.minX
        }
        if let hit = best(ys(moving), ys) {
            result.dy = hit.delta
            if let g = gy, abs(g) < abs(hit.delta) { result.dy = g }
        } else if let g = gy {
            result.dy = g
        } else if let g = gridSize, g > 0 {
            result.dy = grid(moving.minY, size: g) - moving.minY
        }

        // Equal spacing: where an axis found no edge match, a position that makes two gaps equal
        // (between two neighbours, or repeating the gap of an existing pair) wins over the raw grid.
        if !others.isEmpty {
            if gx == nil, !hasEdgeMatch(xs(moving), xs, others, threshold),
               let m = spacingMatch(moving, others, horizontal: true, threshold: threshold) {
                result.dx = m.delta; result.spacing.append(contentsOf: m.guides)
            }
            if gy == nil, !hasEdgeMatch(ys(moving), ys, others, threshold),
               let m = spacingMatch(moving, others, horizontal: false, threshold: threshold) {
                result.dy = m.delta; result.spacing.append(contentsOf: m.guides)
            }
        }

        // Guides are computed against the snapped position so they sit exactly on the match.
        let snapped = moving.offsetBy(dx: result.dx, dy: result.dy)
        for o in others {
            for t in xs(o) where xs(snapped).contains(where: { abs($0 - t) < 0.01 }) {
                result.guides.append(Guide(axis: .vertical, position: t,
                                           from: min(o.minY, snapped.minY), to: max(o.maxY, snapped.maxY)))
            }
            for t in ys(o) where ys(snapped).contains(where: { abs($0 - t) < 0.01 }) {
                result.guides.append(Guide(axis: .horizontal, position: t,
                                           from: min(o.minX, snapped.minX), to: max(o.maxX, snapped.maxX)))
            }
        }
        return result
    }

    private static func hasEdgeMatch(_ mine: [Double], _ theirs: (CGRect) -> [Double], _ others: [CGRect], _ threshold: Double) -> Bool {
        for o in others { for t in theirs(o) { for m in mine where abs(t - m) <= threshold { return true } } }
        return false
    }

    /// Offset along one axis that equalises gaps with neighbours that overlap `moving` on the cross axis.
    static func spacingMatch(_ moving: CGRect, _ others: [CGRect], horizontal: Bool, threshold: Double)
        -> (delta: Double, guides: [SpacingGuide])? {
        func lo(_ r: CGRect) -> Double { horizontal ? r.minX : r.minY }
        func hi(_ r: CGRect) -> Double { horizontal ? r.maxX : r.maxY }
        func crossOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
            horizontal ? (a.minY < b.maxY && b.minY < a.maxY) : (a.minX < b.maxX && b.minX < a.maxX)
        }
        func crossMid(_ r: CGRect) -> Double { horizontal ? r.midY : r.midX }
        let axis: Guide.Axis = horizontal ? .horizontal : .vertical
        let near = others.filter { crossOverlap($0, moving) }.sorted { lo($0) < lo($1) }
        let before = near.filter { hi($0) <= lo(moving) + threshold }
        let after = near.filter { lo($0) >= hi(moving) - threshold }
        var best: (delta: Double, guides: [SpacingGuide])?
        func consider(_ delta: Double, _ guides: [SpacingGuide]) {
            if abs(delta) <= threshold, best == nil || abs(delta) < abs(best!.delta) { best = (delta, guides) }
        }
        // Centered between the nearest neighbour on each side.
        if let a = before.last, let b = after.first {
            let gapA = lo(moving) - hi(a), gapB = lo(b) - hi(moving)
            let d = (gapB - gapA) / 2
            let g = (gapA + gapB) / 2
            let m = moving.offsetBy(dx: horizontal ? d : 0, dy: horizontal ? 0 : d)
            let cross = crossMid(m)
            consider(d, [SpacingGuide(axis: axis, cross: cross, spans: [hi(a)...(hi(a) + g), (lo(b) - g)...lo(b)])])
        }
        // Repeating the gap of the two nearest neighbours on one side.
        if before.count >= 2 {
            let a = before[before.count - 2], b = before[before.count - 1]
            let gap = lo(b) - hi(a)
            if gap > 0 {
                let d = hi(b) + gap - lo(moving)
                consider(d, [SpacingGuide(axis: axis, cross: crossMid(b), spans: [hi(a)...lo(b), hi(b)...(hi(b) + gap)])])
            }
        }
        if after.count >= 2 {
            let a = after[0], b = after[1]
            let gap = lo(b) - hi(a)
            if gap > 0 {
                let d = lo(a) - gap - hi(moving)
                consider(d, [SpacingGuide(axis: axis, cross: crossMid(a), spans: [(lo(a) - gap)...lo(a), hi(a)...lo(b)])])
            }
        }
        return best
    }

    /// Snaps the edges a resize handle is moving to other shapes' edges and centers.
    /// `hx`/`hy` follow the handle convention: -1 moves the min side, 1 the max side, 0 neither.
    public static func resize(_ rect: CGRect, hx: Int, hy: Int, others: [CGRect], threshold: Double,
                              guidesX: [Double] = [], guidesY: [Double] = []) -> Result {
        var result = Result()
        func nearest(_ v: Double, _ candidates: [Double]) -> Double? {
            candidates.map { $0 - v }.filter { abs($0) <= threshold }.min { abs($0) < abs($1) }
        }
        let xs: [Double] = others.flatMap { [Double($0.minX), Double($0.midX), Double($0.maxX)] } + guidesX
        let ys: [Double] = others.flatMap { [Double($0.minY), Double($0.midY), Double($0.maxY)] } + guidesY
        if hx != 0, let d = nearest(hx < 0 ? rect.minX : rect.maxX, xs) { result.dx = d }
        if hy != 0, let d = nearest(hy < 0 ? rect.minY : rect.maxY, ys) { result.dy = d }
        var snapped = rect
        if hx < 0 { snapped.origin.x += result.dx; snapped.size.width -= result.dx }
        if hx > 0 { snapped.size.width += result.dx }
        if hy < 0 { snapped.origin.y += result.dy; snapped.size.height -= result.dy }
        if hy > 0 { snapped.size.height += result.dy }
        for o in others {
            for t in [o.minX, o.midX, o.maxX] {
                let edge = hx < 0 ? snapped.minX : snapped.maxX
                if hx != 0, abs(edge - t) < 0.01 {
                    result.guides.append(Guide(axis: .vertical, position: t, from: min(o.minY, snapped.minY), to: max(o.maxY, snapped.maxY)))
                }
            }
            for t in [o.minY, o.midY, o.maxY] {
                let edge = hy < 0 ? snapped.minY : snapped.maxY
                if hy != 0, abs(edge - t) < 0.01 {
                    result.guides.append(Guide(axis: .horizontal, position: t, from: min(o.minX, snapped.minX), to: max(o.maxX, snapped.maxX)))
                }
            }
        }
        return result
    }
}
