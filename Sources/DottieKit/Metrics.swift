import Foundation
import CoreGraphics

// Capacity, metrics and gauges (ADR 0003). Each frame, the page's flows are assigned to routes in page order, as
// much as each route has room for; the packets drawn and the metrics shown both come from that assignment, so a
// frame stays a pure function of the page, the time and the variables. web/src/measure.ts mirrors this file.

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

/// Every metric of one frame (ADR 0003).
public struct FrameMetrics: Equatable, Sendable {
    public var elements: [UUID: ElementMetrics] = [:]
    public var flows: [UUID: FlowMetrics] = [:]
    /// How much each flow's queue at each shape holds (`DottieDocument.queueKey`): what a player carries over when
    /// the state changes, so the queue drains from there.
    public var queues: [String: Double] = [:]

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

/// Below this, volume and leftover capacity count as none, in both languages.
private let tiny = 1e-9

extension DottieDocument {
    /// One flow's share of a route.
    private struct Placement {
        var hops: [(UUID, Bool)]
        /// The shapes it passes, from the source to the goal.
        var shapes: [UUID]
        var goal: UUID
        var amount: Double
    }

    /// The key of a flow's queue at a shape in `FrameMetrics.queues` and `carried`.
    public static func queueKey(shape: UUID, flow: UUID) -> String { shape.uuidString + "|" + flow.uuidString }

