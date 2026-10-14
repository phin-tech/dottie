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

    public static func free(_ p: CGPoint) -> Endpoint { Endpoint(elementID: nil, port: nil, x: p.x, y: p.y) }
    public static func bound(_ id: UUID, port: Port? = nil) -> Endpoint { Endpoint(elementID: id, port: port) }
}

public enum Arrowhead: String, Codable, Sendable, CaseIterable { case none, arrow, triangle, dot, bar }

public struct ConnectorData: Codable, Equatable, Sendable {
    public var start: Endpoint
    public var end: Endpoint
    public var routing: Routing = .straight
    public var startHead: Arrowhead = .none
    public var endHead: Arrowhead = .arrow
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

    /// Where the line from the shape's center toward `target` crosses its outline.
    public static func edgePoint(_ shape: Element, toward target: CGPoint) -> CGPoint {
        let r = shape.frame
        let c = CGPoint(x: r.midX, y: r.midY)
        let target = shape.unrotated(target) // work in the shape's own frame, then rotate the answer back
        let dx = target.x - c.x, dy = target.y - c.y
        guard (dx != 0 || dy != 0), r.width > 0, r.height > 0 else { return c }
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
        if let port = ep.port { return portPoint(s, port) }
        return edgePoint(s, toward: other)
    }

    public static func endpoints(of e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> (CGPoint, CGPoint) {
        guard let c = e.connector else { return (.zero, .zero) }
        let s = resolve(c.start, other: reference(c.end, in: doc, index), in: doc, index)
        let t = resolve(c.end, other: reference(c.start, in: doc, index), in: doc, index)
        return (s, t)
    }

    /// The routed centerline plus the direction the final segment arrives in.
    public enum Route {
        case polyline([CGPoint])
        case cubic(CGPoint, CGPoint, CGPoint, CGPoint)

        public var points: [CGPoint] {
            switch self {
            case .polyline(let p): return p
            case .cubic(let a, let b, let c, let d):
                return (0...24).map { i in
                    let t = CGFloat(i) / 24, u = 1 - t
                    return CGPoint(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
                                   y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y)
                }
            }
        }
    }

    public static func route(of e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> Route {
        guard let c = e.connector else { return .polyline([]) }
        let (a, b) = endpoints(of: e, in: doc, index: index)
        let dx = b.x - a.x, dy = b.y - a.y
        let horizontal = abs(dx) >= abs(dy)
        switch c.routing {
        case .straight:
            return .polyline([a, b])
        case .curved:
            if horizontal {
                return .cubic(a, CGPoint(x: a.x + dx / 2, y: a.y), CGPoint(x: b.x - dx / 2, y: b.y), b)
            }
            return .cubic(a, CGPoint(x: a.x, y: a.y + dy / 2), CGPoint(x: b.x, y: b.y - dy / 2), b)
        case .elbow:
            // A pinned port decides the axis the connector leaves / arrives along; otherwise use the dominant axis.
            func vertical(_ port: Port?) -> Bool? { port.map { $0 == .top || $0 == .bottom } }
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
