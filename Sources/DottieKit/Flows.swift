import Foundation
import CoreGraphics

/// Traffic from one shape to the first of `to` it can reach, over the connectors drawn in each frame (ADR 0002).
/// Packets aren't stored: every renderer places them while it poses a frame, from the time and the page's variables,
/// so when a click takes a region down, the traffic goes round it.
public struct Flow: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The shape traffic leaves from.
    public var from: UUID
    /// Destinations in order of preference: traffic goes to the first one it can reach.
    public var to: [UUID]
    /// Seconds between packets; nil is 0.5.
    public var every: Double?
    /// Points per second; nil is 160.
    public var speed: Double?
    /// The packets' color; nil is the packet red `addPacket` uses.
    public var color: RGBA?
    /// The packets' diameter; nil is 12.
    public var size: Double?
    /// A condition on the page's variables (`PageState`): nothing flows while it fails.
    public var when: String?

    public init(id: UUID = UUID(), from: UUID, to: [UUID], every: Double? = nil, speed: Double? = nil,
                color: RGBA? = nil, size: Double? = nil, when: String? = nil) {
        self.id = id; self.from = from; self.to = to; self.every = every; self.speed = speed
        self.color = color; self.size = size; self.when = when
    }

    // Lenient, like the rest of the format: a flow with a missing or bad id, source or destination loads and sends
    // nothing rather than failing the page. Destinations that aren't ids are dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let none = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func uuid(_ k: CodingKeys) -> UUID { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil).flatMap(UUID.init(uuidString:)) ?? none }
        id = uuid(.id); from = uuid(.from)
        to = ((try? c.decodeIfPresent([String].self, forKey: .to)) ?? nil)?.compactMap(UUID.init(uuidString:)) ?? []
        func number(_ k: CodingKeys) -> Double? { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil).flatMap { $0.isFinite ? $0 : nil } }
        every = number(.every); speed = number(.speed); size = number(.size)
        color = (try? c.decodeIfPresent(RGBA.self, forKey: .color)) ?? nil
        when = (try? c.decodeIfPresent(String.self, forKey: .when)) ?? nil
    }

    public static let defaultEvery = 0.5, defaultSpeed = 160.0, defaultSize = 12.0
    public static let defaultColor = RGBA(r: 0.95, g: 0.36, b: 0.33)
    /// The most packets one flow draws in a frame.
    static let maxPackets = 400

    /// `every`, `speed` and `size` as drawn: defaults for nil, kept within sensible bounds.
    var interval: Double { Self.clamp(every, Self.defaultEvery, 0.05, 60) }
    var pace: Double { Self.clamp(speed, Self.defaultSpeed, 1, 10000) }
    var diameter: Double { Self.clamp(size, Self.defaultSize, 2, 200) }
    private static func clamp(_ v: Double?, _ fallback: Double, _ lo: Double, _ hi: Double) -> Double {
        guard let v, v.isFinite else { return fallback }
        return min(max(v, lo), hi)
    }

    /// The id of packet `k`: the flow's id with its last twelve digits standing for `k`, so a packet keeps its id from
    /// frame to frame.
    static func packetID(_ flow: UUID, _ k: Int) -> UUID {
        let n = UInt64(bitPattern: Int64(k) &+ (1 << 40)) & 0xFFFF_FFFF_FFFF
        return UUID(uuidString: String(flow.uuidString.prefix(24)) + String(format: "%012llX", n)) ?? flow
    }
}

