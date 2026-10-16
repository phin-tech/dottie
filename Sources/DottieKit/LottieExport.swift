import Foundation
import CoreGraphics
import CoreText

extension Exporter {
    /// How a Lottie export draws motion.
    public enum LottieMode: String, Sendable, CaseIterable {
        /// Sampled at 30 frames a second or more and tweened by the player in between, with lines held
        /// steady (no boil): smooth and small.
        case smooth
        /// Every frame exactly as the GIF draws it, boil included, each held until the next.
        case exact
    }

    /// The page's animation as Lottie JSON (Bodymovin 5), for lottie-web and the Lottie players on iOS and
    /// Android. Everything is vector: shapes and sketchy strokes as paths, text as glyph outlines, pictures as
    /// embedded images, the camera as a parent layer. A page without a timeline is a one-frame animation.
    /// nil when the animation is too long to export (see `maxAnimationFrames`).
    public static func lottie(_ doc: DottieDocument, mode: LottieMode = .smooth, scale: Double = 1,
                              transparent: Bool = false, name: String = "Dottie animation") -> Data? {
        guard !animationTooLong(doc) else { return nil }
        return Data(LottieWriter(doc, mode: mode, scale: scale, transparent: transparent).write(name: name).utf8)
    }
}

/// One thing a layer draws: a set of contours, filled or stroked.
struct LottieItem {
    struct Contour: Equatable {
        var closed: Bool
        var v: [CGPoint], i: [CGPoint], o: [CGPoint]
    }
    var fill: Bool
    var evenOdd = false
    var color: RGBA
    var width = 0.0
    /// Dash, gap and offset for a dashed stroke.
    var dash: [Double]?
    /// How much of the stroke is drawn, 0...1, while it is being drawn on (a Trim Paths end).
    var trim: Double?
    var contours: [Contour]

    /// What has to stay the same for one sample to tween into the next.
    var shape: [Int] {
        [fill ? 1 : 0, evenOdd ? 1 : 0, dash == nil ? 0 : 1, trim == nil ? 0 : 1] + contours.flatMap { [$0.closed ? 1 : 0, $0.v.count] }
    }
}

final class LottieWriter {
    let mode: Exporter.LottieMode
    let fr: Double
    let times: [Double]
    /// Seconds at which the animation ends (the last sample shows until then).
    let end: Double
    let frames: [DottieDocument]
    let indexes: [[UUID: Element]]
    let base: DottieDocument
    let background: RGBA?
    let scale: Double
    private var nextIndex = 2
    private var assets: [[String: Any]] = []
    private var assetIDs: [Data: String] = [:]

    init(_ doc: DottieDocument, mode: Exporter.LottieMode, scale: Double, transparent: Bool) {
        self.mode = mode
        self.scale = min(max(scale.isFinite ? scale : 1, 0.1), 8)
        let tl = doc.timeline
        let fps = tl.map { Timeline.clampFPS($0.fps) } ?? 12
        var source = doc
        switch mode {
        case .exact:
            fr = fps
            times = tl?.frameTimes ?? [0]
        case .smooth:
            let rate = min(60, max(30, fps))
            fr = rate
            source.timeline?.boil = nil
            let d = Timeline.clampTime(tl?.duration ?? 0)
            let n = Int((d * rate - 1e-9).rounded(.up))
            times = n <= 0 ? [0] : (0...n).map { min(d, Double($0) / rate) }
        }
        end = (times.last ?? 0) + 1 / fps
        let theme = doc.resolvedTheme
        base = doc.resolvingInk(to: theme?.ink ?? .black)
        frames = times.map { source.resolved(at: $0).resolvingInk(to: theme?.ink ?? .black) }
        indexes = frames.map(\.elementIndex)
        background = transparent ? nil : theme?.background ?? RGBA(r: 1, g: 1, b: 1)
    }

    private func frame(_ t: Double) -> Double { t * fr }
    private var lastFrame: Double { end * fr }

    // MARK: The composition