    /// The packets the page's flows draw in `frame` (the page posed at `t`), with these variable values (nil: every
    /// flow runs), and the frame's metrics. `since` is the seconds since the page's state last changed (nil: `t`),
    /// and `carried` how much each flow's queue held at that moment (`FrameMetrics.queues` then; ADR 0003): since
    /// then a queue grows by its backlog, or drains at the room its way on has left.
    func flowFrame(in frame: DottieDocument, at t: Double, values: [String: Bool]?, offline: Set<UUID> = [],
                   since: Double? = nil, carried: [String: Double] = [:]) -> (packets: [Element], metrics: FrameMetrics) {
        let since = max(0, min(since ?? t, 1e6))
        let byID = frame.elementIndex
        var metrics = FrameMetrics()
        for e in frame.elements where e.kind != .connector || e.connector != nil {
            var m = ElementMetrics()
            if e.kind != .connector { m.delay = Self.delayOf(e) }
            metrics.elements[e.id] = m
        }
        let flows = flows ?? []
        // Room left on everything with a capacity.
        var room: [UUID: Double] = [:]
        for e in frame.elements { if let c = e.capacity, c.isFinite { room[e.id] = max(c, 0) } }
        func full() -> Set<UUID> { Set(room.filter { $0.value <= tiny }.keys) }
        // The cheapest way to `goal` and the shapes on it.
        func route(_ tree: FlowTree, _ goal: UUID) -> (hops: [(UUID, Bool)], shapes: [UUID]) {
            var hops: [(UUID, Bool)] = [], shapes: [UUID] = []
            var at = goal
            while let step = tree.came[at] { hops.append((step.via, step.back)); shapes.append(at); at = step.from }
            shapes.append(at)
            return (hops.reversed(), shapes.reversed())
        }
        // A route as drawn: its line, length, the stretches inside the shapes it passes (with their delays), and
        // each hop's stretch.
        struct Way { var line: Polyline; var length: Double; var inside: [(Double, Double, Double)]; var stretches: [(UUID, Double, Double)] }
        func way(_ hops: [(UUID, Bool)], _ shapes: [UUID]) -> Way? {
            var points: [CGPoint] = [], inside: [(Double, Double, Double)] = [], stretches: [(UUID, Double, Double)] = []
            var length = 0.0
            for (k, (id, back)) in hops.enumerated() {
                guard let c = byID[id] else { continue }
                var line = Polyline(tracing: c, in: frame).points
                if back { line.reverse() }
                guard let head = line.first else { continue }
                if let last = points.last {
                    let gap = Double(hypot(head.x - last.x, head.y - last.y))
                    inside.append((length, length + gap, byID[shapes[k]].map(Self.delayOf) ?? 0))
                    length += gap
                }
                let start = length
                for (a, b) in zip(line, line.dropFirst()) { length += Double(hypot(b.x - a.x, b.y - a.y)) }
                stretches.append((id, start, length))
                points += line
            }
            return length > 0 ? Way(line: Polyline(points), length: length, inside: inside, stretches: stretches) : nil
        }
        // Where a packet is `elapsed` seconds after leaving along `w`: nil while hidden inside a shape or off the end.
        func along(_ w: Way, _ elapsed: Double, speed: Double) -> Double? {
            var elapsed = elapsed, d = 0.0
            for (a, b, delay) in w.inside {
                let reach = (a - d) / speed
                if elapsed <= reach { break }
                elapsed -= reach; d = a
                let stay = (b - a) / speed + delay
                if elapsed < stay { return nil }
                elapsed -= stay; d = b
            }
            d += elapsed * speed
            return d >= 0 && d <= w.length ? d : nil
        }
        func dot(_ id: UUID, _ center: CGPoint, _ size: Double, _ style: Style, _ layer: UUID) -> Element {
            Element(id: id, kind: .ellipse, frame: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
                    style: style, seed: 1, layerID: layer)
        }

        // Flows leaving the same shape take turns; the page's biggest flow draws a packet every `every` seconds.
        var leaving: [UUID: Int] = [:], turn: [Int] = []
        for flow in flows { turn.append(leaving[flow.from, default: 0]); leaving[flow.from, default: 0] += 1 }
        let biggest = flows.map(\.amount).max() ?? 1
        var packets: [Element] = []
        var waitingBy: [UUID: [(UUID, Double)]] = [:]

        for (i, flow) in flows.enumerated() {
            if let w = flow.when, let values, !PageState.holds(w, in: values) { continue }
            guard let source = byID[flow.from], let base = Self.flowTree(from: flow.from, in: frame, offline: offline) else { continue }
            let volume = flow.amount
            var fm = FlowMetrics(); fm.volume = volume
            var placements: [Placement] = []
            var waiting: [(UUID, Double)] = []
            // Spread: while the first destination is down, the volume is shared equally by the rest.
            let goals = base.goals(flow.to, spread: flow.spread == true)
            let shares: [([UUID], Double)] = goals.count > 1 ? goals.map { ([$0], volume / Double(goals.count)) } : [(flow.to, volume)]
            for (candidates, amount) in shares where amount > tiny {
                var left = amount
                for _ in 0..<32 where left > tiny {
                    guard let tree = Self.flowTree(from: flow.from, in: frame, offline: offline.union(full())),
                          let goal = tree.goals(candidates, spread: false).first else { break }
                    let r = route(tree, goal)
                    let ids = r.shapes + r.hops.map(\.0)
                    let fits = min(left, ids.compactMap { room[$0] }.min() ?? .infinity)
                    guard fits > tiny else { break }
                    for id in ids where room[id] != nil { room[id]! -= fits }
                    placements.append(Placement(hops: r.hops, shapes: r.shapes, goal: goal, amount: fits))
                    left -= fits
                }
                guard left > tiny else { continue }
                // What doesn't fit waits in front of the first full thing on its cheapest way (ignoring capacity).
                var at = flow.from
                if let goal = base.goals(candidates, spread: false).first {
                    let r = route(base, goal), done = full()
                    var sequence: [(UUID, UUID)] = [(r.shapes[0], r.shapes[0])]   // (element, the shape before it)
                    for (k, hop) in r.hops.enumerated() { sequence += [(hop.0, r.shapes[k]), (r.shapes[k + 1], r.shapes[k])] }
                    if let first = sequence.first(where: { done.contains($0.0) }) { at = first.1 }
                }
                if let k = waiting.firstIndex(where: { $0.0 == at }) { waiting[k].1 += left } else { waiting.append((at, left)) }
            }
            waitingBy[flow.id] = waiting

            // Metrics.
            for p in placements {
                for id in p.shapes + p.hops.map(\.0) { metrics.elements[id]?.throughput += p.amount }
                fm.placed += p.amount
            }
            for (at, amount) in waiting { metrics.elements[at]?.backlog += amount; fm.backlog += amount }
            let reachedFirst = placements.filter { $0.goal == flow.to.first }.reduce(0) { $0 + $1.amount }
            fm.backup = volume > tiny ? max(0, (volume - reachedFirst) / volume) : 0

            // Packets: dealt across the placements by their share of the volume.
            let every = min(max(flow.interval * biggest / max(volume, tiny), 0.05), 60)
            let speed = flow.pace, size = flow.diameter
            let phase = Double(turn[i]) / Double(leaving[flow.from]!) * every
            let style = Self.packetStyle(flow)
            var cumulative: [Double] = []
            var sum = 0.0
            for p in placements { sum += p.amount / max(volume, tiny); cumulative.append(sum) }
            if let last = cumulative.indices.last, abs(cumulative[last] - 1) < 1e-9 { cumulative[last] = 1 }
            var transitSum = 0.0
            for (r, p) in placements.enumerated() {
                guard let w = way(p.hops, p.shapes) else { continue }
                let travel = w.length / speed + w.inside.reduce(0) { $0 + $1.2 }
                transitSum += travel * p.amount
                let lo = Int(((t - phase - travel) / every).rounded(.up))
                let hi = Int(((t - phase) / every).rounded(.down))
                let below = r == 0 ? 0 : cumulative[r - 1], upTo = cumulative[r]
                func dealt(_ c: Double, _ k: Int) -> Double { ((Double(k) + 1) * c).rounded(.down) - (Double(k) * c).rounded(.down) }
                var k = max(lo, hi - 3999)
                while k <= hi {
                    defer { k += 1 }
                    guard dealt(upTo, k) - dealt(below, k) == 1, let d = along(w, t - Double(k) * every - phase, speed: speed) else { continue }
                    if let s = w.stretches.first(where: { d >= $0.1 && d <= $0.2 }) { metrics.elements[s.0]?.inFlight += 1 }
                    packets.append(dot(Flow.packetID(flow.id, k), w.line.point(at: d / w.length), size, style, source.layerID))
                }
            }
            fm.transit = fm.placed > tiny ? transitSum / fm.placed : nil
            metrics.flows[flow.id] = fm
        }

        // Queues: each flow's at each shape, its own or carried over from before the state changed. One with backlog
        // grows by it; one without drains at the room left on its way on, and the drained traffic leaves as packets,
        // using that room. Drawn as a pile above the shape (up to 30 a flow, in rows of 10).
        var piles: [UUID: Int] = [:]
        for flow in flows {
            let waiting = waitingBy[flow.id] ?? []
            var shapes = waiting.map(\.0)
            let held = frame.elements.map(\.id).filter { carried[Self.queueKey(shape: $0, flow: flow.id)].map { $0 > tiny } == true }
            for s in held where !shapes.contains(s) { shapes.append(s) }
            guard !shapes.isEmpty else { continue }
            let volume = flow.amount
            let every = min(max(flow.interval * biggest / max(volume, tiny), 0.05), 60)
            let unit = every * max(volume, tiny)   // the volume one packet stands for, times a second
            let speed = flow.pace, size = flow.diameter, style = Self.packetStyle(flow)
            for (j, at) in shapes.enumerated() {
                guard let shape = byID[at] else { continue }
                let layer = byID[flow.from]?.layerID ?? shape.layerID
                let backlog = waiting.first { $0.0 == at }?.1 ?? 0
                let before = max(0, carried[Self.queueKey(shape: at, flow: flow.id)] ?? 0)
                var depth = before + backlog * since
                // Drain: at the most the cheapest way on to the flow's first reachable destination has room for. A
                // queue with nowhere to go, or no room on the way, holds.
                if backlog <= tiny, before > tiny,
                   let tree = Self.flowTree(from: at, in: frame, offline: offline.union(full())),
                   let goal = tree.goals(flow.to, spread: false).first {
                    let r = route(tree, goal)
                    let ids = Array(r.shapes.dropFirst()) + r.hops.map(\.0)
                    let spare = ids.compactMap { room[$0] }.min() ?? .infinity
                    let rate = spare.isFinite ? spare : before / 0.5
                    if rate > tiny {
                        depth = max(0, before - rate * since)
                        if depth > tiny {
                            for id in r.shapes + r.hops.map(\.0) { metrics.elements[id]?.throughput += rate }
                            for id in ids where room[id] != nil { room[id]! -= rate }
                        }
                        // The drained traffic: packets leaving the queue while it empties.
                        if let w = way(r.hops, r.shapes) {
                            let spacing = max(unit / rate, 0.05), lasts = before / rate
                            var k = 0
                            while Double(k) * spacing < lasts, Double(k) * spacing <= since, k < 4000 {
                                defer { k += 1 }
                                guard let d = along(w, since - Double(k) * spacing, speed: speed) else { continue }
                                packets.append(dot(Flow.packetID(flow.id, (1 << 39) + (1 << 20) + j * (1 << 14) + k),
                                                   w.line.point(at: d / w.length), size, style, layer))
                            }
                        }
                    }
                }
                guard depth > tiny || backlog > tiny else { continue }
                metrics.elements[at]?.depth += depth
                if depth > tiny { metrics.queues[Self.queueKey(shape: at, flow: flow.id)] = depth }
                let n = Int(min(max((depth / unit - 1e-9).rounded(.up), 1), 30))
                let rows = (n + 9) / 10
                let base = piles[at, default: 0]; piles[at] = base + rows
                for q in 0..<n {
                    let center = CGPoint(x: shape.x + 2 + size / 2 + Double(q % 10) * (size + 3),
                                         y: shape.y - 4 - size / 2 - Double(base + q / 10) * (size + 3))
                    packets.append(dot(Flow.packetID(flow.id, (1 << 39) + j * 64 + q), center, size, style, layer))
                }
            }
        }
        for e in frame.elements {
            guard let c = e.capacity, c.isFinite, var m = metrics.elements[e.id] else { continue }
            m.load = c > 0 ? m.throughput / c : 1
            metrics.elements[e.id] = m
        }
        return (packets, metrics)
    }

