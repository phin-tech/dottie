import Foundation
import CoreGraphics

// Capacity, metrics and gauges (ADR 0003): the model and the metrics' types. Working them out is dottie.js's
// (web/src/measure.ts), run in JavaScriptCore by SimulationEngine (ADR 0004).

/// Shows one metric (ADR 0003). The element it's on is drawn, when the page is posed, as plain paths and a label.
public struct Gauge: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable, CaseIterable { case number, bar, dial }

    /// One of `PageState.metricNames`.
    public var metric: String
    /// The element or flow it measures.
    public var of: UUID
    /// The value a full bar or dial stands for; nil is 1 for load, else the target's capacity, else the value.
    public var max: Double?
    /// At or past these it turns amber, and red.
    public var warn: Double?
    public var alarm: Double?
    public var style: Style?
    /// What it's called; nil names the metric and its target.
    public var label: String?

    public init(metric: String, of: UUID, max: Double? = nil, warn: Double? = nil, alarm: Double? = nil,
                style: Style? = nil, label: String? = nil) {
        self.metric = metric; self.of = of; self.max = max; self.warn = warn; self.alarm = alarm
        self.style = style; self.label = label
    }

    // Lenient, like the rest of the format: a gauge with a bad target or metric loads and shows a dash.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metric = ((try? c.decodeIfPresent(String.self, forKey: .metric)) ?? nil) ?? ""
        of = ((try? c.decodeIfPresent(String.self, forKey: .of)) ?? nil).flatMap(UUID.init(uuidString:))
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func number(_ k: CodingKeys) -> Double? { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil).flatMap { $0.isFinite ? $0 : nil } }
        max = number(.max); warn = number(.warn); alarm = number(.alarm)
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? nil
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
    }
}

/// A connector's or shape's metrics in one frame.
public struct ElementMetrics: Equatable, Sendable {
    /// Volume through it.
    public var throughput = 0.0
    /// Throughput over capacity; nil without a capacity.
    public var load: Double?
    public var delay = 0.0
    /// Volume waiting at it that no route has room for: the rate its queue grows at.
    public var backlog = 0.0
    /// Packets on it (connectors) in this frame.
    public var inFlight = 0
    /// How much has piled up at it: backlog times the seconds since the page's state last changed.
    public var depth = 0.0
}

/// A flow's metrics in one frame.
public struct FlowMetrics: Equatable, Sendable {
    public var volume = 0.0
    /// Volume on a route with room, and volume left waiting.
    public var placed = 0.0
    public var backlog = 0.0
    /// The fraction not reaching its first destination.
    public var backup = 0.0
    /// Seconds end to end (route length over speed, plus delays), weighted by volume; nil when nothing is placed.
    public var transit: Double?
}

/// One way a flow's traffic takes in a frame (`FlowRoute` in web/src/measure.ts).
public struct FlowRoute: Equatable, Sendable {
    /// The shape it reaches: a destination, or the queue it waits in when `waits`.
    public var goal: UUID
    /// The connectors it takes, in order, and whether each is taken backwards (end to start).
    public var hops: [(connector: UUID, backwards: Bool)]
    /// The share of the flow's volume on it.
    public var amount: Double
    public var waits: Bool
    /// The connectors' costs added up.
    public var cost: Double

    public static func == (a: FlowRoute, b: FlowRoute) -> Bool {
        a.goal == b.goal && a.amount == b.amount && a.waits == b.waits && a.cost == b.cost
            && a.hops.map(\.connector) == b.hops.map(\.connector) && a.hops.map(\.backwards) == b.hops.map(\.backwards)
    }
}

/// Every metric of one frame (ADR 0003).
public struct FrameMetrics: Equatable, Sendable {
    public var elements: [UUID: ElementMetrics] = [:]
    /// The ways each flow that runs takes, only when asked for (`posedWithMetrics(routes: true)`); a flow that runs
    /// but reaches nothing has none.
    public var routes: [UUID: [FlowRoute]] = [:]
    public var flows: [UUID: FlowMetrics] = [:]
    /// What a player carries over when the state changes: how much each flow's queue at each shape holds
    /// (`DottieDocument.queueKey`), so it drains from there, and each gauge's reading (`gaugeKey`), so it eases from
    /// there to the new one.
    public var carry: [String: Double] = [:]

    /// `metric` of the element or flow `id`, or nil when it has none.
    public func value(_ metric: String, of id: UUID) -> Double? {
        if let f = flows[id] {
            switch metric {
            case "throughput": return f.placed
            case "backlog": return f.backlog
            case "backup": return f.backup
            case "transit": return f.transit
            default: return nil
            }
        }
        guard let e = elements[id] else { return nil }
        switch metric {
        case "throughput": return e.throughput
        case "load": return e.load
        case "delay": return e.delay
        case "backlog": return e.backlog
        case "inFlight": return Double(e.inFlight)
        case "depth": return e.depth
        default: return nil
        }
    }
}

