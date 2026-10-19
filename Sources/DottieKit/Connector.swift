import Foundation
import CoreGraphics

public enum Port: String, Codable, Sendable, CaseIterable { case top, right, bottom, left }
public enum Routing: String, Codable, Sendable, CaseIterable { case straight, curved, elbow }

/// One end of a connector. Bound to a shape (edge-following, or pinned to a port) or free in space.
public struct Endpoint: Codable, Equatable, Sendable {
    public var elementID: UUID?
    public var port: Port?          // nil = edge-following
    public var x: Double = 0        // used only when unbound
    public var y: Double = 0
    /// Pins the end to one of the bound extension shape's `ports` (its index there). Wins over `port`.
    public var portIndex: Int? = nil

    public static func free(_ p: CGPoint) -> Endpoint { Endpoint(elementID: nil, port: nil, x: p.x, y: p.y) }
    public static func bound(_ id: UUID, port: Port? = nil) -> Endpoint { Endpoint(elementID: id, port: port) }
}

public enum Arrowhead: String, Codable, Sendable, CaseIterable { case none, arrow, triangle, dot, bar }

/// A point on the canvas a connector's line passes through.
public struct Waypoint: Codable, Equatable, Hashable, Sendable {
    public var x, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ p: CGPoint) { x = p.x; y = p.y }
    public var point: CGPoint { CGPoint(x: x, y: y) }
}

public struct ConnectorData: Codable, Equatable, Sendable {
    public var start: Endpoint
    public var end: Endpoint
    public var routing: Routing = .straight
    public var startHead: Arrowhead = .none
    public var endHead: Arrowhead = .arrow
    /// Bends the user dragged in, start to end, on the canvas. The line passes through each in turn, whatever its
    /// routing; they stay put when the end shapes move, and move with the connector. Nil (or empty) routes it
    /// from its ends alone.
    public var waypoints: [Waypoint]? = nil
    /// Hops (small arcs) where the line crosses a connector drawn beneath it.
    public var hops: Bool? = nil
    public init(start: Endpoint, end: Endpoint, routing: Routing = .straight, endArrow: Bool = true) {
        self.start = start; self.end = end; self.routing = routing
        self.endHead = endArrow ? .arrow : .none
    }
    /// Convenience over `endHead`/`startHead` for callers that only care whether there is a head.
    public var endArrow: Bool {
        get { endHead != .none }
        set { endHead = newValue ? (endHead == .none ? .arrow : endHead) : .none }
    }
    public var startArrow: Bool {
        get { startHead != .none }
        set { startHead = newValue ? (startHead == .none ? .arrow : startHead) : .none }
    }

    /// Moves what belongs to the connector itself, its free ends and its waypoints, through `f` (a move, a turn, a
    /// scale). Bound ends follow their shapes, so they are left alone.
    public mutating func transformFree(_ f: (CGPoint) -> CGPoint) {
        for isStart in [true, false] {
            var ep = isStart ? start : end
            if ep.elementID == nil {
                let p = f(CGPoint(x: ep.x, y: ep.y))
                ep.x = p.x; ep.y = p.y
            }
            if isStart { start = ep } else { end = ep }
        }
        if let w = waypoints { waypoints = w.map { Waypoint(f($0.point)) } }
    }

    /// Changes the routing. An elbow line's waypoints are its corners, which mean nothing to a straight or curved
    /// line (and the other way round), so a change between the two kinds takes the bends out.
    public mutating func setRouting(_ r: Routing) {
        if (routing == .elbow) != (r == .elbow) { waypoints = nil }
        routing = r
    }