    /// How a flow's packets look.
    static func packetStyle(_ flow: Flow) -> Style {
        var style = Style()
        let color = flow.color ?? Flow.defaultColor
        style.fill = color; style.stroke = color; style.strokeWidth = 1.5; style.roughness = 0
        return style
    }

    /// A shape's delay as traffic feels it: 0...3600 seconds.
    static func delayOf(_ e: Element) -> Double {
        guard e.kind != .connector, let d = e.delay, d.isFinite else { return 0 }
        return min(max(d, 0), 3600)
    }

    /// The metrics of the page at `t` (ADR 0003).
    public func metrics(at t: Double = 0, state: StateChoice = .initial, since: Double? = nil,
                        carried: [String: Double] = [:]) -> FrameMetrics {
        posedWithMetrics(at: t, state: state, since: since, carried: carried).metrics
    }
}

// MARK: Overrides that compare metrics, and gauges

extension DottieDocument {
    /// The frame's metric for a condition's comparison: its target is an element's anchor, or an element's or a
    /// flow's id.
    static func metricLookup(_ metrics: FrameMetrics, in frame: DottieDocument) -> (PageState.MetricTerm) -> Double? {
        var anchors: [String: UUID] = [:]
        for e in frame.elements { if let a = e.anchor, anchors[a] == nil { anchors[a] = e.id } }
        return { term in
            guard let id = anchors[term.target] ?? UUID(uuidString: term.target) else { return nil }
            return metrics.value(term.metric, of: id)
        }
    }

