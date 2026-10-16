import Foundation
import CoreGraphics

/// The geometry contract between Dottie and dottie.js: what a page resolves to at a moment, with no drawing.
/// `dottie inspect` prints it and `just goldens` stores it for the fixtures in `fixtures/`; dottie.js computes
/// the same structure and its tests compare the two, number by number.
public enum Inspector {
    /// Times worth checking on an animated page: evenly spaced across it, off the frame grid, plus each
    /// scene, the poster and both ends. A still page has just 0.
    public static func sampleTimes(_ doc: DottieDocument) -> [Double] {
        guard let tl = doc.timeline else { return [0] }
        let d = tl.duration
        var times: [Double] = [0, d]
        for i in 1..<16 { times.append(d * (Double(i) + 0.37) / 16) }
        for m in tl.markers ?? [] { times.append(m.t) }
        if let p = tl.poster { times.append(p) }
        return Array(Set(times.map(round4))).filter { $0 >= 0 && $0 <= d }.sorted()
    }

    /// One page at each of `times`, plus what doesn't depend on time.
    public static func page(_ doc: DottieDocument, index: Int, times: [Double]) -> [String: Any] {
        var out: [String: Any] = ["page": index + 1, "name": doc.name, "id": doc.id.uuidString]
        if let tl = doc.timeline, let plan = Exporter.animation(doc) {
            out["duration"] = num(tl.duration)
            out["fps"] = num(tl.fps)
            out["frameCount"] = plan.times.count
            out["poster"] = num(tl.poster ?? tl.duration)
            out["size"] = [num(plan.size.width), num(plan.size.height)]
            // Without a camera every frame shows the same rectangle: the bounds of the whole animation.
            if tl.camera?.isEmpty ?? true, let r = plan.rects.first { out["bounds"] = rect(r) }
            out["markers"] = (tl.markers ?? []).map { ["t": num($0.t), "name": $0.name] as [String: Any] }
        } else {
            out["bounds"] = rect(Exporter.bounds(of: doc))
        }
        out["frames"] = times.map { frame(doc, at: $0) }
        return out
    }

    /// The page posed at `t`: each element drawn, in drawing order, and where the camera looks.
    public static func frame(_ doc: DottieDocument, at t: Double) -> [String: Any] {
        let f = doc.resolved(at: t)
        let index = f.elementIndex
        let visible = Set(f.layers.filter(\.visible).map(\.id))
        var out: [String: Any] = ["t": num(t)]
        if let tl = doc.timeline {
            out["view"] = tl.cameraView(at: t).map(rect) ?? NSNull()
            out["scene"] = (tl.markers ?? []).lastIndex { $0.t <= t } ?? -1
        }
        if doc.timeline?.camera?.isEmpty ?? true { out["bounds"] = rect(Exporter.bounds(of: f)) }
        out["elements"] = f.orderedElements.enumerated().map { z, e -> [String: Any] in
            var d: [String: Any] = ["id": e.id.uuidString, "kind": e.kind.rawValue, "z": z, "seed": e.seed,
                                    "frame": rect(e.frame)]
            if !visible.contains(e.layerID) { d["hiddenLayer"] = true }
            if let r = e.rotation { d["rotation"] = num(r) }
            if let o = e.style.opacity { d["opacity"] = num(o) }
            if let r = e.reveal { d["reveal"] = num(r) }
            d["strokeWidth"] = num(e.style.strokeWidth)
            d["stroke"] = color(e.style.stroke)
            d["fill"] = color(e.style.fill)
            if e.kind == .connector {
                let (a, b) = Connector.endpoints(of: e, in: f, index: index)
                d["start"] = point(a)
                d["end"] = point(b)
                d["route"] = Connector.route(of: e, in: f, index: index).points.map(point)
            }
            return d
        }
        return out
    }

    /// A whole file: every page at its sample times (or at `times` when given).
    public static func file(_ file: DottieFile, pages: [Int]? = nil, times: [Double]? = nil) -> [String: Any] {
        let which = pages ?? Array(file.pages.indices)
        return ["version": file.version, "pages": which.map { i in
            page(file.pages[i], index: i, times: times ?? sampleTimes(file.pages[i]))
        }]
    }

    /// Sorted-key JSON with one element per line, so goldens diff well: anything that holds no objects is
    /// written on one line.
    public static func json(_ value: Any) throws -> Data {
        Data((write(value, indent: "") + "\n").utf8)
    }

    private static func write(_ v: Any, indent: String) -> String {
        func holdsObjects(_ v: Any) -> Bool {
            if v is [String: Any] { return true }
            if let a = v as? [Any] { return a.contains(where: holdsObjects) }
            return false
        }
        let inner = indent + "  "
        switch v {
        case let d as [String: Any]:
            if d.isEmpty { return "{}" }
            let keys = d.keys.sorted()
            if !d.values.contains(where: holdsObjects) {
                return "{" + keys.map { "\(string($0)): \(write(d[$0]!, indent: inner))" }.joined(separator: ", ") + "}"
            }
            return "{\n" + keys.map { "\(inner)\(string($0)): \(write(d[$0]!, indent: inner))" }.joined(separator: ",\n") + "\n\(indent)}"
        case let a as [Any]:
            if a.isEmpty { return "[]" }
            if !a.contains(where: holdsObjects) { return "[" + a.map { write($0, indent: inner) }.joined(separator: ", ") + "]" }
            return "[\n" + a.map { inner + write($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case let s as String: return string(s)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let u as UInt32: return String(u)
        case let x as Double:
            return x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x)
        case is NSNull: return "null"
        default: return "null"
        }
    }

    private static func string(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
    static func num(_ v: Double) -> Double { round4(v) == 0 ? 0 : round4(v) }   // no -0
    static func num(_ v: CGFloat) -> Double { num(Double(v)) }
    static func point(_ p: CGPoint) -> [Double] { [num(p.x), num(p.y)] }
    static func rect(_ r: CGRect) -> [Double] { [num(r.minX), num(r.minY), num(r.width), num(r.height)] }
    static func color(_ c: RGBA) -> [Double] { [num(c.r), num(c.g), num(c.b), num(c.a)] }
}
