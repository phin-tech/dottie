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

    public static func line(_ a: CGPoint, _ b: CGPoint, rng: inout SeededRNG, roughness: Double, into path: CGMutablePath) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        let maxOff = min(2.0, max(0.6, length / 10))
        // Two passes with different jitter give the characteristic doubled stroke.
        for pass in 0..<2 {
            let spread = pass == 0 ? 1.0 : 1.4
            func j() -> CGFloat { CGFloat(offset(&rng, maxOff, roughness) * spread) }
            let mid = rng.unit() * 0.4 + 0.3
            let bow = CGFloat(offset(&rng, length / 60, roughness))
            let dx = b.x - a.x, dy = b.y - a.y
            let nx = -dy / length, ny = dx / length
            let start = CGPoint(x: a.x + j(), y: a.y + j())
            let end = CGPoint(x: b.x + j(), y: b.y + j())
            let c1 = CGPoint(x: a.x + dx * CGFloat(mid) * 0.66 + nx * bow + j() * 0.5,
                             y: a.y + dy * CGFloat(mid) * 0.66 + ny * bow + j() * 0.5)
            let c2 = CGPoint(x: a.x + dx * (0.5 + CGFloat(mid) * 0.5) + nx * bow + j() * 0.5,
                             y: a.y + dy * (0.5 + CGFloat(mid) * 0.5) + ny * bow + j() * 0.5)
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
        }
    }

    public static func polygon(_ pts: [CGPoint], rng: inout SeededRNG, roughness: Double) -> CGPath {
        let path = CGMutablePath()
        for i in pts.indices {
            line(pts[i], pts[(i + 1) % pts.count], rng: &rng, roughness: roughness, into: path)
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