    /// `elements` with the looks of overrides that compare metrics applied, and gauges drawn as plain elements;
    /// with no values (`.all`, the editor), both are left as they are.
    static func finishing(_ elements: [Element], metrics: FrameMetrics, values: [String: Bool]?, frame: DottieDocument,
                          flows: [Flow]) -> [Element] {
        let lookup = metricLookup(metrics, in: frame)
        var out: [Element] = []
        for var e in elements {
            if let values, let overrides = e.overrides {
                for o in overrides where PageState.mentionsMetric(o.when) && PageState.holds(o.when, in: values, metric: lookup) {
                    e = o.looksOnly.apply(to: e)
                }
            }
            // The editor (`.all`, no values) edits the gauge itself, a rectangle.
            if let g = e.gauge, values != nil { out += gauge(e, g, metrics: metrics, frame: frame, flows: flows) } else { out.append(e) }
        }
        return out
    }

    static let gaugeGreen = RGBA(hex: "#16a34a")!, gaugeAmber = RGBA(hex: "#d97706")!, gaugeRed = RGBA(hex: "#dc2626")!
    static let gaugeBlue = RGBA(hex: "#2f6fdf")!, gaugeTrack = RGBA(hex: "#e5e7eb")!, gaugeGray = RGBA(hex: "#9ca3af")!

