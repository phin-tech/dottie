import Foundation
import CoreGraphics

/// Editing a committed pen stroke: reading and moving its Bézier control points, and erasing.
extension Element {
    /// Absolute control points of a committed stroke: `1 + 3n` of them (start, then c1, c2, end per segment).
    public var strokeControlPoints: [CGPoint]? {
        guard kind == .freehand, let flat = path, flat.count >= 8, (flat.count - 2) % 6 == 0 else { return nil }
        let r = frame
        return stride(from: 0, to: flat.count, by: 2).map {
            CGPoint(x: r.minX + flat[$0] * r.width, y: r.minY + flat[$0 + 1] * r.height)
        }
    }

    /// Points along the stroke, spaced at most `maxStep` apart.
    public func flattenedStroke(maxStep: Double = 4) -> [CGPoint] {
        guard let cp = strokeControlPoints else { return [] }
        return Element.flatten(cp, maxStep: maxStep)
    }

    static func flatten(_ cp: [CGPoint], maxStep: Double) -> [CGPoint] {
        var out: [CGPoint] = [cp[0]]
        for s in 0..<((cp.count - 1) / 3) {
            let seg = Array(cp[(3 * s)...(3 * s + 3)])
            let hull = zip(seg, seg.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.reduce(0, +)
            let n = min(400, max(4, Int((hull / max(maxStep, 0.5)).rounded(.up))))
            for k in 1...n { out.append(StrokeFit.point(seg, Double(k) / Double(n))) }
        }
        return out
    }

    /// Replaces the stroke's control points, re-fitting the frame to the new curve.
    public mutating func setStrokeControlPoints(_ cp: [CGPoint]) {
        guard kind == .freehand, cp.count >= 4, (cp.count - 1) % 3 == 0 else { return }
        let samples = Element.flatten(cp, maxStep: 8)
        let xs = samples.map(\.x), ys = samples.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 1), height: max(ys.max()! - ys.min()!, 1))
        func n(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        frame = box
        path = cp.flatMap { [n(($0.x - box.minX) / box.width), n(($0.y - box.minY) / box.height)] }
        points = nil
    }

    /// Moves one control point. An anchor (index % 3 == 0) carries its two handles with it, so the
    /// curve keeps its shape around the point; a handle moves alone.
    public mutating func moveStrokeControlPoint(_ index: Int, to p: CGPoint) {
        guard var cp = strokeControlPoints, cp.indices.contains(index) else { return }
        let d = CGPoint(x: p.x - cp[index].x, y: p.y - cp[index].y)
        cp[index] = p
        if index % 3 == 0 {
            for j in [index - 1, index + 1] where cp.indices.contains(j) {
                cp[j] = CGPoint(x: cp[j].x + d.x, y: cp[j].y + d.y)
            }
        }
        setStrokeControlPoints(cp)
    }
}

extension DottieDocument {
    /// Eraser: cuts the parts of pen strokes within `radius` of `p` (the remainder is re-fitted, and a
    /// stroke split in two becomes two strokes) and removes any other shape the point touches.
    /// Returns the ids of removed elements and true if anything changed.
    @discardableResult
    public mutating func erase(at p: CGPoint, radius: Double) -> Bool {
        let editable = Set(layers.filter { $0.visible && !$0.locked }.map(\.id))
        var changed = false
        var removed = Set<UUID>()
        var result: [Element] = []
        for e in elements {
            guard editable.contains(e.layerID) else { result.append(e); continue }
            if e.kind == .freehand {
                guard e.frame.insetBy(dx: -radius - 2, dy: -radius - 2).contains(p) else { result.append(e); continue }
                let samples = e.flattenedStroke(maxStep: max(1, radius / 2))
                guard !samples.isEmpty else { result.append(e); continue }
                let hit = samples.map { hypot($0.x - p.x, $0.y - p.y) <= radius }
                guard hit.contains(true) else { result.append(e); continue }
                changed = true
                var runs: [[CGPoint]] = [], run: [CGPoint] = []
                for (pt, h) in zip(samples, hit) {
                    if h { if run.count >= 2 { runs.append(run) }; run = [] } else { run.append(pt) }
                }
                if run.count >= 2 { runs.append(run) }
                if runs.isEmpty { removed.insert(e.id); continue }
                for (k, r) in runs.enumerated() {
                    var piece = e
                    if k > 0 { piece.id = UUID(); piece.seed = .random(in: 1...UInt32.max) }
                    let xs = r.map(\.x), ys = r.map(\.y)
                    let box = CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 1), height: max(ys.max()! - ys.min()!, 1))
                    piece.frame = box
                    piece.points = r.map { StrokePoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) }
                    piece.path = nil
                    piece.fitStroke()
                    result.append(piece)
                }
            } else {
                let touches = e.kind == .connector
                    ? Connector.distance(from: p, to: e, in: self) <= max(radius, 4)
                    : e.frame.insetBy(dx: -2, dy: -2).contains(p)
                if touches { removed.insert(e.id); changed = true } else { result.append(e) }
            }
        }
        guard changed else { return false }
        elements = result
        if !removed.isEmpty { remove(removed) }
        return true
    }
}
