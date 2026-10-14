import Foundation
import CoreGraphics

/// Small deterministic PRNG (SplitMix64) so the same seed always yields the same sketch.
public struct SeededRNG: Sendable {
    private var state: UInt64
    public init(seed: UInt32) { state = UInt64(seed) &+ 0x9E3779B97F4A7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in -1...1
    public mutating func signed() -> Double { Double(next() >> 11) / Double(1 << 52) - 1 }
    /// Uniform in 0...1
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// rough.js-style sketchy path generation.
public enum Rough {
    static func offset(_ rng: inout SeededRNG, _ amount: Double, _ roughness: Double) -> Double {
        rng.signed() * amount * roughness
    }

    /// - Parameters:
    ///   - bowing: scales the sideways bow of the stroke, independent of `roughness`. 0 is straight but shaky.
    ///   - preserveEnds: keep both endpoints exact (jitter only the middle), so a connector still touches its shape.
    public static func line(_ a: CGPoint, _ b: CGPoint, rng: inout SeededRNG, roughness: Double,
                            bowing: Double = 1, preserveEnds: Bool = false, into path: CGMutablePath) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        // rough.js: jitter fades on long lines, and short ones never wobble by more than a tenth of their length.
        let gain = length < 200 ? 1 : length > 500 ? 0.4 : -0.0016668 * length + 1.233334
        let maxOff = length < 20 ? length / 10 : 2.0
        // Two passes give the characteristic doubled stroke; the retrace stays tighter than the first pass.
        for pass in 0..<2 {
            let spread = (pass == 0 ? 1.0 : 0.5) * gain
            func j() -> CGFloat { CGFloat(offset(&rng, maxOff, roughness) * spread) }
            let mid = rng.unit() * 0.4 + 0.3
            let bow = CGFloat(offset(&rng, length / 60, roughness) * bowing * gain)
            let dx = b.x - a.x, dy = b.y - a.y
            let nx = -dy / length, ny = dx / length
            let start = preserveEnds ? a : CGPoint(x: a.x + j(), y: a.y + j())
            let end = preserveEnds ? b : CGPoint(x: b.x + j(), y: b.y + j())
            let c1 = CGPoint(x: a.x + dx * CGFloat(mid) * 0.66 + nx * bow + j() * 0.5,
                             y: a.y + dy * CGFloat(mid) * 0.66 + ny * bow + j() * 0.5)
            let c2 = CGPoint(x: a.x + dx * (0.5 + CGFloat(mid) * 0.5) + nx * bow + j() * 0.5,
                             y: a.y + dy * (0.5 + CGFloat(mid) * 0.5) + ny * bow + j() * 0.5)
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
        }
    }

    public static func polygon(_ pts: [CGPoint], rng: inout SeededRNG, roughness: Double, bowing: Double = 1) -> CGPath {
        let path = CGMutablePath()
        for i in pts.indices {
            line(pts[i], pts[(i + 1) % pts.count], rng: &rng, roughness: roughness, bowing: bowing, into: path)
        }
        return path
    }

    public static func ellipse(in rect: CGRect, rng: inout SeededRNG, roughness: Double) -> CGPath {
        let path = CGMutablePath()
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0.5, ry > 0.5 else { return path }
        let n = max(8, min(24, Int((rx + ry) / 6)))
        let wobble = min(2.5, (rx + ry) / 25) * roughness
        for pass in 0..<2 {
            let phase = rng.unit() * 2 * .pi
            // Overshoot the closing point a little on the second pass, like a real pen.
            let sweep = 2 * Double.pi * (pass == 0 ? 1.0 : 1.04)
            let count = Int(Double(n) * sweep / (2 * .pi)) + 1
            var pts: [CGPoint] = []
            for i in 0..<count {
                let t = phase + sweep * Double(i) / Double(n)
                let wx = CGFloat(rng.signed() * wobble), wy = CGFloat(rng.signed() * wobble)
                pts.append(CGPoint(x: cx + rx * CGFloat(cos(t)) + wx, y: cy + ry * CGFloat(sin(t)) + wy))
            }
            addCatmullRom(pts, to: path)
        }
        return path
    }

    static func addCatmullRom(_ p: [CGPoint], to path: CGMutablePath) {
        guard p.count > 2 else { return }
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }
}

/// Hachure fill: parallel scanlines clipped to a polygon, as rough.js draws a pen-shaded fill.
public enum Hachure {
    /// rough.js's default hachure angle.
    public static let angle = -41.0 * Double.pi / 180

    /// Segments of parallel lines `gap` apart at `angle` (radians) that lie inside `polygon`.
    /// Deterministic, and aligned to the polygon so the pattern doesn't swim when it is resized.
    public static func lines(in polygon: [CGPoint], angle: Double = angle, gap: Double) -> [(CGPoint, CGPoint)] {
        lines(in: [polygon], angle: angle, gap: gap)
    }

    /// Several contours at once, filled even-odd, so a contour inside another is a hole.
    public static func lines(in polygons: [[CGPoint]], angle: Double = angle, gap: Double) -> [(CGPoint, CGPoint)] {
        guard gap > 0 else { return [] }
        let c = cos(angle), s = sin(angle)
        // Rotate so the hatch direction is horizontal.
        let rots = polygons.filter { $0.count >= 3 }.map { poly in
            poly.map { CGPoint(x: $0.x * c + $0.y * s, y: -$0.x * s + $0.y * c) }
        }
        guard let minY = rots.joined().map(\.y).min(), let maxY = rots.joined().map(\.y).max() else { return [] }
        func back(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * c - y * s, y: x * s + y * c) }
        var out: [(CGPoint, CGPoint)] = []
        var y = minY + gap / 2
        while y < maxY {
            var xs: [Double] = []
            for rot in rots {
                for i in rot.indices {
                    let a = rot[i], b = rot[(i + 1) % rot.count]
                    if (a.y <= y && y < b.y) || (b.y <= y && y < a.y) {
                        xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
                    }
                }
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                if xs[k + 1] - xs[k] > 0.5 { out.append((back(xs[k], y), back(xs[k + 1], y))) }
                k += 2
            }
            y += gap
        }
        return out
    }
}