    /// A metric's value as a gauge shows it: a percentage for load and backup, seconds for transit and delay.
    static func formatted(_ metric: String, _ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        switch metric {
        case "load", "backup": return number(v * 100, places: 0) + "%"
        case "transit", "delay": return number(v, places: abs(v) >= 10 ? 1 : 2) + "s"
        default: return number(v, places: abs(v) >= 100 ? 0 : abs(v) >= 10 ? 1 : 2)
        }
    }

    /// `v` to `places` decimals, halves away from zero, trailing zeros dropped: the same text in both languages.
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

    /// A gauge drawn: its frame as a `.path` carrying the label, then the bar or dial.
    static func gauge(_ e: Element, _ g: Gauge, metrics: FrameMetrics, frame: DottieDocument, flows: [Flow]) -> [Element] {
        let value = metrics.value(g.metric, of: g.of)
        let target = frame.elements.first { $0.id == g.of }
        let full = g.max ?? (g.metric == "load" ? 1 : target?.capacity ?? value ?? 1)
        let fraction = value.map { full > 0 ? min(max($0 / full, 0), 1) : 0 } ?? 0
        let warn = g.warn ?? (g.metric == "load" ? 0.7 : nil), alarm = g.alarm ?? (g.metric == "load" ? 0.9 : nil)
        var color = warn == nil && alarm == nil ? gaugeBlue : gaugeGreen
        if let v = value, let warn, v >= warn { color = gaugeAmber }
        if let v = value, let alarm, v >= alarm { color = gaugeRed }
        if value == nil { color = gaugeGray }
        let name = g.label ?? {
            let what = target.flatMap { $0.text?.components(separatedBy: "\n").first ?? $0.anchor }
                ?? (flows.contains { $0.id == g.of } ? "flow" : "?")
            return "\(g.metric) \(what)"
        }()
        let style = g.style ?? .number
        let w = max(e.width, 1), h = max(e.height, 1)
        // Normalized cubic contours from points in the gauge's own coordinates.
        func line(_ a: CGPoint, _ b: CGPoint) -> [Double] {
            [a.x / w, a.y / h, (a.x + (b.x - a.x) / 3) / w, (a.y + (b.y - a.y) / 3) / h,
             (a.x + 2 * (b.x - a.x) / 3) / w, (a.y + 2 * (b.y - a.y) / 3) / h, b.x / w, b.y / h]
        }
        func box(_ r: CGRect) -> PathSubpath {
            let p = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            var coords = line(p[0], p[1])
            for k in 1..<4 { coords += line(p[k], p[(k + 1) % 4]).dropFirst(2) }
            return PathSubpath(closed: true, coords: coords)
        }
        func arc(_ c: CGPoint, _ radius: Double, from a0: Double, to a1: Double) -> PathSubpath {
            // Clockwise on screen from a0 to a1 (radians, y down), in pieces of at most 90°.
            let pieces = max(1, Int((abs(a1 - a0) / (.pi / 2) - 1e-9).rounded(.up)))
            let step = (a1 - a0) / Double(pieces), kappa = 4.0 / 3 * tan(step / 4)
            func at(_ a: Double) -> CGPoint { CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a)) }
            let s = at(a0)
            var coords = [s.x / w, s.y / h]
            for k in 0..<pieces {
                let a = a0 + Double(k) * step, b = a + step
                let p0 = at(a), p3 = at(b)
                let c1 = CGPoint(x: p0.x - kappa * radius * sin(a), y: p0.y + kappa * radius * cos(a))
                let c2 = CGPoint(x: p3.x + kappa * radius * sin(b), y: p3.y - kappa * radius * cos(b))
                coords += [c1.x / w, c1.y / h, c2.x / w, c2.y / h, p3.x / w, p3.y / h]
            }
            return PathSubpath(closed: false, coords: coords)
        }
        func part(_ k: Int, _ subpaths: [PathSubpath], stroke: RGBA, fill: RGBA?, width: Double) -> Element {
            var s = Style()
            s.stroke = stroke; s.strokeWidth = width; s.roughness = 0; s.opacity = e.style.opacity
            if let fill { s.fill = fill; s.fillStyle = .solid } else { s.fill = RGBA(r: 0, g: 0, b: 0, a: 0) }
            var p = Element(id: Flow.packetID(e.id, -(1 << 38) - k), kind: .path, frame: e.frame, style: s, seed: 1, layerID: e.layerID)
            p.subpaths = subpaths
            return p
        }

