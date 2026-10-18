import Foundation
import CoreGraphics

/// The outline of a `.path` as straight segments, for connectors and labels that follow the drawing rather than
/// its bounding box. dottie.js does the same thing (web/src/connector.ts); the two must agree, since goldens are
/// shared.
extension Element {
    /// Curve segments are flattened into this many straight steps each.
    static let outlineStepsPerCurve = 16

    /// Where a line coming in from `c + d` toward the center `c` first meets the drawing, in the element's own
    /// (unrotated) frame; nil when the ray misses every contour. That is the crossing farthest from `c` that is not
    /// past `c + d`, so lines inside the shape (a cylinder's rims, a hole) never catch the connector. When the far
    /// end is inside the shape and no crossing comes before it, the nearest crossing ahead of `c` is used.
    func outlineCrossing(from c: CGPoint, along d: CGPoint) -> CGPoint? {
        var nearest: CGFloat?, farthest: CGFloat?
        func test(_ a: CGPoint, _ b: CGPoint) {
            let e = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let denominator = d.x * e.y - d.y * e.x // cross(d, e): zero when the ray and the segment are parallel
            guard denominator != 0 else { return }
            let ac = CGPoint(x: a.x - c.x, y: a.y - c.y)
            // c + t·d = a + s·e, solved with cross products.
            let t = (ac.x * e.y - ac.y * e.x) / denominator
            let s = (ac.x * d.y - ac.y * d.x) / denominator
            guard t > 0, s >= 0, s <= 1 else { return }
            if nearest == nil || t < nearest! { nearest = t }
            if t <= 1, farthest == nil || t > farthest! { farthest = t }
        }
        for contour in shapeContours {
            let points = Element.flatten(contour)
            for i in 1..<max(points.count, 1) { test(points[i - 1], points[i]) }
            if contour.closed, let first = points.first, let last = points.last { test(last, first) }
        }
        guard let t = farthest ?? nearest else { return nil }
        return CGPoint(x: c.x + d.x * t, y: c.y + d.y * t)
    }

    /// A contour's Bézier points as a polyline: each curve's start, then 16 steps along it, then the last point.
    private static func flatten(_ contour: Contour) -> [CGPoint] {
        let p = contour.points
        guard p.count >= 4 else { return p }
        var out: [CGPoint] = []
        for seg in 0..<((p.count - 1) / 3) {
            let p0 = p[3 * seg], p1 = p[3 * seg + 1], p2 = p[3 * seg + 2], p3 = p[3 * seg + 3]
            for k in 0..<outlineStepsPerCurve {
                let t = CGFloat(k) / CGFloat(outlineStepsPerCurve), u = 1 - t
                out.append(CGPoint(
                    x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
                    y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y))
            }
        }
        out.append(p[p.count - 1])
        return out
    }

    /// Where a shape's own text goes: its `labelRect` when an extension shape gives one, otherwise the frame inset
    /// by 6 points.
    public var labelFrame: CGRect {
        guard kind == .path, let l = labelRect else { return frame.insetBy(dx: 6, dy: 6) }
        return CGRect(x: frame.minX + l.x * frame.width, y: frame.minY + l.y * frame.height,
                      width: l.width * frame.width, height: l.height * frame.height)
    }
}