extension DottieDocument {
    /// The key of a flow's queue at a shape in `FrameMetrics.carry` and `carried`.
    public static func queueKey(shape: UUID, flow: UUID) -> String { shape.uuidString + "|" + flow.uuidString }
    /// The key of a gauge's reading in `FrameMetrics.carry` and `carried`.
    public static func gaugeKey(_ gauge: UUID) -> String { "gauge|" + gauge.uuidString }
    /// How a flow's packets look.
    static func packetStyle(_ flow: Flow) -> Style {
        var style = Style()
        let color = flow.color ?? Flow.defaultColor
        style.fill = color; style.stroke = color; style.strokeWidth = 1.5; style.roughness = 0
        return style
    }

    /// The metrics of the page at `t` (ADR 0003).
    public func metrics(at t: Double = 0, state: StateChoice = .initial, since: Double? = nil,
                        carried: [String: Double] = [:]) -> FrameMetrics {
        posedWithMetrics(at: t, state: state, since: since, carried: carried).metrics
    }
}

// MARK: Numbers as Dottie writes them

extension DottieDocument {
    /// `v` to `places` decimals, halves away from zero, trailing zeros dropped (`formatNumber` in web/src/measure.ts).
    static func number(_ v: Double, places: Int) -> String {
        let scale = places == 0 ? 1.0 : places == 1 ? 10.0 : 100.0
        let n = (abs(v) * scale + 0.5).rounded(.down)
        guard n < 1e15 else { return v < 0 ? "-∞" : "∞" }
        let whole = Int64(n / scale), part = Int64(n) - whole * Int64(scale)
        var s = String(whole)
        if places > 0, part > 0 {
            var digits = String(part)
            while digits.count < places { digits = "0" + digits }
            while digits.hasSuffix("0") { digits.removeLast() }
            s += "." + digits
        }
        return (v < 0 && n > 0 ? "-" : "") + s
    }

    /// A metric's value as Dottie writes it: a percentage for load and backup, seconds for transit and delay (the
    /// text gauges show, `formatted` in web/src/measure.ts).
    static func formatted(_ metric: String, _ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        switch metric {
        case "load", "backup": return number(v * 100, places: 0) + "%"
        case "transit", "delay": return number(v, places: abs(v) >= 10 ? 1 : 2) + "s"
        default: return number(v, places: abs(v) >= 100 ? 0 : abs(v) >= 10 ? 1 : 2)
        }
    }
}

// MARK: Editing