extension DottieDocument {
    /// The connectors traffic takes from `from` to the first of `to` it reaches in `frame`, as (connector, backwards)
    /// hops; nil when none can be reached. The cheapest route by the connectors' `cost` (1 each unless set), ties to
    /// the route found first, earlier connectors first (ADR 0002): with no costs set, the fewest hops.
    /// `offline` elements (an override says so) carry nothing: traffic neither leaves, passes nor arrives through them.
    static func flowRoute(from: UUID, to: [UUID], in frame: DottieDocument, offline: Set<UUID> = []) -> [(UUID, Bool)]? {
        let shapes = Set(frame.elements.filter { $0.kind != .connector && !offline.contains($0.id) }.map(\.id))
        guard shapes.contains(from) else { return nil }
        var next: [UUID: [(to: UUID, via: UUID, back: Bool, cost: Double)]] = [:]
        for e in frame.elements {
            guard let c = e.connector, !offline.contains(e.id), let a = c.start.elementID, let b = c.end.elementID, a != b,
                  shapes.contains(a), shapes.contains(b) else { continue }
            next[a, default: []].append((b, e.id, false, c.routeCost))
            if c.startHead != .none { next[b, default: []].append((a, e.id, true, c.routeCost)) }
        }
        // Dijkstra. The next shape settled is the cheapest not yet settled, ties to the one reached first (`order`), so
        // with equal costs it settles shapes in breadth-first order and web/src/flows.ts picks the same route.
        var dist: [UUID: Double] = [from: 0], order: [UUID: Int] = [from: 0], counter = 1
        var came: [UUID: (from: UUID, via: UUID, back: Bool)] = [:]
        var open: [UUID] = [from], settled: Set<UUID> = []
        while !open.isEmpty {
            var best = 0
            for i in 1..<open.count {
                let (a, b) = (open[i], open[best])
                if dist[a]! < dist[b]! || (dist[a]! == dist[b]! && order[a]! < order[b]!) { best = i }
            }
            let n = open.remove(at: best)
            settled.insert(n)
            for edge in next[n] ?? [] where !settled.contains(edge.to) {
                let d = dist[n]! + edge.cost
                if let old = dist[edge.to], old <= d { continue }
                if dist[edge.to] == nil { open.append(edge.to) }
                dist[edge.to] = d; order[edge.to] = counter; counter += 1
                came[edge.to] = (n, edge.via, edge.back)
            }
        }
        guard let goal = to.first(where: { $0 != from && settled.contains($0) }) else { return nil }
        var hops: [(UUID, Bool)] = []
        var at = goal
        while let step = came[at] { hops.append((step.via, step.back)); at = step.from }
        return hops.reversed()
    }

    /// The packets the page's flows draw in `frame` (the page posed at `t`), with these variable values (nil: every
    /// flow runs).
    func flowPackets(in frame: DottieDocument, at t: Double, values: [String: Bool]?, offline: Set<UUID> = []) -> [Element] {
        guard let flows, !flows.isEmpty else { return [] }
        let byID = frame.elementIndex
        var out: [Element] = []
        // Flows leaving the same shape take turns: the i-th of m starts i/m of its gap later, so they don't draw on
        // top of each other. Counted over the page's flows, whatever their conditions, so a flow switching on moves none.
        var leaving: [UUID: Int] = [:], turn: [Int] = []
        for flow in flows { turn.append(leaving[flow.from, default: 0]); leaving[flow.from, default: 0] += 1 }
        for (i, flow) in flows.enumerated() {
            if let w = flow.when, let values, !PageState.holds(w, in: values) { continue }
            guard let source = byID[flow.from], let hops = Self.flowRoute(from: flow.from, to: flow.to, in: frame, offline: offline) else { continue }
            var points: [CGPoint] = []
            for (id, back) in hops {
                guard let c = byID[id] else { continue }
                let p = Polyline(tracing: c, in: frame).points
                points += back ? p.reversed() : p
            }
            let line = Polyline(points)
            let length = Double(line.length)
            guard length > 0 else { continue }
            let every = flow.interval, speed = flow.pace, size = flow.diameter
            // Packet k left at k × every + phase; it's on the route while 0 <= (t − k × every − phase) × speed <= length.
            let phase = Double(turn[i]) / Double(leaving[flow.from]!) * every
            let lo = Int(((t - phase - length / speed) / every).rounded(.up))
            let hi = Int(((t - phase) / every).rounded(.down))
            guard hi >= lo else { continue }
            var style = Style()
            let color = flow.color ?? Flow.defaultColor
            style.fill = color; style.stroke = color; style.strokeWidth = 1.5; style.roughness = 0
            for k in max(lo, hi - Flow.maxPackets + 1)...hi {
                let d = (t - Double(k) * every - phase) * speed
                let p = line.point(at: d / length)
                out.append(Element(id: Flow.packetID(flow.id, k), kind: .ellipse,
                                   frame: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size),
                                   style: style, seed: 1, layerID: source.layerID))
            }
        }
        return out
    }
}