    func write(name: String) -> String {
        let (rects, size) = views()
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        // The camera: a parent for every drawn layer, mapping the page's view at each moment onto the frame.
        var camera: [String: Any] = layer(1, type: 3, name: "camera", ip: 0, op: lastFrame, ks: transform(
            anchor: vector(rects.map { [Double($0.minX), Double($0.minY)] }, times),
            scale: vector(rects.map { [Double(w) / Double($0.width) * 100, Double(w) / Double($0.width) * 100] }, times)))

        camera.removeValue(forKey: "parent")
        var drawn: [[String: Any]] = []   // back to front
        if let background {
            var page = layer(nextLayer(), type: 1, name: "page", ip: 0, op: lastFrame, ks: transform())
            page["sw"] = w; page["sh"] = h; page["sc"] = hex(background)
            page.removeValue(forKey: "parent")
            drawn.append(page)
        }
        drawn += pathRuns(name: "rock") { i in
            let visible = Set(frames[i].layers.filter(\.visible).map(\.id))
            let floors = frames[i].orderedElements.filter { visible.contains($0.layerID) && DungeonGrid.isFloor($0) }
            let rock = DungeonGrid.rock(for: floors)
            return rock.isEmpty ? nil : (rock.map { r in
                LottieItem(fill: false, color: r.ink, width: r.width, contours: Self.contours(r.path))
            }, 1)
        }
        for e in base.orderedElements { drawn += element(e.id) }

        let doc: [String: Any] = [
            "v": "5.7.4", "fr": fr, "ip": 0, "op": lastFrame, "w": w, "h": h, "nm": name, "ddd": 0,
            "assets": assets, "layers": [camera] + drawn.reversed(), "markers": [Any](),
        ]
        return Self.json(doc) + "\n"
    }

    /// The part of the page shown at each sample, and the size of the output (Exporter.animation).
    private func views() -> ([CGRect], CGSize) {
        if let tl = base.timeline, let first = tl.camera?.first(where: { $0.width > 1 && $0.height > 1 }) {
            let rects = times.map { tl.cameraView(at: $0) ?? first.rect }
            let width = min(Double(rects.map(\.width).max() ?? CGFloat(first.width)), 4096)
            return (rects, CGSize(width: width, height: width * first.height / first.width))
        }
        var b = CGRect.null
        for f in frames where !f.elements.isEmpty { b = b.union(Exporter.bounds(of: f)) }
        if b.isNull { b = Exporter.bounds(of: frames[0]) }
        return (Array(repeating: b, count: times.count), b.size)
    }

    private func nextLayer() -> Int { defer { nextIndex += 1 }; return nextIndex }

    // MARK: Elements

    /// The layers drawing one element over the whole animation.
    private func element(_ id: UUID) -> [[String: Any]] {
        let name = "e-\(id.uuidString)"
        func posed(_ i: Int) -> Element? {
            guard let e = indexes[i][id], (e.style.opacity ?? 1) > 0,
                  frames[i].layers.first(where: { $0.id == e.layerID })?.visible ?? true else { return nil }
            return e
        }
        var out: [[String: Any]] = []
        if base.elementIndex[id]?.kind == .image { out += pictureLayers(id, name, posed) }
        func sample(_ i: Int) -> ([LottieItem], Double)? {
            posed(i).map { e in (Self.items(of: e, in: frames[i], index: indexes[i], background: background), e.style.opacity ?? 1) }
        }
        for run in runs(of: times.indices.map(posed)) {
            let indices = Set(run.map(\.0))
            if mode == .smooth, let l = restLayer(id, name, run, sample) { out.append(l); continue }
            out += pathRuns(name: name) { indices.contains($0) ? sample($0) : nil }
        }
        return out
    }