extension DiagramOps {
    /// Marks a shape as a queue, where traffic that can't go on waits (ADR 0003), or not.
    public static func setQueue(_ doc: inout DottieDocument, id: UUID, _ on: Bool) throws {
        guard let i = doc.elements.firstIndex(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
        guard doc.elements[i].kind != .connector else { throw OpsError.invalid("'queue' is for shapes; traffic waits inside them") }
        doc.elements[i].queue = on ? true : nil
    }

    /// Sets an element's capacity and a shape's delay (ADR 0003): nil leaves one as it is, `.some(nil)` clears it.
    public static func setCapacity(_ doc: inout DottieDocument, id: UUID, capacity: Double??, delay: Double??) throws {
        guard let i = doc.elements.firstIndex(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
        if let capacity {
            if let c = capacity, !(c.isFinite && c >= 0) { throw OpsError.invalid("'capacity' is a number, 0 or more") }
            doc.elements[i].capacity = capacity
        }
        if let delay {
            if let d = delay, !(d.isFinite && d >= 0) { throw OpsError.invalid("'delay' is seconds, 0 or more") }
            if delay != nil, doc.elements[i].kind == .connector { throw OpsError.invalid("'delay' is for shapes; traffic waits inside them") }
            doc.elements[i].delay = delay
        }
    }

    /// Adds a gauge showing `metric` of the element or flow `of` (ADR 0003): a clean rectangle that every renderer
    /// draws as a number, bar or dial. Returns it.
    @discardableResult
    public static func addGauge(_ doc: inout DottieDocument, metric: String, of: UUID, frame: CGRect, style: Gauge.Style? = nil,
                                max: Double? = nil, warn: Double? = nil, alarm: Double? = nil, label: String? = nil) throws -> Element {
        guard PageState.metricNames.contains(metric) else {
            throw OpsError.invalid("'metric' is one of \(PageState.metricNames.joined(separator: ", ")), got '\(metric)'")
        }
        guard doc.elements.contains(where: { $0.id == of }) || (doc.flows ?? []).contains(where: { $0.id == of }) else {
            throw OpsError.notFound("No element or flow \(of.uuidString) to measure")
        }
        let w = frame.width > 0 ? frame.width : 160, h = frame.height > 0 ? frame.height : (style == .dial ? 110 : 80)
        var s = Style()
        s.roughness = 0; s.fill = RGBA(r: 1, g: 1, b: 1); s.fillStyle = .solid; s.stroke = RGBA(r: 0.8, g: 0.82, b: 0.85); s.strokeWidth = 1
        s.textColor = RGBA.black
        var e = Element(kind: .rectangle, frame: CGRect(x: frame.minX, y: frame.minY, width: w, height: h), style: s,
                        layerID: doc.layers.first?.id ?? UUID())
        e.gauge = Gauge(metric: metric, of: of, max: max, warn: warn, alarm: alarm, style: style, label: label)
        doc.elements.append(e)
        return e
    }

    /// One line per element and flow with something to show, at the starting values: for a listing or a step of
    /// `simulate`.
    /// What an element is called in a report: its first line of text, its anchor, or its id; an unlabelled
    /// connector by its ends.
    static func reportNames(_ doc: DottieDocument) -> [UUID: String] {
        var names = Dictionary(doc.elements.map { ($0.id, $0.text.map { "\"\($0.components(separatedBy: "\n")[0])\"" } ?? $0.anchor ?? $0.id.uuidString) },
                               uniquingKeysWith: { a, _ in a })
        for e in doc.elements where e.kind == .connector && e.text == nil && e.anchor == nil {
            if let a = e.connector?.start.elementID, let b = e.connector?.end.elementID, let na = names[a], let nb = names[b] { names[e.id] = "\(na) → \(nb)" }
        }
        return names
    }

    /// The ways each flow's traffic takes at `t` in `state`, one line per flow then one per way: where it goes, the
    /// connectors (with ids, so they can be changed), its share and the cost; and why a flow goes nowhere.
    public static func describeRoutes(_ doc: DottieDocument, at t: Double = 0, state: StateChoice = .initial,
                                      since: Double? = nil, carried: [String: Double] = [:]) -> [String] {
        let m = doc.posedWithMetrics(at: t, state: state, since: since, carried: carried, routes: true).metrics
        let names = reportNames(doc)
        func n(_ v: Double) -> String { DottieDocument.number(v, places: 2) }
        var out: [String] = []
        for f in doc.flows ?? [] {
            let head = "flow \(f.id.uuidString.prefix(8)) \(names[f.from] ?? "?") → \(f.to.map { names[$0] ?? "?" }.joined(separator: " or "))"
            guard let ways = m.routes[f.id] else { out.append(head + ": not running (its when doesn't hold)"); continue }
            guard !ways.isEmpty else {
                let shown = doc.posed(at: t, state: state).elements.contains { $0.id == f.from }
                out.append(head + (shown ? ": reaches none of its destinations" : ": its source isn't drawn")); continue
            }
            let volume = m.flows[f.id]?.volume ?? 0
            out.append(head + (ways.count > 1 ? ": \(ways.count) ways" : ""))
            for w in ways {
                let share = volume > 0 ? " (\(DottieDocument.formatted("load", w.amount / volume)))" : ""
                let via = w.hops.map { "\(names[$0.connector] ?? "?") [\($0.connector.uuidString.prefix(8))]\($0.backwards ? " backwards" : "")" }
                out.append("  \(w.waits ? "waits at" : "to") \(names[w.goal] ?? "?"): \(n(w.amount))\(share), cost \(n(w.cost)), via "
                           + (via.isEmpty ? "nothing" : via.joined(separator: ", ")))
            }
        }
        return out
    }

    public static func describeMetrics(_ doc: DottieDocument, at t: Double = 0, state: StateChoice = .initial,
                                       since: Double? = nil, carried: [String: Double] = [:]) -> [String] {
        let m = doc.metrics(at: t, state: state, since: since, carried: carried)
        let names = reportNames(doc)
        func n(_ v: Double) -> String { DottieDocument.number(v, places: 2) }
        var out: [String] = []
        for e in doc.elements {
            guard let x = m.elements[e.id], x.throughput > 0 || x.load != nil || x.backlog > 0 || x.delay > 0 || x.depth > 0 else { continue }
            var parts = ["throughput \(n(x.throughput))"]
            if let l = x.load { parts.append("load \(DottieDocument.formatted("load", l))") }
            if x.backlog > 0 { parts.append("backlog \(n(x.backlog)) (piled up \(n(x.depth)))") }
            else if x.depth > 0 { parts.append("\(n(x.depth)) queued (drains when there's room)") }
            if x.delay > 0 { parts.append("delay \(n(x.delay))s") }
            out.append("\(names[e.id] ?? "?"): " + parts.joined(separator: ", "))
        }
        for f in doc.flows ?? [] {
            guard let x = m.flows[f.id] else { continue }
            var parts = ["placed \(n(x.placed)) of \(n(x.volume))"]
            if x.backlog > 0 { parts.append("backlog \(n(x.backlog))") }
            if x.backup > 0 { parts.append("\(DottieDocument.formatted("load", x.backup)) via backup") }
            if let tr = x.transit { parts.append("transit \(DottieDocument.formatted("transit", tr))") }
            out.append("flow \(f.id.uuidString.prefix(8)) \(names[f.from] ?? "?") → \(f.to.map { names[$0] ?? "?" }.joined(separator: " or ")): "
                       + parts.joined(separator: ", "))
        }
        return out
    }
}
