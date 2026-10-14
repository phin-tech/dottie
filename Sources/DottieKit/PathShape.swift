import Foundation
import CoreGraphics

/// Reading and writing the contours of a `.path` element.
extension Element {
    /// A contour in canvas coordinates: `1 + 3n` Bézier points (start, then c1, c2, end per segment).
    struct Contour {
        var closed: Bool
        var points: [CGPoint]
    }

    var shapeContours: [Contour] {
        guard kind == .path, let subs = subpaths else { return [] }
        let r = frame
        return subs.compactMap { s in
            guard s.coords.count >= 8, (s.coords.count - 2) % 6 == 0 else { return nil }
            let pts = stride(from: 0, to: s.coords.count, by: 2).map {
                CGPoint(x: r.minX + s.coords[$0] * r.width, y: r.minY + s.coords[$0 + 1] * r.height)
            }
            return Contour(closed: s.closed, points: pts)
        }
    }

    /// The exact (not sketchy) geometry of a `.path`, in canvas coordinates.
    var shapePath: CGPath {
        let path = CGMutablePath()
        for c in shapeContours {
            path.move(to: c.points[0])
            for k in 0..<((c.points.count - 1) / 3) {
                path.addCurve(to: c.points[3 * k + 3], control1: c.points[3 * k + 1], control2: c.points[3 * k + 2])
            }
            if c.closed { path.closeSubpath() }
        }
        return path
    }

    /// A `.path` element drawing `path` (canvas coordinates) in its own bounding box.
    public static func shape(_ path: CGPath, style: Style = Style(), seed: UInt32 = .random(in: 1...UInt32.max),
                             layerID: UUID, groupID: UUID? = nil) -> Element? {
        // Absolute contours first, with every segment as a cubic; the frame comes from the curves themselves
        // because CGPath's own bounding box is not exact for all segment types.
        var contours: [Contour] = []
        var pts: [CGPoint] = []
        var start = CGPoint.zero
        func flush(closed: Bool) {
            if pts.count >= 4 { contours.append(Contour(closed: closed, points: pts)) }
            pts = []
        }
        path.applyWithBlock { el in
            let p = el.pointee.points
            let cur = pts.last ?? start
            switch el.pointee.type {
            case .moveToPoint:
                flush(closed: false); start = p[0]; pts = [p[0]]
            case .addLineToPoint:
                pts += [cur, p[0], p[0]] // c1 on the start, c2 on the end: a straight segment
            case .addQuadCurveToPoint:
                let c = p[0], e = p[1]
                pts += [CGPoint(x: cur.x + 2 / 3 * (c.x - cur.x), y: cur.y + 2 / 3 * (c.y - cur.y)),
                        CGPoint(x: e.x + 2 / 3 * (c.x - e.x), y: e.y + 2 / 3 * (c.y - e.y)), e]
            case .addCurveToPoint:
                pts += [p[0], p[1], p[2]]
            case .closeSubpath:
                guard !pts.isEmpty else { break }
                if cur != start { pts += [cur, start, start] }
                flush(closed: true)
                pts = [start] // a segment after a close continues from the contour's start
            @unknown default: break
            }
        }
        flush(closed: false)
        guard !contours.isEmpty else { return nil }

        let samples = contours.flatMap { flatten($0.points, maxStep: 2) }
        guard let minX = samples.map(\.x).min(), let maxX = samples.map(\.x).max(),
              let minY = samples.map(\.y).min(), let maxY = samples.map(\.y).max(),
              minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else { return nil }
        let frame = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        func n(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        var e = Element(kind: .path, frame: frame, style: style, seed: seed, layerID: layerID, groupID: groupID)
        e.subpaths = contours.map { c in
            PathSubpath(closed: c.closed, coords: c.points.flatMap {
                [n(($0.x - frame.minX) / frame.width), n(($0.y - frame.minY) / frame.height)]
            })
        }
        return e
    }
}