extension DiagramOps {
    /// Adds a flow (or with `replacing`, changes that one) and makes sure the page plays: a timeline at least `loop`
    /// seconds long (4 by default), with `every` rounded so the timeline is a whole number of packets and loops
    /// seamlessly. Returns the flow.
    @discardableResult
    public static func addFlow(_ doc: inout DottieDocument, from: UUID, to: [UUID], every: Double? = nil, speed: Double? = nil,
                               color: RGBA? = nil, size: Double? = nil, when: String? = nil,
                               replacing: UUID? = nil) throws -> Flow {
        let shapes = Set(doc.elements.filter { $0.kind != .connector }.map(\.id))
        guard shapes.contains(from) else { throw OpsError.notFound("Traffic leaves from a shape on the page; no shape \(from.uuidString)") }
        guard !to.isEmpty else { throw OpsError.invalid("A flow needs at least one destination") }
        if let bad = to.first(where: { !shapes.contains($0) }) { throw OpsError.notFound("No shape \(bad.uuidString) to send traffic to") }
        let condition = try when.flatMap(PageState.checked)
        if doc.timeline == nil { doc.timeline = Timeline(duration: 4) }
        let duration = max(doc.timeline!.duration, 0.05)
        var flow = Flow(id: replacing ?? UUID(), from: from, to: to, every: nil, speed: speed, color: color, size: size, when: condition)
        if let every, every.isFinite, every > 0 {
            let n = max(1, (duration / min(max(every, 0.05), 60)).rounded())
            flow.every = duration / n
        } else {
            let n = max(1, (duration / Flow.defaultEvery).rounded())
            if abs(duration / n - Flow.defaultEvery) > 1e-9 { flow.every = duration / n }
        }
        var list = doc.flows ?? []
        if let replacing {
            guard let i = list.firstIndex(where: { $0.id == replacing }) else { throw OpsError.notFound("No flow \(replacing.uuidString)") }
            list[i] = flow
        } else {
            list.append(flow)
        }
        doc.flows = list
        return flow
    }

    /// Removes a flow. Returns whether there was one.
    @discardableResult
    public static func removeFlow(_ doc: inout DottieDocument, _ id: UUID) -> Bool {
        guard let i = doc.flows?.firstIndex(where: { $0.id == id }) else { return false }
        doc.flows!.remove(at: i)
        if doc.flows!.isEmpty { doc.flows = nil }
        return true
    }

    /// One line per flow for a listing: where it goes now (at the starting values), or that it can't get there.
    public static func describeFlows(_ doc: DottieDocument) -> [String] {
        let frame = doc.posed(at: 0)
        let values = doc.stateValues(.initial)
        let offline = Set(doc.elements.filter { $0.activeOverrides(values).contains { $0.offline == true } }.map(\.id))
        let names = Dictionary(doc.elements.map { ($0.id, $0.text.map { "\"\($0)\"" } ?? $0.id.uuidString) }, uniquingKeysWith: { a, _ in a })
        return (doc.flows ?? []).map { f in
            var line = "flow \(f.id.uuidString): \(names[f.from] ?? "?") → " + f.to.map { names[$0] ?? "?" }.joined(separator: " or ")
            line += String(format: ", every %.2gs at %g pt/s", f.interval, f.pace)
            if let w = f.when { line += ", when \(w)" }
            if let hops = DottieDocument.flowRoute(from: f.from, to: f.to, in: frame, offline: offline) {
                line += ", now \(hops.count) hop\(hops.count == 1 ? "" : "s")"
            } else {
                line += ", now can't reach any destination"
            }
            return line
        }
    }
}