        var back = e
        back.gauge = nil
        back.kind = .path
        back.subpaths = [box(CGRect(x: 0, y: 0, width: w, height: h))]
        back.text = name + "\n" + formatted(g.metric, value)
        var parts: [Element] = []
        switch style {
        case .number:
            back.labelRect = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            back.style.textColor = color
        case .bar:
            back.labelRect = NormalizedRect(x: 0, y: 0, width: 1, height: 0.66)
            let inset = min(10, w * 0.08), barH = min(12, h * 0.18), top = h * 0.72
            let track = CGRect(x: inset, y: top, width: w - 2 * inset, height: barH)
            parts.append(part(1, [box(track)], stroke: gaugeTrack, fill: gaugeTrack, width: 0.5))
            if fraction > 0 {
                parts.append(part(2, [box(CGRect(x: inset, y: top, width: track.width * fraction, height: barH))], stroke: color, fill: color, width: 0.5))
            }
        case .dial:
            back.labelRect = NormalizedRect(x: 0, y: 0.54, width: 1, height: 0.46)
            let radius = min(w * 0.38, h * 0.4), center = CGPoint(x: w / 2, y: h * 0.5)
            let thick = max(2, radius * 0.16)
            parts.append(part(1, [arc(center, radius, from: .pi, to: 2 * .pi)], stroke: gaugeTrack, fill: nil, width: thick))
            if fraction > 0 {
                parts.append(part(2, [arc(center, radius, from: .pi, to: .pi + .pi * fraction)], stroke: color, fill: nil, width: thick))
            }
            let a = .pi + .pi * fraction
            let tip = CGPoint(x: center.x + radius * 0.85 * cos(a), y: center.y + radius * 0.85 * sin(a))
            parts.append(part(3, [PathSubpath(closed: false, coords: line(center, tip))], stroke: RGBA(r: 0.2, g: 0.2, b: 0.2), fill: nil, width: 2))
        }
        return [back] + parts
    }
}

// MARK: Editing

extension DiagramOps {
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
    public static func describeMetrics(_ doc: DottieDocument, at t: Double = 0, state: StateChoice = .initial,
                                       since: Double? = nil, carried: [String: Double] = [:]) -> [String] {
        let m = doc.metrics(at: t, state: state, since: since, carried: carried)
        var names = Dictionary(doc.elements.map { ($0.id, $0.text.map { "\"\($0.components(separatedBy: "\n")[0])\"" } ?? $0.anchor ?? $0.id.uuidString) },
                               uniquingKeysWith: { a, _ in a })
        // An unlabelled connector is named by its ends.
        for e in doc.elements where e.kind == .connector && e.text == nil && e.anchor == nil {
            if let a = e.connector?.start.elementID, let b = e.connector?.end.elementID, let na = names[a], let nb = names[b] { names[e.id] = "\(na) → \(nb)" }
        }
        func n(_ v: Double) -> String { DottieDocument.number(v, places: 2) }
        var out: [String] = []
        for e in doc.elements {
            guard let x = m.elements[e.id], x.throughput > 0 || x.load != nil || x.backlog > 0 || x.delay > 0 || x.depth > 0 else { continue }
            var parts = ["throughput \(n(x.throughput))"]
            if let l = x.load { parts.append("load \(DottieDocument.formatted("load", l))") }
            if x.backlog > 0 { parts.append("backlog \(n(x.backlog)) (piled up \(n(x.depth)))") }
            else if x.depth > 0 { parts.append("draining, \(n(x.depth)) left") }
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
