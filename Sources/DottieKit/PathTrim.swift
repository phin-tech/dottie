import Foundation
import CoreGraphics

extension CGPath {
    /// Every contour as points, curves flattened into short segments.
    var contours: [[CGPoint]] {
        var out: [[CGPoint]] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        applyWithBlock { el in
            let e = el.pointee, p = e.points
            let last = current.last ?? start
            switch e.type {
            case .moveToPoint:
                if current.count > 1 { out.append(current) }
                start = p[0]; current = [p[0]]
            case .addLineToPoint: current.append(p[0])
            case .addQuadCurveToPoint:
                for i in 1...12 {
                    let t = CGFloat(i) / 12, u = 1 - t
                    current.append(CGPoint(x: u*u*last.x + 2*u*t*p[0].x + t*t*p[1].x, y: u*u*last.y + 2*u*t*p[0].y + t*t*p[1].y))
                }
            case .addCurveToPoint:
                for i in 1...16 {
                    let t = CGFloat(i) / 16, u = 1 - t
                    current.append(CGPoint(x: u*u*u*last.x + 3*u*u*t*p[0].x + 3*u*t*t*p[1].x + t*t*t*p[2].x,
                                           y: u*u*u*last.y + 3*u*u*t*p[0].y + 3*u*t*t*p[1].y + t*t*t*p[2].y))
                }
            case .closeSubpath:
                current.append(start)
                if current.count > 1 { out.append(current) }
                current = [start]
            @unknown default: break
            }
        }
        if current.count > 1 { out.append(current) }
        return out
    }

    /// The first `fraction` of the path by length, contours in drawing order: a stroke being drawn on.
    func trimmed(to fraction: Double) -> CGPath {
        let lines = contours.map(Polyline.init)
        var left = CGFloat(min(max(fraction, 0), 1)) * lines.reduce(0) { $0 + $1.length }
        let out = CGMutablePath()
        for line in lines where left > 0 {
            out.move(to: line.points[0])
            for i in 1..<line.points.count {
                let seg = line.lengths[i] - line.lengths[i - 1]
                if seg <= left { out.addLine(to: line.points[i]); left -= seg; continue }
                let a = line.points[i - 1], b = line.points[i], f = left / seg
                out.addLine(to: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                left = 0
                break
            }
        }
        return out
    }
}

extension Element {
    /// The stroke progress to draw, or nil when the element is fully drawn.
    var revealProgress: Double? { reveal.flatMap { $0 < 1 ? max(0, $0) : nil } }

    /// `text` cut to the part typed out so far.
    func typed(_ s: String, _ progress: Double) -> String {
        String(s.prefix(Int((Double(s.count) * progress).rounded(.down))))
    }
}