    public mutating func translateFree(dx: Double, dy: Double) {
        transformFree { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}

/// Connector geometry. Everything is computed from bindings at render time,
/// so arrows follow shapes with no bookkeeping.
public enum Connector {
    public static func portPoint(_ shape: Element, _ port: Port) -> CGPoint {
        let r = shape.frame
        let p: CGPoint
        switch port {
        case .top: p = CGPoint(x: r.midX, y: r.minY)
        case .right: p = CGPoint(x: r.maxX, y: r.midY)
        case .bottom: p = CGPoint(x: r.midX, y: r.maxY)
        case .left: p = CGPoint(x: r.minX, y: r.midY)
        }
        return shape.rotated(p)
    }

    /// A port of an extension shape: its normalized `ports[index]`, on the canvas.
    public static func portPoint(_ shape: Element, index: Int) -> CGPoint? {
        guard let p = shape.ports, p.indices.contains(index) else { return nil }
        let r = shape.frame
        return shape.rotated(CGPoint(x: r.minX + p[index].x * r.width, y: r.minY + p[index].y * r.height))
    }

    /// Where the line from the shape's center toward `target` crosses its outline. A `.path` uses its actual
    /// contours (see `Element.outlineCrossing`), so a stencil's connectors meet its drawing, not its bounding box.
    public static func edgePoint(_ shape: Element, toward target: CGPoint) -> CGPoint {
        let r = shape.frame
        let c = CGPoint(x: r.midX, y: r.midY)
        let target = shape.unrotated(target) // work in the shape's own frame, then rotate the answer back
        let dx = target.x - c.x, dy = target.y - c.y
        guard (dx != 0 || dy != 0), r.width > 0, r.height > 0 else { return c }
        if shape.kind == .path, let hit = shape.outlineCrossing(from: c, along: CGPoint(x: dx, y: dy)) {
            return shape.rotated(hit)
        }
        let hw = r.width / 2, hh = r.height / 2
        let t: CGFloat
        switch shape.kind {
        case .ellipse:
            t = 1 / sqrt((dx * dx) / (hw * hw) + (dy * dy) / (hh * hh))
        case .diamond:
            t = 1 / (abs(dx) / hw + abs(dy) / hh)
        default:
            t = min(dx != 0 ? hw / abs(dx) : .infinity, dy != 0 ? hh / abs(dy) : .infinity)
        }
        return shape.rotated(CGPoint(x: c.x + dx * t, y: c.y + dy * t))
    }

    /// The points a connector can be pinned to on `shape`: an extension shape's own `ports` when it declares any,
    /// otherwise the four mid-edge ports, on the canvas.
    public static func connectionPoints(_ shape: Element) -> [CGPoint] {
        if let ports = shape.ports, !ports.isEmpty {
            return ports.indices.compactMap { portPoint(shape, index: $0) }
        }
        return Port.allCases.map { portPoint(shape, $0) }
    }

    /// The end of a connector dropped at `p` on `shape`: pinned to the nearest connection point within `radius` (one
    /// of an extension shape's `ports`, else a mid-edge port), otherwise following the shape's edge.
    public static func endpoint(near p: CGPoint, on shape: Element, radius: CGFloat = 12) -> Endpoint {
        guard let ports = shape.ports, !ports.isEmpty else { return .bound(shape.id, port: port(near: p, of: shape, radius: radius)) }
        var end = Endpoint.bound(shape.id)
        end.portIndex = ports.indices
            .compactMap { i in portPoint(shape, index: i).map { (i, hypot($0.x - p.x, $0.y - p.y)) } }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
        return end
    }

    /// Nearest port of `shape` within `radius` of `p`, if any (used to snap on drop).
    public static func port(near p: CGPoint, of shape: Element, radius: CGFloat = 12) -> Port? {
        Port.allCases
            .map { ($0, hypot(portPoint(shape, $0).x - p.x, portPoint(shape, $0).y - p.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// `index` is `doc.elementIndex`. Callers that resolve many connectors in one pass build it once;
    /// without it each lookup scans the element array, which is quadratic on large documents.
    private static func shape(_ id: UUID, in doc: DottieDocument, _ index: [UUID: Element]?) -> Element? {
        if let index { return index[id] }
        return doc.elements.first { $0.id == id }
    }

    private static func reference(_ ep: Endpoint, in doc: DottieDocument, _ index: [UUID: Element]?) -> CGPoint {
        if let id = ep.elementID, let s = shape(id, in: doc, index) {
            return CGPoint(x: s.frame.midX, y: s.frame.midY)
        }
        return CGPoint(x: ep.x, y: ep.y)
    }

    private static func resolve(_ ep: Endpoint, other: CGPoint, in doc: DottieDocument, _ index: [UUID: Element]?) -> CGPoint {
        guard let id = ep.elementID, let s = shape(id, in: doc, index) else {
            return CGPoint(x: ep.x, y: ep.y)
        }
        if let i = ep.portIndex, let p = portPoint(s, index: i) { return p }
        if let port = ep.port { return portPoint(s, port) }
        return edgePoint(s, toward: other)
    }

    public static func endpoints(of e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> (CGPoint, CGPoint) {
        guard let c = e.connector else { return (.zero, .zero) }
        // An edge-following end aims at the next point along the line: its nearest waypoint, else the other end.
        let w = c.waypoints ?? []
        let s = resolve(c.start, other: w.first?.point ?? reference(c.end, in: doc, index), in: doc, index)
        let t = resolve(c.end, other: w.last?.point ?? reference(c.start, in: doc, index), in: doc, index)
        return (s, t)
    }

    /// The routed centerline plus the direction the final segment arrives in.
    public enum Route {
        case polyline([CGPoint])
        /// Joined cubic Béziers: the start, then two controls and an end per segment.
        case curve([CGPoint])

        public var points: [CGPoint] {
            switch self {
            case .polyline(let p): return p
            case .curve(let p):
                var out: [CGPoint] = []
                for s in 0..<((p.count - 1) / 3) {
                    let a = p[3 * s], b = p[3 * s + 1], c = p[3 * s + 2], d = p[3 * s + 3]
                    for i in (s == 0 ? 0 : 1)...24 {
                        let t = CGFloat(i) / 24, u = 1 - t
                        out.append(CGPoint(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
                                           y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y))
                    }
                }
                return out
            }
        }
    }

    public static func route(of e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> Route {
        guard let c = e.connector else { return .polyline([]) }
        let (a, b) = endpoints(of: e, in: doc, index: index)
        if let w = c.waypoints, !w.isEmpty { return route(through: [a] + w.map(\.point) + [b], c) }
        let dx = b.x - a.x, dy = b.y - a.y
        let horizontal = abs(dx) >= abs(dy)
        switch c.routing {
        case .straight:
            return .polyline([a, b])
        case .curved:
            if horizontal {
                return .curve([a, CGPoint(x: a.x + dx / 2, y: a.y), CGPoint(x: b.x - dx / 2, y: b.y), b])
            }
            return .curve([a, CGPoint(x: a.x, y: a.y + dy / 2), CGPoint(x: b.x, y: b.y - dy / 2), b])
        case .elbow:
            // A pinned port decides the axis the connector leaves / arrives along; otherwise use the dominant axis.
            let startV = vertical(c.start.port) ?? !horizontal
            let endV = vertical(c.end.port) ?? !horizontal
            switch (startV, endV) {
            case (true, true):
                let my = a.y + dy / 2
                return .polyline([a, CGPoint(x: a.x, y: my), CGPoint(x: b.x, y: my), b])
            case (false, false):
                let mx = a.x + dx / 2
                return .polyline([a, CGPoint(x: mx, y: a.y), CGPoint(x: mx, y: b.y), b])
            case (true, false):
                return .polyline([a, CGPoint(x: a.x, y: b.y), b])
            case (false, true):
                return .polyline([a, CGPoint(x: b.x, y: a.y), b])
            }
        }
    }

    private static func vertical(_ port: Port?) -> Bool? { port.map { $0 == .top || $0 == .bottom } }

    /// The route through `p` (the start, the waypoints, the end): straight lines between them, a smooth curve
    /// through them (Catmull-Rom), or right angles that turn as little as they can.
    private static func route(through p: [CGPoint], _ c: ConnectorData) -> Route {
        switch c.routing {
        case .straight:
            return .polyline(p)
        case .curved:
            var out = [p[0]]
            for i in 0..<(p.count - 1) {
                let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
                out.append(CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6))
                out.append(CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
                out.append(p2)
            }
            return .curve(out)
        case .elbow:
            let first = p[1], a = p[0]
            var goVertical = vertical(c.start.port) ?? (abs(first.y - a.y) > abs(first.x - a.x))
            let endV = vertical(c.end.port)
            var out = [a]
            for i in 1..<p.count {
                let q = p[i], cur = out[out.count - 1]
                let alignedX = abs(cur.x - q.x) < 0.5, alignedY = abs(cur.y - q.y) < 0.5
                if alignedX || alignedY {
                    out.append(q)
                    if alignedX != alignedY { goVertical = !alignedX } // turn after a vertical leg, and vice versa
                    continue
                }
                // The last leg arrives along a pinned port's axis; every other leg sets off along `goVertical`.
                let up = i == p.count - 1 ? endV.map { !$0 } ?? goVertical : goVertical
                let corner = up ? CGPoint(x: cur.x, y: q.y) : CGPoint(x: q.x, y: cur.y)
                out.append(corner); out.append(q)
                goVertical = up // the leg ended along the other axis, so the next sets off along this one
            }
            return .polyline(simplified(out))
        }
    }

    /// Drops repeated points and the middle of three in a line, so dragged bends that fall into line disappear.
    static func simplified(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for q in pts {
            if let l = out.last, abs(l.x - q.x) < 0.5, abs(l.y - q.y) < 0.5 { continue }
            if out.count >= 2 {
                let p = out[out.count - 2], m = out[out.count - 1]
                if (abs(p.x - m.x) < 0.5 && abs(m.x - q.x) < 0.5) || (abs(p.y - m.y) < 0.5 && abs(m.y - q.y) < 0.5) {
                    out[out.count - 1] = q; continue
                }
            }
            out.append(q)
        }
        return out.count >= 2 ? out : pts
    }

    // MARK: Bends

    /// A place on a selected connector to drag to reshape it.
    public enum BendHandle: Equatable, Sendable {
        /// One of its waypoints, on a straight or curved line.
        case waypoint(Int)
        /// Halfway between two points along a straight or curved line: dragging it adds a waypoint at this index.
        case insert(Int)
        /// One segment of an elbow line, by its index in the route: dragging moves it sideways.
        case segment(Int)
    }

    /// Where a connector's bend handles are: on a straight or curved line its waypoints and a handle halfway along
    /// each stretch between them; on an elbow line the middle of each segment.
    public static func bendHandles(of e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> [(handle: BendHandle, at: CGPoint)] {
        guard let c = e.connector else { return [] }
        let r = route(of: e, in: doc, index: index)
        let w = c.waypoints ?? []
        func mid(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
        switch r {
        case .polyline(let route) where c.routing == .elbow:
            let pts = simplified(route) // a bare elbow can have zero-length segments; they get no handles
            return (0..<max(pts.count - 1, 0)).map { (.segment($0), mid(pts[$0], pts[$0 + 1])) }
        case .polyline(let pts):
            return w.indices.map { (.waypoint($0), w[$0].point) }
                + (0..<max(pts.count - 1, 0)).map { (.insert($0), mid(pts[$0], pts[$0 + 1])) }
        case .curve(let pts):
            let halves = (0..<((pts.count - 1) / 3)).map { s -> CGPoint in
                let a = pts[3 * s], b = pts[3 * s + 1], c = pts[3 * s + 2], d = pts[3 * s + 3]
                return CGPoint(x: (a.x + 3 * b.x + 3 * c.x + d.x) / 8, y: (a.y + 3 * b.y + 3 * c.y + d.y) / 8)
            }
            return w.indices.map { (.waypoint($0), w[$0].point) } + halves.indices.map { (.insert($0), halves[$0]) }
        }
    }

    /// The waypoints `e` gets when `handle` is dragged to `p`, worked out from `e` as it was when the drag began.
    /// An elbow segment moves sideways only; when it is the first or last, a new corner keeps the end where it is.
    public static func bend(_ e: Element, in doc: DottieDocument, handle: BendHandle, to p: CGPoint) -> [Waypoint]? {
        guard let c = e.connector else { return nil }
        var w = c.waypoints ?? []
        switch handle {
        case .waypoint(let i):
            guard w.indices.contains(i) else { return c.waypoints }
            w[i] = Waypoint(p)
            return w
        case .insert(let i):
            w.insert(Waypoint(p), at: min(max(i, 0), w.count))
            return w
        case .segment(let k):
            guard case .polyline(let route) = route(of: e, in: doc) else { return c.waypoints }
            let r = simplified(route) // as bendHandles numbers the segments
            guard r.indices.contains(k + 1) else { return c.waypoints }
            let horizontal = abs(r[k].y - r[k + 1].y) < abs(r[k].x - r[k + 1].x)
            var pts = r, lo = k, hi = k + 1
            if hi == pts.count - 1 { pts.insert(pts[hi], at: hi) }
            if lo == 0 { pts.insert(pts[0], at: 0); lo += 1; hi += 1 }
            for i in [lo, hi] {
                if horizontal { pts[i].y = p.y } else { pts[i].x = p.x }
            }
            return pts[1..<(pts.count - 1)].map(Waypoint.init)
        }
    }

    /// Arrowhead wing points for an arrow tip at `tip` arriving from direction `from`.
    public static func arrowhead(tip: CGPoint, from: CGPoint, size: CGFloat) -> (CGPoint, CGPoint) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let spread = CGFloat.pi / 7
        func wing(_ s: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - size * cos(angle + s), y: tip.y - size * sin(angle + s))
        }
        return (wing(spread), wing(-spread))
    }

    public static func distance(from p: CGPoint, to e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> CGFloat {
        let pts = route(of: e, in: doc, index: index).points
        guard pts.count > 1 else { return .infinity }
        var best = CGFloat.infinity
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let l2 = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)
            let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / l2))
            best = min(best, hypot(p.x - (a.x + t * (b.x - a.x)), p.y - (a.y + t * (b.y - a.y))))
        }
        return best
    }

    public static func bounds(of e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> CGRect {
        let pts = route(of: e, in: doc, index: index).points
        guard let f = pts.first else { return .zero }
        return pts.reduce(CGRect(origin: f, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
}
