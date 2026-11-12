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
    /// Instead of `volume`, an expression of the page's variables and `time` worked out each frame (ADR 0008), such
    /// as a ramp: `"clamp((time - 15) * 180, 0, 3400)"`. Saved as `volume`, a string.
    public var volumeExpression: String?
    /// Its volume, or destinations, while a condition on the page's variables holds, the last that holds winning: a
    /// spike, peak season, a router sending a caller elsewhere.
    public var overrides: [FlowOverride]?

    enum CodingKeys: String, CodingKey { case id, from, to, every, speed, color, size, when, spread, volume, overrides }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(from, forKey: .from); try c.encode(to, forKey: .to)
        try c.encodeIfPresent(every, forKey: .every); try c.encodeIfPresent(speed, forKey: .speed)
        try c.encodeIfPresent(color, forKey: .color); try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(when, forKey: .when); try c.encodeIfPresent(spread, forKey: .spread)
        if let e = volumeExpression { try c.encode(e, forKey: .volume) } else { try c.encodeIfPresent(volume, forKey: .volume) }
        try c.encodeIfPresent(overrides, forKey: .overrides)
    }

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
        volumeExpression = (try? c.decodeIfPresent(String.self, forKey: .volume)) ?? nil
        overrides = ((try? c.decodeIfPresent([FlowOverride].self, forKey: .overrides)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
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

/// A flow's volume while a condition holds (`Flow.overrides`).
public struct FlowOverride: Codable, Equatable, Sendable {
    public var when: String
    public var volume: Double?
    /// Instead of `volume`, an expression of the variables and `time` (ADR 0008); saved as `volume`, a string.
    public var volumeExpression: String?
    /// Where the flow goes meanwhile, instead of its own `to`; its queues drain there too.
    public var to: [UUID]?
    public init(when: String, volume: Double? = nil, volumeExpression: String? = nil, to: [UUID]? = nil) {
        self.when = when; self.volume = volume; self.volumeExpression = volumeExpression
        self.to = to.flatMap { $0.isEmpty ? nil : $0 }
    }
    enum CodingKeys: String, CodingKey { case when, volume, to }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        when = ((try? c.decodeIfPresent(String.self, forKey: .when)) ?? nil) ?? ""
        volume = ((try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? nil).flatMap { $0.isFinite ? $0 : nil }
        volumeExpression = (try? c.decodeIfPresent(String.self, forKey: .volume)) ?? nil
        to = ((try? c.decodeIfPresent([String].self, forKey: .to)) ?? nil)?.compactMap(UUID.init(uuidString:)).nilIfEmpty
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(when, forKey: .when)
        if let e = volumeExpression { try c.encode(e, forKey: .volume) } else { try c.encodeIfPresent(volume, forKey: .volume) }
        try c.encodeIfPresent(to, forKey: .to)
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

extension DiagramOps {
    /// Adds a flow (or with `replacing`, changes that one) and makes sure the page plays: a timeline at least `loop`
    /// seconds long (4 by default), with `every` rounded so the timeline is a whole number of packets and loops
    /// seamlessly. Returns the flow.
    @discardableResult
    public static func addFlow(_ doc: inout DottieDocument, from: UUID, to: [UUID], every: Double? = nil, speed: Double? = nil,
                               color: RGBA? = nil, size: Double? = nil, when: String? = nil, spread: Bool? = nil,
                               volume: Double? = nil, volumeExpression: String? = nil, overrides: [FlowOverride]? = nil,
                               replacing: UUID? = nil) throws -> Flow {
        let shapes = Set(doc.elements.filter { $0.kind != .connector }.map(\.id))
        guard shapes.contains(from) else { throw OpsError.notFound("Traffic leaves from a shape on the page; no shape \(from.uuidString)") }
        guard !to.isEmpty else { throw OpsError.invalid("A flow needs at least one destination") }
        if let bad = to.first(where: { !shapes.contains($0) }) { throw OpsError.notFound("No shape \(bad.uuidString) to send traffic to") }
        let condition = try when.flatMap { try PageState.checked($0) }
        // A volume can be an expression of the variables and `time` (ADR 0008).
        func expression(_ v: String?) throws -> String? {
            guard let v else { return nil }
            let c = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let e = Expr.parse(c), e.metrics.isEmpty else {
                throw OpsError.invalid("A volume is a number, or an expression of page variables and time, like "
                                       + "\"clamp((time - 15) * 180, 0, 3400)\"; got '\(v)'")
            }
            return c
        }
        let checkedOverrides = try overrides.map { list in
            try list.map { o -> FlowOverride in
                guard let w = try PageState.checked(o.when) else { throw OpsError.invalid("A flow override needs 'when'") }
                if let v = o.volume, !(v.isFinite && v >= 0) { throw OpsError.invalid("A flow override's volume is 0 or more") }
                if let bad = o.to?.first(where: { !shapes.contains($0) }) { throw OpsError.notFound("No shape \(bad.uuidString) for a flow override to send traffic to") }
                return FlowOverride(when: w, volume: o.volume, volumeExpression: try expression(o.volumeExpression), to: o.to)
            }
        }
        let checkedExpression = try expression(volumeExpression)
        if doc.timeline == nil { doc.timeline = Timeline(duration: 4) }
        let duration = max(doc.timeline!.duration, 0.05)
        var flow = Flow(id: replacing ?? UUID(), from: from, to: to, every: nil, speed: speed, color: color, size: size, when: condition, spread: spread,
                        volume: volume.flatMap { $0.isFinite ? max($0, 0) : nil })
        flow.volumeExpression = checkedExpression
        flow.overrides = checkedOverrides.flatMap { $0.isEmpty ? nil : $0 }
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
        let names = Dictionary(doc.elements.map { ($0.id, $0.text.map { "\"\($0)\"" } ?? $0.id.uuidString) }, uniquingKeysWith: { a, _ in a })
        return (doc.flows ?? []).map { f in
            var line = "flow \(f.id.uuidString): \(names[f.from] ?? "?") → " + f.to.map { names[$0] ?? "?" }.joined(separator: " or ")
            line += String(format: ", every %.2gs at %g pt/s", f.interval, f.pace)
            if let w = f.when { line += ", when \(w)" }
            if f.spread == true { line += ", spread when the first is down" }
            if let e = f.volumeExpression { line += ", volume \(e)" } else if let v = f.volume { line += ", volume \(DottieDocument.number(v, places: 2))" }
            for o in f.overrides ?? [] {
                if let e = o.volumeExpression { line += ", volume \(e)" } else if let v = o.volume { line += ", volume \(DottieDocument.number(v, places: 2))" }
                if let to = o.to { line += ", to " + to.map { names[$0] ?? "?" }.joined(separator: " or ") }
                line += " when \(o.when)"
            }
            if let hops = route(of: f, in: doc) {
                line += ", now \(hops) hop\(hops == 1 ? "" : "s")"
            } else {
                line += ", now can't reach any destination"
            }
            return line
        }
    }

    /// How many connectors the flow's cheapest way to a destination has at the starting values, whatever its own
    /// condition and volume, as the simulation routes it; nil when it can reach none.
    static func route(of flow: Flow, in doc: DottieDocument) -> Int? {
        var alone = flow
        alone.when = nil; alone.volume = nil; alone.volumeExpression = nil; alone.overrides = nil
        var d = doc
        d.flows = [alone]
        let m = d.metrics(at: 0)
        let n = d.elements.filter { $0.kind == .connector && (m.elements[$0.id]?.throughput ?? 0) > 0 }.count
        return n > 0 ? n : nil
    }
}