    /// Smooth mode's small layer for a shape: drawn once at rest, moved, sized and turned by its transform,
    /// its colors and line widths keyed. nil when the shape's look changes in a way a transform can't carry
    /// (drawing on, a fill appearing), or it isn't a plain shape.
    private func restLayer(_ id: UUID, _ name: String, _ run: [(Int, Element)], _ sample: (Int) -> ([LottieItem], Double)?) -> [String: Any]? {
        guard var rest = base.elementIndex[id], ![.connector, .image].contains(rest.kind), rest.width > 0.5, rest.height > 0.5,
              run.count > 1, run.allSatisfy({ $0.1.revealProgress == nil }) else { return nil }
        rest.rotation = nil; rest.reveal = nil; rest.style.dashOffset = nil
        let restItems = Self.items(of: rest, in: base, index: base.elementIndex, background: background)
        func kinds(_ items: [LottieItem]) -> [[Int]] { items.map { [$0.fill ? 1 : 0, $0.evenOdd ? 1 : 0, $0.dash == nil ? 0 : 1, $0.trim == nil ? 0 : 1] } }
        var posed: [[LottieItem]] = []
        for (i, _) in run {
            guard let items = sample(i)?.0, kinds(items) == kinds(restItems) else { return nil }
            posed.append(items)
        }
        let es = run.map(\.1), ts = run.map { times[$0.0] }
        let sx = es.map { $0.width / rest.width }, sy = es.map { $0.height / rest.height }
        // Text squashed out of proportion reads badly; such a shape is better keyed, where its text rewraps.
        if !(rest.text ?? "").isEmpty, zip(sx, sy).contains(where: { abs($0 - $1) > 0.02 * max($0, $1) }) { return nil }
        // Lines scale with the layer; key their widths back to what they are.
        let k = zip(sx, sy).map { max(sqrt(abs($0 * $1)), 1e-3) }
        var groups: [[String: Any]] = []
        for j in restItems.indices {
            let items = posed.map { $0[j] }
            var it: [[String: Any]] = restItems[j].contours.map { ["ty": "sh", "ks": ["a": 0, "k": Self.shapeValue($0)]] }
            let color = vector(items.map { [$0.color.r, $0.color.g, $0.color.b, 1] }, ts)
            let alpha = vector(items.map { [$0.color.a * 100] }, ts)
            if restItems[j].fill {
                it.append(["ty": "fl", "c": color, "o": alpha, "r": restItems[j].evenOdd ? 2 : 1])
            } else {
                var st: [String: Any] = ["ty": "st", "c": color, "o": alpha, "w": vector(zip(items, k).map { [$0.width / $1] }, ts),
                                         "lc": 2, "lj": 2, "ml": 4]
                if restItems[j].dash != nil {
                    st["d"] = zip(["d", "g", "o"], ["dash", "gap", "offset"]).enumerated().map { n, d in
                        ["n": d.0, "nm": d.1, "v": vector(zip(items, k).map { [$0.dash![n] / $1] }, ts)] as [String: Any]
                    }
                }
                it.append(st)
            }
            it.append(Self.groupTransform)
            groups.append(["ty": "gr", "it": it, "np": it.count - 1])
        }
        var l = layer(nextLayer(), type: 4, name: name, ip: frame(ts[0]), op: endFrame(after: run.last!.0), ks: transform(
            anchor: ["a": 0, "k": [Double(rest.frame.midX), Double(rest.frame.midY)]],
            position: vector(es.map { [Double($0.frame.midX), Double($0.frame.midY)] }, ts),
            scale: vector(zip(sx, sy).map { [$0 * 100, $1 * 100] }, ts),
            rotation: vector(unwound(es.map { $0.angle * 180 / .pi }).map { [$0] }, ts),
            opacity: vector(es.map { [($0.style.opacity ?? 1) * 100] }, ts)))
        l["shapes"] = Array(groups.reversed())
        return l
    }

    /// A picture: one image layer for each stretch it is shown, moved, sized and turned with it.
    private func pictureLayers(_ id: UUID, _ name: String, _ posed: (Int) -> Element?) -> [[String: Any]] {
        guard let img = base.elementIndex[id]?.image, let cg = img.cgImage else { return [] }
        let asset: String
        if let known = assetIDs[img.data] { asset = known } else {
            asset = "image\(assets.count)"
            assetIDs[img.data] = asset
            assets.append(["id": asset, "w": cg.width, "h": cg.height, "u": "", "e": 1,
                           "p": "data:\(img.mimeType);base64,\(img.data.base64EncodedString())"])
        }
        let pw = Double(cg.width), ph = Double(cg.height)
        var out: [[String: Any]] = []
        for run in runs(of: times.indices.map { i in posed(i).flatMap { $0.revealProgress == nil ? $0 : nil } }) {
            let es = run.map { $0.1 }, ts = run.map { times[$0.0] }
            var l = layer(nextLayer(), type: 2, name: name, ip: frame(ts[0]), op: endFrame(after: run.last!.0), ks: transform(
                anchor: ["a": 0, "k": [pw / 2, ph / 2]],
                position: vector(es.map { [Double($0.frame.midX), Double($0.frame.midY)] }, ts),
                scale: vector(es.map { [$0.width / pw * 100, $0.height / ph * 100] }, ts),
                rotation: vector(unwound(es.map { $0.angle * 180 / .pi }).map { [$0] }, ts),
                opacity: vector(es.map { [($0.style.opacity ?? 1) * 100] }, ts)))
            l["refId"] = asset
            out.append(l)
        }
        return out
    }

