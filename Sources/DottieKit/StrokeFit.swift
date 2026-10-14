import Foundation
import CoreGraphics

/// Fits a sampled pen stroke with a chain of cubic Béziers (Schneider, "An Algorithm for
/// Automatically Fitting Digitized Curves", Graphics Gems). Pure arithmetic, so the same points and
/// tolerance always give the same curve.
public enum StrokeFit {
    /// Max distance, in input units, the fitted curve may stray from the samples.
    public static let tolerance: Double = 1.0
    /// Newton–Raphson re-parameterization passes tried before a segment is split.
    static let maxIterations = 4

    /// Returns `1 + 3n` control points: the start, then `c1, c2, end` per segment.
    public static func fit(_ input: [CGPoint], tolerance: Double = tolerance) -> [CGPoint] {
        var pts: [CGPoint] = []
        for p in input where pts.last.map({ $0 != p }) ?? true { pts.append(p) }
        guard let first = pts.first else { return [] }
        guard pts.count >= 2 else { return [first, first, first, first] }
        if pts.count == 2 {
            let a = pts[0], b = pts[1]
            return [a, lerp(a, b, 1.0 / 3), lerp(a, b, 2.0 / 3), b]
        }
        let t1 = normalized(pts[1] - pts[0])
        let t2 = normalized(pts[pts.count - 2] - pts[pts.count - 1])
        var out: [CGPoint] = [first]
        fitCubic(pts, 0, pts.count - 1, t1, t2, tolerance * tolerance, &out)
        return out
    }

    // MARK: Recursion

    private static func fitCubic(_ d: [CGPoint], _ first: Int, _ last: Int, _ t1: CGPoint, _ t2: CGPoint,
                                 _ errSq: Double, _ out: inout [CGPoint]) {
        if last - first == 1 {
            let dist = hypot(d[last].x - d[first].x, d[last].y - d[first].y) / 3
            out += [d[first] + t1 * dist, d[last] + t2 * dist, d[last]]
            return
        }
        var u = chordLength(d, first, last)
        var bez = generate(d, first, last, u, t1, t2)
        var (maxSq, split) = maxError(d, first, last, bez, u)
        if maxSq < errSq { out += [bez[1], bez[2], bez[3]]; return }

        if maxSq < errSq * 16 {
            for _ in 0..<maxIterations {
                u = reparameterize(d, first, last, u, bez)
                bez = generate(d, first, last, u, t1, t2)
                (maxSq, split) = maxError(d, first, last, bez, u)
                if maxSq < errSq { out += [bez[1], bez[2], bez[3]]; return }
            }
        }
        let center = normalized(d[split - 1] - d[split + 1])
        fitCubic(d, first, split, t1, center, errSq, &out)
        fitCubic(d, split, last, center * -1, t2, errSq, &out)
    }

    // MARK: Pieces

    private static func generate(_ d: [CGPoint], _ first: Int, _ last: Int, _ u: [Double],
                                 _ t1: CGPoint, _ t2: CGPoint) -> [CGPoint] {
        let p0 = d[first], p3 = d[last]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for i in 0...(last - first) {
            let t = u[i], s = 1 - t
            let b0 = s * s * s, b1 = 3 * t * s * s, b2 = 3 * t * t * s, b3 = t * t * t
            let a1 = t1 * b1, a2 = t2 * b2
            c00 += dot(a1, a1); c01 += dot(a1, a2); c11 += dot(a2, a2)
            let tmp = d[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
            x0 += dot(a1, tmp); x1 += dot(a2, tmp)
        }
        let det = c00 * c11 - c01 * c01
        let aL = det == 0 ? 0 : (x0 * c11 - x1 * c01) / det
        let aR = det == 0 ? 0 : (c00 * x1 - c01 * x0) / det
        let seg = hypot(p3.x - p0.x, p3.y - p0.y)
        let eps = 1e-6 * seg
        if aL < eps || aR < eps {
            return [p0, p0 + t1 * (seg / 3), p3 + t2 * (seg / 3), p3]
        }
        return [p0, p0 + t1 * aL, p3 + t2 * aR, p3]
    }

    private static func reparameterize(_ d: [CGPoint], _ first: Int, _ last: Int, _ u: [Double],
                                       _ b: [CGPoint]) -> [Double] {
        (0...(last - first)).map { i in
            let t = u[i]
            let q = point(b, t)
            let q1 = (b[1] - b[0]) * 3 * (1 - t) * (1 - t) + (b[2] - b[1]) * 6 * (1 - t) * t + (b[3] - b[2]) * 3 * t * t
            let q2 = (b[2] - b[1] * 2 + b[0]) * 6 * (1 - t) + (b[3] - b[2] * 2 + b[1]) * 6 * t
            let diff = q - d[first + i]
            let num = dot(diff, q1)
            let den = dot(q1, q1) + dot(diff, q2)
            return den == 0 ? t : min(1, max(0, t - num / den))
        }
    }

    private static func maxError(_ d: [CGPoint], _ first: Int, _ last: Int, _ b: [CGPoint],
                                 _ u: [Double]) -> (Double, Int) {
        var split = (last - first + 1) / 2 + first
        var worst = 0.0
        for i in (first + 1)..<last {
            let v = point(b, u[i - first]) - d[i]
            let sq = dot(v, v)
            if sq >= worst { worst = sq; split = i }
        }
        // A split on an endpoint would recurse forever; keep it strictly interior.
        return (worst, min(max(split, first + 1), last - 1))
    }

    private static func chordLength(_ d: [CGPoint], _ first: Int, _ last: Int) -> [Double] {
        var u = [0.0]
        for i in (first + 1)...last {
            u.append(u[u.count - 1] + hypot(d[i].x - d[i - 1].x, d[i].y - d[i - 1].y))
        }
        let total = u[u.count - 1]
        return total == 0 ? u : u.map { $0 / total }
    }

    static func point(_ b: [CGPoint], _ t: Double) -> CGPoint {
        let s = 1 - t
        return b[0] * (s * s * s) + b[1] * (3 * t * s * s) + b[2] * (3 * t * t * s) + b[3] * (t * t * t)
    }

    private static func normalized(_ v: CGPoint) -> CGPoint {
        let l = hypot(v.x, v.y)
        return l == 0 ? .zero : CGPoint(x: v.x / l, y: v.y / l)
    }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> Double { a.x * b.x + a.y * b.y }
    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { a + (b - a) * t }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func * (a: CGPoint, s: Double) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }

extension Element {
    /// Replace the raw pen samples with a fitted Bézier chain, stored flat and normalized to the frame.
    /// No-op for anything but a freehand stroke that still carries raw points.
    public mutating func fitStroke() {
        guard kind == .freehand, let raw = points, !raw.isEmpty else { return }
        let r = frame
        let abs = raw.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }
        let fitted = StrokeFit.fit(abs)
        func n(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        path = fitted.flatMap { [n(($0.x - r.minX) / r.width), n(($0.y - r.minY) / r.height)] }
        points = nil
    }
}
