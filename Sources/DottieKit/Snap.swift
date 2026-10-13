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

    public struct Result: Equatable, Sendable {
        public var dx: Double = 0
        public var dy: Double = 0
        public var guides: [Guide] = []
    }

    public static func grid(_ v: Double, size: Double) -> Double { size > 0 ? (v / size).rounded() * size : v }

    /// Offset that aligns `moving`'s edges or center with `others`' edges or centers within
    /// `threshold`; falls back to the grid on an axis with no object match.
    public static func move(_ moving: CGRect, others: [CGRect], threshold: Double, gridSize: Double? = nil) -> Result {
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

        if let hit = best(xs(moving), xs) {
            result.dx = hit.delta
        } else if let g = gridSize, g > 0 {
            result.dx = grid(moving.minX, size: g) - moving.minX
        }
        if let hit = best(ys(moving), ys) {
            result.dy = hit.delta
        } else if let g = gridSize, g > 0 {
            result.dy = grid(moving.minY, size: g) - moving.minY
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
}
