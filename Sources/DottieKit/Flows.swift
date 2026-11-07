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
    /// When the first destination can't be reached, deal packets in turn across every other one that can, rather
    /// than sending them all to the next.
    public var spread: Bool?
    /// How much it carries, in the page's own unit (ADR 0003); nil is 1. The page's biggest flow draws a packet
    /// every `every` seconds, and the rest proportionally fewer.
    public var volume: Double?

    public init(id: UUID = UUID(), from: UUID, to: [UUID], every: Double? = nil, speed: Double? = nil,
                color: RGBA? = nil, size: Double? = nil, when: String? = nil, spread: Bool? = nil, volume: Double? = nil) {
        self.id = id; self.from = from; self.to = to; self.every = every; self.speed = speed
        self.color = color; self.size = size; self.when = when; self.spread = spread == true ? true : nil
        self.volume = volume
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
        spread = ((try? c.decodeIfPresent(Bool.self, forKey: .spread)) ?? nil) == true ? true : nil
        volume = number(.volume)
    }

    public static let defaultEvery = 0.5, defaultSpeed = 160.0, defaultSize = 12.0
    public static let defaultColor = RGBA(r: 0.95, g: 0.36, b: 0.33)
    /// The most packets one flow draws in a frame.
    static let maxPackets = 400

    /// `every`, `speed` and `size` as drawn: defaults for nil, kept within sensible bounds.
    var interval: Double { Self.clamp(every, Self.defaultEvery, 0.05, 60) }
    var pace: Double { Self.clamp(speed, Self.defaultSpeed, 1, 10000) }
    var diameter: Double { Self.clamp(size, Self.defaultSize, 2, 200) }
    /// `volume` as assigned: 1 for nil, within 0...1e12.
    var amount: Double { Self.clamp(volume, 1, 0, 1e12) }
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
    /// Every shape traffic from `from` can reach in `frame`, with the cheapest way to each: by the connectors'
    /// `cost` (1 each unless set), ties to the shape reached first, earlier connectors first (ADR 0002), so with no
    /// costs set it's the fewest hops. Nil when `from` isn't drawn or is offline. `offline` elements (an override says
    /// so) carry nothing: traffic neither leaves, passes nor arrives through them.
    static func flowTree(from: UUID, in frame: DottieDocument, offline: Set<UUID> = []) -> FlowTree? {
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
        // with equal costs it settles shapes in breadth-first order and web/src/flows.ts picks the same routes.
        var dist: [UUID: Double] = [from: 0], order: [UUID: Int] = [from: 0], counter = 1
        var tree = FlowTree(from: from)
        var open: [UUID] = [from]
        while !open.isEmpty {
            var best = 0
            for i in 1..<open.count {
                let (a, b) = (open[i], open[best])
                if dist[a]! < dist[b]! || (dist[a]! == dist[b]! && order[a]! < order[b]!) { best = i }
            }
            let n = open.remove(at: best)
            tree.settled.insert(n)
            for edge in next[n] ?? [] where !tree.settled.contains(edge.to) {
                let d = dist[n]! + edge.cost
                if let old = dist[edge.to], old <= d { continue }
                if dist[edge.to] == nil { open.append(edge.to) }
                dist[edge.to] = d; order[edge.to] = counter; counter += 1
                tree.came[edge.to] = (n, edge.via, edge.back)
            }
        }
        return tree
    }

    struct FlowTree {
        let from: UUID
        var settled: Set<UUID> = []
        var came: [UUID: (from: UUID, via: UUID, back: Bool)] = [:]

        /// The destinations a flow sends to: the first of `to` that can be reached; with `spread`, when the first
        /// can't be, every other one that can.
        func goals(_ to: [UUID], spread: Bool) -> [UUID] {
            let reachable = to.filter { $0 != from && settled.contains($0) }
            guard let first = reachable.first else { return [] }
            return spread && first != to.first ? reachable : [first]
        }

        /// The connectors to `goal`, as (connector, backwards) hops.
        func hops(to goal: UUID) -> [(UUID, Bool)] {
            var hops: [(UUID, Bool)] = []
            var at = goal
            while let step = came[at] { hops.append((step.via, step.back)); at = step.from }
            return hops.reversed()
        }
    }

    /// The connectors traffic takes from `from` to the first of `to` it reaches in `frame`, as (connector, backwards)
    /// hops; nil when none can be reached.
    static func flowRoute(from: UUID, to: [UUID], in frame: DottieDocument, offline: Set<UUID> = []) -> [(UUID, Bool)]? {
        guard let tree = flowTree(from: from, in: frame, offline: offline), let goal = tree.goals(to, spread: false).first else { return nil }
        return tree.hops(to: goal)
    }
}

extension DiagramOps {
    /// Adds a flow (or with `replacing`, changes that one) and makes sure the page plays: a timeline at least `loop`
    /// seconds long (4 by default), with `every` rounded so the timeline is a whole number of packets and loops
    /// seamlessly. Returns the flow.
    @discardableResult
    public static func addFlow(_ doc: inout DottieDocument, from: UUID, to: [UUID], every: Double? = nil, speed: Double? = nil,
                               color: RGBA? = nil, size: Double? = nil, when: String? = nil, spread: Bool? = nil,
                               volume: Double? = nil, replacing: UUID? = nil) throws -> Flow {
        let shapes = Set(doc.elements.filter { $0.kind != .connector }.map(\.id))
        guard shapes.contains(from) else { throw OpsError.notFound("Traffic leaves from a shape on the page; no shape \(from.uuidString)") }
        guard !to.isEmpty else { throw OpsError.invalid("A flow needs at least one destination") }
        if let bad = to.first(where: { !shapes.contains($0) }) { throw OpsError.notFound("No shape \(bad.uuidString) to send traffic to") }
        let condition = try when.flatMap { try PageState.checked($0) }
        if doc.timeline == nil { doc.timeline = Timeline(duration: 4) }
        let duration = max(doc.timeline!.duration, 0.05)
        var flow = Flow(id: replacing ?? UUID(), from: from, to: to, every: nil, speed: speed, color: color, size: size, when: condition, spread: spread,
                        volume: volume.flatMap { $0.isFinite ? max($0, 0) : nil })
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
            if f.spread == true { line += ", spread when the first is down" }
            if let v = f.volume { line += ", volume \(DottieDocument.number(v, places: 2))" }
            if let hops = DottieDocument.flowRoute(from: f.from, to: f.to, in: frame, offline: offline) {
                line += ", now \(hops.count) hop\(hops.count == 1 ? "" : "s")"
            } else {
                line += ", now can't reach any destination"
            }
            return line
        }
    }
}