    /// Splits samples into stretches where `value` is non-nil: (sample index, value) pairs.
    private func runs<T>(of values: [T?]) -> [[(Int, T)]] {
        var out: [[(Int, T)]] = [], current: [(Int, T)] = []
        for (i, v) in values.enumerated() {
            if let v { current.append((i, v)) } else if !current.isEmpty { out.append(current); current = [] }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func endFrame(after i: Int) -> Double { i + 1 < times.count ? frame(times[i + 1]) : lastFrame }

    /// Shape layers drawing `sample`'s items: one for each stretch whose items keep the same shape, their
    /// paths, colors and widths keyed from sample to sample. nil from `sample` is nothing drawn then.
    private func pathRuns(name: String, _ sample: (Int) -> ([LottieItem], Double)?) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var run: [(Int, [LottieItem], Double)] = []
        func flush() {
            defer { run = [] }
            guard let first = run.first, !first.1.isEmpty else { return }
            let ts = run.map { times[$0.0] }
            // A run that only slides along keys the layer's position and draws its first sample throughout.
            let shifts = Self.shifts(run.map(\.1))
            var groups: [[String: Any]] = []
            for k in first.1.indices {
                var items = run.map { $0.1[k] }
                if shifts != nil { items = items.map { var c = $0; c.contours = first.1[k].contours; return c } }
                var it: [[String: Any]] = items[0].contours.indices.map { c in
                    ["ty": "sh", "ks": shape(items.map { $0.contours[c] }, ts)]
                }
                if items[0].trim != nil {
                    // Drawn on: the stroke trimmed from its start, every contour in turn.
                    it.append(["ty": "tm", "s": ["a": 0, "k": 0], "o": ["a": 0, "k": 0], "m": 2,
                               "e": vector(items.map { [($0.trim ?? 1) * 100] }, ts)])
                }
                let color = vector(items.map { [$0.color.r, $0.color.g, $0.color.b, 1] }, ts)
                let alpha = vector(items.map { [$0.color.a * 100] }, ts)
                if items[0].fill {
                    it.append(["ty": "fl", "c": color, "o": alpha, "r": items[0].evenOdd ? 2 : 1])
                } else {
                    var st: [String: Any] = ["ty": "st", "c": color, "o": alpha, "w": vector(items.map { [$0.width] }, ts),
                                             "lc": 2, "lj": 2, "ml": 4]
                    if items[0].dash != nil {
                        st["d"] = zip(["d", "g", "o"], ["dash", "gap", "offset"]).enumerated().map { j, n in
                            ["n": n.0, "nm": n.1, "v": vector(items.map { [$0.dash![j]] }, ts)] as [String: Any]
                        }
                    }
                    it.append(st)
                }
                it.append(Self.groupTransform)
                groups.append(["ty": "gr", "it": it, "np": it.count - 1])
            }
            var l = layer(nextLayer(), type: 4, name: name, ip: frame(ts[0]), op: endFrame(after: run.last!.0),
                          ks: transform(position: shifts.map { s in vector(s.map { [Double($0.x), Double($0.y)] }, ts) },
                                        opacity: vector(run.map { [$0.2 * 100] }, ts)))
            l["shapes"] = Array(groups.reversed())   // Lottie draws the first on top
            out.append(l)
        }
        for i in times.indices {
            guard let (items, opacity) = sample(i) else { flush(); continue }
            if let last = run.last, last.1.map(\.shape) != items.map(\.shape) { flush() }
            run.append((i, items, opacity))
        }
        flush()
        return out
    }

    /// How far each sample's items sit from the first's, when they are only that: the same contours moved.
    static func shifts(_ samples: [[LottieItem]]) -> [CGPoint]? {
        guard samples.count > 1, let first = samples.first,
              let origin = first.lazy.flatMap(\.contours).first?.v.first else { return nil }
        var out: [CGPoint] = []
        for items in samples {
            guard let p = items.lazy.flatMap(\.contours).first?.v.first else { return nil }
            let d = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
            for (a, b) in zip(first, items) {
                for (ca, cb) in zip(a.contours, b.contours) {
                    func near(_ p: CGPoint, _ q: CGPoint) -> Bool { abs(p.x - q.x) < 0.01 && abs(p.y - q.y) < 0.01 }
                    for j in ca.v.indices where !near(CGPoint(x: ca.v[j].x + d.x, y: ca.v[j].y + d.y), cb.v[j])
                        || !near(ca.i[j], cb.i[j]) || !near(ca.o[j], cb.o[j]) { return nil }
                }
            }
            out.append(d)
        }
        return out.allSatisfy { $0 == .zero } ? nil : out
    }

    // MARK: Keyframes

    /// A property from one value per sample: static when they never change, else keyed (held from each to
    /// the next in exact mode, tweened in smooth), leaving out keys the player would arrive at anyway.
    private func keyed(_ values: [[Double]], _ ts: [Double], _ wrap: @escaping ([Double]) -> Any, dims: Int) -> [String: Any] {
        guard let first = values.first, values.contains(where: { $0 != first }) else { return ["a": 0, "k": wrap(values.first ?? [])] }
        let hold = mode == .exact
        var keep: [Int] = []
        for i in values.indices {
            if i == 0 || i == values.count - 1 { keep.append(i); continue }
            if values[i] == values[i - 1] && values[i] == values[i + 1] { continue }
            if hold { if values[i] != values[i - 1] { keep.append(i) }; continue }
            // Tweened: a key on the straight line between its neighbours adds nothing.
            let (a, b, c) = (values[i - 1], values[i], values[i + 1])
            let u = (ts[i] - ts[i - 1]) / max(ts[i + 1] - ts[i - 1], 1e-9)
            if zip(zip(a, b), c).allSatisfy({ abs($0.0 + ($1 - $0.0) * u - $0.1) < 0.005 }) { continue }
            keep.append(i)
        }
        // A held value that doesn't change at the end needs no key there.
        if hold, keep.count > 1, values[keep[keep.count - 1]] == values[keep[keep.count - 2]] { keep.removeLast() }
        let ease: [String: Any] = ["x": Array(repeating: 1.0, count: dims), "y": Array(repeating: 1.0, count: dims)]
        let out: [String: Any] = ["x": Array(repeating: 0.0, count: dims), "y": Array(repeating: 0.0, count: dims)]
        let keys: [[String: Any]] = keep.enumerated().map { n, i in
            var k: [String: Any] = ["t": frame(ts[i]), "s": wrap(values[i])]
            if n < keep.count - 1 { if hold { k["h"] = 1 } else { k["i"] = ease; k["o"] = out } }
            return k
        }
        return ["a": 1, "k": keys]
    }

    private func vector(_ values: [[Double]], _ ts: [Double]) -> [String: Any] {
        let dims = values.first?.count ?? 1
        let animated = keyed(values, ts, { $0 }, dims: dims)
        // A static scalar is a plain number; keyed scalars are one-element arrays.
        if animated["a"] as? Int == 0, dims == 1 { return ["a": 0, "k": values[0][0]] }
        return animated
    }

    private func shape(_ contours: [LottieItem.Contour], _ ts: [Double]) -> [String: Any] {
        func flat(_ c: LottieItem.Contour) -> [Double] { (c.v + c.i + c.o).flatMap { [Double($0.x), Double($0.y)] } }
        let closed = contours[0].closed, n = contours[0].v.count
        func dict(_ f: [Double]) -> [String: Any] {
            func points(_ k: Int) -> [[Double]] { (0..<n).map { j in [f[2 * (k * n + j)], f[2 * (k * n + j) + 1]] } }
            return ["c": closed, "v": points(0), "i": points(1), "o": points(2)]
        }
        if contours.allSatisfy({ $0 == contours[0] }) { return ["a": 0, "k": Self.shapeValue(contours[0])] }
        let k = keyed(contours.map(flat), ts, { dict($0) }, dims: 1)
        guard k["a"] as? Int == 1, let keys = k["k"] as? [[String: Any]] else { return k }
        // Keyed shapes hold their value in a one-element list.
        return ["a": 1, "k": keys.map { key in var key = key; key["s"] = [key["s"]!]; return key }]
    }

    static func shapeValue(_ c: LottieItem.Contour) -> [String: Any] {
        func points(_ p: [CGPoint]) -> [[Double]] { p.map { [Double($0.x), Double($0.y)] } }
        return ["c": c.closed, "v": points(c.v), "i": points(c.i), "o": points(c.o)]
    }

    /// Turns spanning ±180° stay continuous, so a tween between samples never spins the long way round.
    private func unwound(_ degrees: [Double]) -> [Double] {
        var out: [Double] = []
        for d in degrees {
            guard let last = out.last else { out.append(d); continue }
            out.append(d - 360 * ((d - last) / 360).rounded())
        }
        return out
    }

    // MARK: JSON pieces

    private func layer(_ index: Int, type: Int, name: String, ip: Double, op: Double, ks: [String: Any]) -> [String: Any] {
        ["ddd": 0, "ind": index, "ty": type, "nm": name, "ln": name, "sr": 1, "ks": ks, "ao": 0, "ip": ip, "op": op,
         "st": 0, "bm": 0, "parent": 1]
    }

    private func transform(anchor: [String: Any]? = nil, position: [String: Any]? = nil, scale: [String: Any]? = nil,
                           rotation: [String: Any]? = nil, opacity: [String: Any]? = nil) -> [String: Any] {
        ["a": anchor ?? ["a": 0, "k": [0, 0]], "p": position ?? ["a": 0, "k": [0, 0]],
         "s": scale ?? ["a": 0, "k": [100, 100]], "r": rotation ?? ["a": 0, "k": 0], "o": opacity ?? ["a": 0, "k": 100]]
    }

    static var groupTransform: [String: Any] { [
        "ty": "tr", "p": ["a": 0, "k": [0, 0]], "a": ["a": 0, "k": [0, 0]], "s": ["a": 0, "k": [100, 100]],
        "r": ["a": 0, "k": 0], "o": ["a": 0, "k": 100], "sk": ["a": 0, "k": 0], "sa": ["a": 0, "k": 0],
    ] }

    private func hex(_ c: RGBA) -> String {
        func h(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#\(h(c.r))\(h(c.g))\(h(c.b))"
    }

    /// Compact JSON, numbers to three decimals.
    static func json(_ v: Any) -> String {
        switch v {
        case let d as [String: Any]:
            return "{" + d.keys.sorted().map { "\(string($0)):\(json(d[$0]!))" }.joined(separator: ",") + "}"
        case let a as [[String: Any]]: return "[" + a.map(json).joined(separator: ",") + "]"
        case let a as [Any]: return "[" + a.map(json).joined(separator: ",") + "]"
        case let s as String: return string(s)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let x as Double:
            let r = (x * 1000).rounded() / 1000
            if !r.isFinite { return "0" }
            return r == r.rounded() && abs(r) < 1e15 ? String(Int(r)) : String(r)
        case let x as CGFloat: return json(Double(x))
        default: return "null"
        }
    }

    private static func string(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}

// MARK: What an element draws

extension LottieWriter {
    /// Everything `e` draws, back to front, in page coordinates (rotation applied), as `Renderer.draw` draws it.
    static func items(of e: Element, in doc: DottieDocument, index: [UUID: Element], background: RGBA?) -> [LottieItem] {
        var e = e
        if let r = e.revealProgress, e.kind == .text { e.text = e.typed(e.text ?? "", r) }
        let pattern = Renderer.dashPattern(e.style.dash, width: e.style.strokeWidth)
        let dash = pattern.map { [$0[0], $0[1], e.style.dashOffset ?? 0] }
        var t = CGAffineTransform.identity
        if e.angle != 0, e.kind != .connector {
            let c = CGPoint(x: e.frame.midX, y: e.frame.midY)
            t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: e.angle).translatedBy(x: -c.x, y: -c.y)
        }
        func contours(_ p: CGPath) -> [LottieItem.Contour] { Self.contours(t.isIdentity ? p : p.copy(using: &t)!) }
        func stroke(_ p: CGPath, color: RGBA? = nil, width: Double? = nil, dashed: Bool = true, trim: Double? = nil) -> LottieItem {
            LottieItem(fill: false, color: color ?? e.style.stroke, width: width ?? e.style.strokeWidth,
                       dash: dashed ? dash : nil, trim: trim, contours: contours(p))
        }
        func fill(_ p: CGPath, _ color: RGBA, evenOdd: Bool = false) -> LottieItem {
            LottieItem(fill: true, evenOdd: evenOdd, color: color, contours: contours(p))
        }
        func text(_ frame: CTFrame, in box: CGRect) -> [LottieItem] {
            glyphs(frame, in: box).map { LottieItem(fill: true, color: $0.color, contours: contours($0.path)) }
        }

        if e.kind == .connector {
            let (line, filled) = Renderer.connectorParts(for: e, in: doc, index: index)
            if let r = e.revealProgress { return [stroke(line, trim: r)] }
            let both = CGMutablePath(); both.addPath(line); both.addPath(filled)
            var out = [stroke(both)]
            if !filled.isEmpty { out.append(fill(filled, e.style.stroke)) }
            if let s = e.text, !s.isEmpty {
                let r = Renderer.labelRect(for: e, in: doc, index: index)
                if let background { out.append(fill(CGPath(rect: r, transform: nil), background)) }
                let (f, box) = Renderer.textFrame(s, in: r, fontSize: e.style.fontSize, color: e.style.stroke.cgColor, centered: true)
                out += text(f, in: box)
            }
            return out.filter { !$0.contours.isEmpty }
        }
        if let r = e.revealProgress, e.kind != .text {
            return [stroke(Renderer.outline(for: e), trim: r)].filter { !$0.contours.isEmpty }
        }
        var out: [LottieItem] = []
        switch e.kind {
        case .text:
            let (f, box) = Renderer.textFrame(e.text ?? "", in: e.frame, fontSize: e.style.fontSize, color: e.style.stroke.cgColor, centered: false)
            out += text(f, in: box)
        case .image:
            if e.image?.cgImage == nil {   // a picture that can't be decoded shows as a crossed-out box
                let r = e.frame, p = CGMutablePath()
                p.addRect(r)
                p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                out.append(stroke(p, color: RGBA(r: 0.5, g: 0.5, b: 0.5), width: 1, dashed: false))
            }
            if e.style.stroke.a > 0, e.style.strokeWidth > 0 { out.append(stroke(Renderer.outline(for: e))) }
        default:
            if e.kind == .note, e.style.fill.a > 0 {
                let shadow = Renderer.fillPath(for: e).copy(using: [CGAffineTransform(translationX: Note.shadowOffset.width, y: Note.shadowOffset.height)])!
                out.append(fill(shadow, RGBA(r: 0, g: 0, b: 0, a: 0.14 * e.style.fill.a)))
            }
            if e.style.fill.a > 0, e.kind != .freehand {
                let evenOdd = e.evenOdd == true
                switch e.style.fillStyle {
                case .solid:
                    out.append(fill(Renderer.fillPath(for: e), e.style.fill, evenOdd: evenOdd))
                case .grid:
                    out.append(fill(Renderer.fillPath(for: e), e.style.fill, evenOdd: evenOdd))
                    out.append(stroke(Renderer.hachurePath(for: e), color: DungeonGrid.lineColor(for: e.style.fill), width: 1, dashed: false))
                case .hachure, .crossHatch:
                    out.append(stroke(Renderer.hachurePath(for: e), color: e.style.fill, width: max(1, e.style.strokeWidth / 2), dashed: false))
                }
            }
            out.append(stroke(Renderer.outline(for: e)))
            if let s = e.text, !s.isEmpty {
                if e.kind == .note {
                    let rect = Note.textRect(e.frame)
                    if rect.width > 1, rect.height > 1 {
                        let f = Note.layout(s, in: rect, fontSize: e.style.fontSize, color: e.style.stroke.cgColor).frame
                        out += text(f, in: rect)
                        let marks = Note.decorations(Note.lines(of: f, in: rect), in: rect)
                        if !marks.isEmpty {
                            let p = CGMutablePath()
                            for (a, b) in marks { p.move(to: a); p.addLine(to: b) }
                            out.append(stroke(p, width: max(1, e.style.fontSize / 14), dashed: false))
                        }
                    }
                } else {
                    let (f, box) = Renderer.textFrame(s, in: e.frame.insetBy(dx: 6, dy: 6), fontSize: e.style.fontSize,
                                                      color: e.style.stroke.cgColor, centered: true)
                    out += text(f, in: box)
                }
            }
        }
        return out.filter { !$0.contours.isEmpty }
    }

    /// The glyphs of a laid-out frame as outlines in top-left coordinates, one path for each text color.
    static func glyphs(_ frame: CTFrame, in box: CGRect) -> [(path: CGPath, color: RGBA)] {
        var byColor: [(path: CGMutablePath, color: RGBA)] = []
        for l in Note.lines(of: frame, in: box) {
            for run in CTLineGetGlyphRuns(l.line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = attrs[kCTFontAttributeName as String] as! CTFont
                var color = RGBA.black
                if let c = attrs[kCTForegroundColorAttributeName as String], CFGetTypeID(c as CFTypeRef) == CGColor.typeID {
                    color = rgba(c as! CGColor)
                }
                let n = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                let path: CGMutablePath
                if let k = byColor.firstIndex(where: { $0.color == color }) { path = byColor[k].path } else {
                    path = CGMutablePath(); byColor.append((path, color))
                }
                for (g, p) in zip(glyphs, positions) {
                    // CoreText is y-up from the baseline; the page is y-down.
                    var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: l.origin.x + p.x, ty: l.origin.y - p.y)
                    if let outline = CTFontCreatePathForGlyph(font, g, &t) { path.addPath(outline) }
                }
            }
        }
        return byColor.map { ($0.path, $0.color) }
    }

    static func rgba(_ c: CGColor) -> RGBA {
        let s = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? c
        let k = (s.components ?? [0, 0, 0, 1]).map(Double.init)
        if k.count >= 4 { return RGBA(r: k[0], g: k[1], b: k[2], a: k[3]) }
        if k.count == 2 { return RGBA(r: k[0], g: k[0], b: k[0], a: k[1]) }
        return .black
    }

    /// A path as Lottie contours: vertices with in and out tangents relative to them.
    static func contours(_ path: CGPath) -> [LottieItem.Contour] {
        var out: [LottieItem.Contour] = []
        var current: LottieItem.Contour?
        var start = CGPoint.zero
        func finish() {
            if var c = current, c.v.count > 1 {
                // A closing segment that lands back on the start is the closing edge itself.
                if c.closed, let last = c.v.last, hypot(last.x - c.v[0].x, last.y - c.v[0].y) < 1e-6, c.o.last == .zero {
                    c.i[0] = c.i[c.i.count - 1]
                    c.v.removeLast(); c.i.removeLast(); c.o.removeLast()
                }
                if c.v.count > 1 || !c.closed { out.append(c) }
            }
            current = nil
        }
        func begin(_ p: CGPoint) {
            finish()
            current = LottieItem.Contour(closed: false, v: [p], i: [.zero], o: [.zero])
        }
        func add(_ p: CGPoint, c1: CGPoint?, c2: CGPoint?) {
            if current == nil || current!.closed { begin(start) }
            let last = current!.v[current!.v.count - 1]
            if let c1 { current!.o[current!.o.count - 1] = CGPoint(x: c1.x - last.x, y: c1.y - last.y) }
            current!.v.append(p)
            current!.i.append(c2.map { CGPoint(x: $0.x - p.x, y: $0.y - p.y) } ?? .zero)
            current!.o.append(.zero)
        }
        path.applyWithBlock { el in
            let p = el.pointee.points
            switch el.pointee.type {
            case .moveToPoint: start = p[0]; begin(p[0])
            case .addLineToPoint: add(p[0], c1: nil, c2: nil)
            case .addQuadCurveToPoint:
                let last = current?.v.last ?? start
                let c1 = CGPoint(x: last.x + 2 / 3 * (p[0].x - last.x), y: last.y + 2 / 3 * (p[0].y - last.y))
                let c2 = CGPoint(x: p[1].x + 2 / 3 * (p[0].x - p[1].x), y: p[1].y + 2 / 3 * (p[0].y - p[1].y))
                add(p[1], c1: c1, c2: c2)
            case .addCurveToPoint: add(p[2], c1: p[0], c2: p[1])
            case .closeSubpath:
                if current != nil { current!.closed = true; finish() }
            @unknown default: break
            }
        }
        finish()
        return out
    }
}
