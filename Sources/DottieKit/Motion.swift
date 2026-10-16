import Foundation
import CoreGraphics

/// A span of time over which an element's center travels along a path: a connector's route, or the
/// outline of a shape. Afterwards the element stays at the path's end until an x or y key after the
/// span takes it back.
public struct Follow: Codable, Equatable, Sendable {
    /// A connector, or any other element whose outline is traced.
    public var path: UUID
    /// Seconds.
    public var start, end: Double
    /// The pace along the path; nil is `.easeInOut`.
    public var ease: Ease?
    /// Travel from the path's end to its start.
    public var reverse: Bool?
    /// Turn the element to face along the path.
    public var orient: Bool?
    /// Times round the path over the span (for orbiting a closed outline); nil is once.
    public var laps: Double?

    public init(path: UUID, start: Double, end: Double, ease: Ease? = nil, reverse: Bool? = nil,
                orient: Bool? = nil, laps: Double? = nil) {
        self.path = path; self.start = start; self.end = end; self.ease = ease
        self.reverse = reverse; self.orient = orient; self.laps = laps
    }
}

/// Points along a path with their running length, for finding the point a fraction of the way along.
struct Polyline {
    var points: [CGPoint]
    var lengths: [CGFloat]

    init(_ points: [CGPoint]) {
        self.points = points
        var run: CGFloat = 0
        lengths = points.indices.map { i in
            if i > 0 { run += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
            return run
        }
    }

    var length: CGFloat { lengths.last ?? 0 }

    /// The point `u` (0...1) of the way along, by distance.
    func point(at u: Double) -> CGPoint {
        guard points.count > 1, length > 0 else { return points.first ?? .zero }
        let d = CGFloat(min(max(u, 0), 1)) * length
        var i = 1
        while i < lengths.count - 1, lengths[i] < d { i += 1 }
        let seg = lengths[i] - lengths[i - 1]
        let f = seg > 0 ? (d - lengths[i - 1]) / seg : 0
        let a = points[i - 1], b = points[i]
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// The path's first contour.
    init(path: CGPath) { self.init(path.contours.first ?? []) }

    /// The clean route of a connector, or the clean, rotated outline of any other element.
    init(tracing e: Element, in doc: DottieDocument) {
        if e.kind == .connector {
            self.init(Connector.route(of: e, in: doc).points)
        } else {
            var clean = e
            clean.style.roughness = 0
            let pts = Polyline(path: Renderer.outline(for: clean)).points
            self.init(e.angle == 0 ? pts : pts.map(e.rotated))
        }
    }
}

extension Track {
    /// The path span placing the element at time `t`: the latest one started, unless an x or y key after it
    /// has taken the element back.
    func followSpan(at t: Double) -> Follow? {
        let t = localTime(t)   // a repeated span repeats its travel too
        guard let f = follow?.filter({ $0.start <= t }).max(by: { $0.start < $1.start }) else { return nil }
        if keys.contains(where: { $0.t >= f.end && $0.t <= t && ($0.x != nil || $0.y != nil) }) { return nil }
        return f
    }

    /// `e` moved onto the path it is following at time `t`, if any. `doc` is the page with keys applied.
    func following(_ e: Element, at t: Double, in doc: DottieDocument) -> Element {
        guard let f = followSpan(at: t) else { return e }
        let t = localTime(t)
        guard let pathElement = doc.elements.first(where: { $0.id == f.path }), pathElement.id != e.id else { return e }
        let line = Polyline(tracing: pathElement, in: doc)
        let span = f.end - f.start
        var u = (f.ease ?? .easeInOut).apply(span > 0 ? min(1, (t - f.start) / span) : 1) * (f.laps ?? 1)
        if u > 1 { u = u.truncatingRemainder(dividingBy: 1) == 0 ? 1 : u.truncatingRemainder(dividingBy: 1) }
        if f.reverse == true { u = 1 - u }
        let p = line.point(at: u)
        var moved = e
        moved.x = p.x - e.width / 2
        moved.y = p.y - e.height / 2
        if f.orient == true {
            let step = f.reverse == true ? -0.01 : 0.01
            let a = line.point(at: u - step / 2), b = line.point(at: u + step / 2)
            if a != b { moved.rotation = atan2(b.y - a.y, b.x - a.x) }
        }
        return moved
    }
}

extension Timeline {
    /// Adds a span of path following to element `id`, lengthening the timeline to fit.
    public mutating func addFollow(_ f: Follow, for id: UUID) {
        duration = max(duration, f.end)
        if let ti = tracks.firstIndex(where: { $0.element == id }) {
            tracks[ti].follow = (tracks[ti].follow ?? []) + [f]
        } else {
            tracks.append(Track(element: id, keys: [], follow: [f]))
        }
    }
}

extension DottieDocument {
    /// Makes element `id` travel along `path` (a connector or a shape's outline) from `t` for `duration` seconds.
    public mutating func addFollow(_ id: UUID, along path: UUID, at t: Double, duration: Double = 1, ease: Ease? = nil,
                                   reverse: Bool = false, orient: Bool = false, laps: Double? = nil) throws {
        guard let e = elements.first(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
        guard e.kind != .connector else { throw OpsError.invalid("Connectors follow their shapes; move those instead") }
        guard elements.contains(where: { $0.id == path }) else { throw OpsError.notFound("No path element \(path.uuidString)") }
        guard id != path else { throw OpsError.invalid("An element can't follow itself") }
        var tl = timeline ?? Timeline(duration: 0)
        let t = Timeline.clampTime(t)
        tl.addFollow(Follow(path: path, start: t, end: Timeline.clampTime(t + max(0.05, duration)), ease: ease,
                            reverse: reverse ? true : nil, orient: orient ? true : nil,
                            laps: laps.map { $0.isFinite ? min(max($0, 0), 1000) : 1 }), for: id)
        timeline = tl
    }

    /// A dot that travels along `connector` from `t` for `duration` seconds and is hidden otherwise:
    /// a request, message or packet on its way. Returns the dot.
    @discardableResult
    /// With a `label`, the packet is a pill carrying that text ("POST /orders") instead of a dot.
    public mutating func addPacket(along connector: UUID, at t: Double, duration: Double = 0.6,
                                   color: RGBA = RGBA(r: 0.95, g: 0.36, b: 0.33), size: Double = 14,
                                   label: String? = nil) throws -> Element {
        guard let c = elements.first(where: { $0.id == connector }), c.kind == .connector else {
            throw OpsError.invalid("A packet travels along a connector")
        }
        let start = Connector.endpoints(of: c, in: self).0
        var style = Style()
        style.fill = color; style.stroke = color; style.roughness = min(c.style.roughness, 1); style.strokeWidth = 1.5
        var frame = CGSize(width: size, height: size)
        let text = label.map { String($0.prefix(60)) }.flatMap { $0.isEmpty ? nil : $0 }
        if let text {
            // White lettering on the packet's color; the pill hugs the text.
            style.stroke = RGBA(r: 1, g: 1, b: 1)
            style.fontSize = 12
            style.roughness = 0
            let fit = Renderer.textSize(text, fontSize: style.fontSize, maxWidth: 400)
            frame = CGSize(width: ceil(fit.width) + 24, height: max(size, ceil(fit.height) + 14))
        }
        let dot = Element(kind: .ellipse, frame: CGRect(x: start.x - frame.width / 2, y: start.y - frame.height / 2,
                                                        width: frame.width, height: frame.height),
                          style: style, layerID: c.layerID, text: text)
        elements.append(dot)
        let t = Timeline.clampTime(t)
        let d = min(max(0.05, duration), 60)
        var tl = timeline ?? Timeline(duration: 0)
        tl.setKey(Keyframe(t: t, visible: true), for: dot.id)
        tl.setKey(Keyframe(t: t + d, visible: false), for: dot.id)
        tl.addFollow(Follow(path: connector, start: t, end: t + d), for: dot.id)
        timeline = tl
        return dot
    }

    /// Reveals the page's shapes in connector order: shapes nothing points to first, then what they point to,
    /// a step of `stagger` seconds per rank. With `packets`, a packet runs down each arrow (which appears as
    /// it sets off); with `drawArrows`, each arrow draws itself on. Either way the shape an arrow points to
    /// enters once it gets there, `travel` seconds later.
    public mutating func addBuild(_ transition: Transition = .popIn, at start: Double = 0, stagger: Double = 0.4,
                                  packets: Bool = false, drawArrows: Bool = false, travel: Double = 0.6) throws {
        let start = Timeline.clampTime(start)
        let stagger = stagger.isFinite ? min(max(stagger, 0), 60) : 0.4
        let travel = travel.isFinite ? min(max(travel, 0.05), 60) : 0.6
        guard transition.isEntrance else { throw OpsError.invalid("A build needs an entrance transition") }
        let shapes = elements.filter { $0.kind != .connector }
        guard !shapes.isEmpty else { throw OpsError.invalid("The page has no shapes to build") }
        let ids = Set(shapes.map(\.id))
        let edges = elements.compactMap { e -> (UUID, UUID, UUID)? in
            guard let a = e.connector?.start.elementID, let b = e.connector?.end.elementID,
                  ids.contains(a), ids.contains(b), a != b else { return nil }
            return (e.id, a, b)
        }
        // Breadth-first ranks from the sources; a cycle with no way in starts from its top-left shape.
        let byPosition = shapes.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        var rank: [UUID: Int] = [:]
        var parentEdge: [UUID: (UUID, UUID)] = [:]   // shape -> (connector, source) it was reached by
        let targets = Set(edges.map(\.2))
        var queue = byPosition.map(\.id).filter { !targets.contains($0) }
        for id in queue { rank[id] = 0 }
        // Ranks are keyed by id, so count distinct ids: a file with a duplicated id would otherwise never finish.
        let distinct = ids.count
        while rank.count < distinct || !queue.isEmpty {
            if queue.isEmpty, let next = byPosition.first(where: { rank[$0.id] == nil }) {
                rank[next.id] = (rank.values.max() ?? -1) + 1; queue = [next.id]
            }
            var nextQueue: [UUID] = []
            for u in queue {
                for (c, a, b) in edges where a == u && rank[b] == nil {
                    rank[b] = rank[u]! + 1; parentEdge[b] = (c, u); nextQueue.append(b)
                }
            }
            queue = nextQueue
        }
        let d = transition.defaultDuration
        var appear: [UUID: Double] = [:]
        for r in 0...(rank.values.max() ?? 0) {
            let level = byPosition.filter { rank[$0.id] == r }
            for (j, e) in level.enumerated() {
                var t = start + Double(r) * stagger + Double(j) * 0.08
                if packets || drawArrows, let (c, source) = parentEdge[e.id], let sourceT = appear[source] {
                    let leave = sourceT + d
                    if drawArrows { try addTransition(.drawIn, to: c, at: leave, duration: travel) }
                    if packets {
                        try addPacket(along: c, at: leave, duration: travel)
                        timeline!.setKey(Keyframe(t: leave, visible: true), for: c)
                    }
                    t = leave + travel
                }
                appear[e.id] = t
                try addTransition(transition, to: e.id, at: t)
            }
        }
        // Arrows that didn't lead the build draw on once both their shapes are in.
        if drawArrows {
            let led = Set(parentEdge.values.map(\.0))
            for (c, a, b) in edges where !led.contains(c) {
                if let ta = appear[a], let tb = appear[b] { try addTransition(.drawIn, to: c, at: max(ta, tb) + d, duration: travel) }
            }
        }
        timeline!.duration += 0.75   // a beat on the finished diagram before the loop restarts
    }
}
