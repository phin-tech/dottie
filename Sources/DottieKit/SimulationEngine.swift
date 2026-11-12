import Foundation
import JavaScriptCore

/// Runs dottie.js's simulation (web/src/measure.ts, bundled as `PlayerScript.simulation`) in JavaScriptCore, so the
/// app, the CLI, QuickLook and dottie.js share one implementation of flows' assignment and packets, the metrics,
/// the overrides that compare them, and gauges (ADRs 0003 and 0004). One context, used by one caller at a time.
/// If it can't run (a bug in the bundled script), the frame is drawn without traffic, and debug builds stop.
final class SimulationEngine: @unchecked Sendable {
    static let shared = SimulationEngine()

    private let lock = NSLock()
    private var context: JSContext?
    private var frameFunction: JSValue?
    private var pageFunction: JSValue?
    /// The page the context holds (`DottieSim.page`), sent again only when the posed page changes.
    private var lastPage: DottieDocument?
    /// Why the last frame couldn't be worked out, if it couldn't.
    private(set) var failure: String?

    private init() {}

    private func load() -> JSValue? {
        if let frameFunction { return frameFunction }
        guard let context = JSContext() else { failure = "JavaScript is unavailable"; return nil }
        context.evaluateScript(PlayerScript.simulation)
        if let e = context.exception { failure = "Simulation failed to load: \(e)"; return nil }
        let f = context.objectForKeyedSubscript("DottieSim")?.objectForKeyedSubscript("frame")
        let p = context.objectForKeyedSubscript("DottieSim")?.objectForKeyedSubscript("page")
        guard let f, !f.isUndefined, let p, !p.isUndefined else { failure = "Simulation has no frame function"; return nil }
        self.context = context
        frameFunction = f
        pageFunction = p
        return f
    }

    private struct Request: Encodable {
        var t: Double
        var values: [String: Var]?
        var offline: [String]
        var since: Double?
        var carried: [String: Double]
        var routes: Bool
    }

    private struct Response: Decodable {
        struct Element: Decodable { var throughput: Double; var load: Double?; var delay: Double; var backlog: Double; var inFlight: Int; var depth: Double }
        struct Flow: Decodable { var volume: Double; var placed: Double; var backlog: Double; var backup: Double; var transit: Double? }
        var packets: [[Packet]]
        var elements: [String: Element]
        var flows: [String: Flow]
        var carry: [String: Double]
        var finish: [Finish]
        var routes: [String: [Route]]?
    }

    /// One way a flow takes: `[goal, [[connector, backwards], ...], amount, waits, cost]`.
    private struct Route: Decodable {
        var route: FlowRoute
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            func id(_ s: String) throws -> UUID {
                guard let u = UUID(uuidString: s) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an id") }
                return u
            }
            let goal = try id(try c.decode(String.self))
            var hops: [(connector: UUID, backwards: Bool)] = []
            var list = try c.nestedUnkeyedContainer()
            while !list.isAtEnd {
                var hop = try list.nestedUnkeyedContainer()
                hops.append((try id(try hop.decode(String.self)), try hop.decode(Bool.self)))
            }
            route = FlowRoute(goal: goal, hops: hops, amount: try c.decode(Double.self), waits: try c.decode(Bool.self),
                              cost: try c.decode(Double.self))
        }
    }

    /// What finishing does to one element (`finishPlan` in web/src/measure.ts): the overrides comparing metrics whose
    /// looks apply, and a gauge's drawing.
    struct Finish: Decodable {
        var id: UUID
        var applied: [Int]
        var gauge: Drawn?
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            guard let id = UUID(uuidString: try c.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an id")
            }
            self.id = id
            applied = try c.decode([Int].self)
            gauge = try c.decodeIfPresent(Drawn.self)
        }
    }

    /// A gauge as drawn: its frame's label, label box, text color and outline, then each part.
    struct Drawn: Decodable {
        var text: String
        var label: [Double]
        var textColor: RGBA?
        var fontSize: Double?
        var subpaths: [PathSubpath]
        var parts: [Part]
        struct Part: Decodable {
            var id: UUID, subpaths: [PathSubpath], stroke: RGBA, fill: RGBA?, width: Double
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                guard let id = UUID(uuidString: try c.decode(String.self)) else {
                    throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an id")
                }
                self.id = id
                subpaths = try c.decode([PathSubpath].self)
                stroke = try c.decode(RGBA.self)
                fill = try c.decodeIfPresent(RGBA.self)
                width = try c.decode(Double.self)
            }
        }
    }

    /// One frame as the simulation works it out: its packets and metrics, and how it finishes the page's elements.
    struct Frame {
        var packets: [Element]
        var metrics: FrameMetrics
        var finish: [UUID: Finish]

        /// `elements` with the looks of overrides that compare metrics applied, and gauges drawn as plain elements
        /// (ADR 0003), then the packets above them.
        func finished(_ elements: [Element]) -> [Element] {
            var out: [Element] = []
            for var e in elements {
                guard let f = finish[e.id] else { out.append(e); continue }
                for k in f.applied where e.overrides?.indices.contains(k) == true { e = e.overrides![k].looksOnly.apply(to: e) }
                guard let g = f.gauge else { out.append(e); continue }
                var back = e
                back.gauge = nil
                back.kind = .path
                back.subpaths = g.subpaths
                back.text = g.text
                if g.label.count == 4 { back.labelRect = NormalizedRect(x: g.label[0], y: g.label[1], width: g.label[2], height: g.label[3]) }
                if let c = g.textColor { back.style.textColor = c }
                if let s = g.fontSize, s.isFinite, s > 0 { back.style.fontSize = s }
                out.append(back)
                for p in g.parts {
                    var s = Style()
                    s.stroke = p.stroke; s.strokeWidth = p.width; s.roughness = 0; s.opacity = e.style.opacity
                    if let fill = p.fill { s.fill = fill; s.fillStyle = .solid } else { s.fill = RGBA(r: 0, g: 0, b: 0, a: 0) }
                    var part = Element(id: p.id, kind: .path, frame: e.frame, style: s, seed: 1, layerID: e.layerID)
                    part.subpaths = p.subpaths
                    out.append(part)
                }
            }
            return out + packets
        }
    }

    /// One field of a packet: `[id, x, y, size, layer]`.
    private enum Packet: Decodable {
        case text(String), number(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
        }
        var text: String? { if case .text(let s) = self { s } else { nil } }
        var number: Double? { if case .number(let n) = self { n } else { nil } }
    }

    /// One frame of `frame`, the page posed at `t` with its flows still on it; nil if the simulation can't run.
    func frame(_ frame: DottieDocument, at t: Double, values: [String: Var]?, offline: Set<UUID>,
               since: Double?, carried: [String: Double], routes: Bool = false) -> Frame? {
        var page = frame
        // Pictures don't affect traffic, and would cost an encoding.
        for i in page.elements.indices where page.elements[i].image != nil { page.elements[i].image = nil }
        let request = Request(t: t, values: values, offline: offline.map(\.uuidString).sorted(), since: since, carried: carried,
                              routes: routes)
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        lock.lock(); defer { lock.unlock() }
        failure = "bad response"
        defer { if let failure { assertionFailure("The simulation failed: \(failure)") } }
        guard let f = load() else { return nil }
        if page != lastPage {
            lastPage = nil
            guard let json = try? JSONEncoder().encode(page) else { return nil }
            pageFunction?.call(withArguments: [String(decoding: json, as: UTF8.self)])
            if let e = context?.exception { failure = "\(e)"; context?.exception = nil; return nil }
            lastPage = page
        }
        let result = f.call(withArguments: [text])
        if let e = context?.exception { failure = "\(e)"; context?.exception = nil; return nil }
        guard let out = result?.toString(),
              let response = try? JSONDecoder().decode(Response.self, from: Data(out.utf8)) else { return nil }

        var metrics = FrameMetrics()
        for (key, m) in response.elements {
            guard let id = UUID(uuidString: key) else { continue }
            metrics.elements[id] = ElementMetrics(throughput: m.throughput, load: m.load, delay: m.delay,
                                                  backlog: m.backlog, inFlight: m.inFlight, depth: m.depth)
        }
        for (key, m) in response.flows {
            guard let id = UUID(uuidString: key) else { continue }
            metrics.flows[id] = FlowMetrics(volume: m.volume, placed: m.placed, backlog: m.backlog, backup: m.backup, transit: m.transit)
        }
        metrics.carry = response.carry
        for (key, list) in response.routes ?? [:] {
            if let id = UUID(uuidString: key) { metrics.routes[id] = list.map(\.route) }
        }

        // A packet's id starts with its flow's first 24 digits (`Flow.packetID`), which gives its look.
        var styles: [Substring: Style] = [:]
        for flow in frame.flows ?? [] { styles[flow.id.uuidString.prefix(24)] = DottieDocument.packetStyle(flow) }
        var packets: [Element] = []
        for p in response.packets {
            guard p.count == 5, let key = p[0].text, let id = UUID(uuidString: key), let x = p[1].number, let y = p[2].number,
                  let size = p[3].number, let layer = p[4].text.flatMap(UUID.init(uuidString:)) else { continue }
            packets.append(Element(id: id, kind: .ellipse, frame: CGRect(x: x, y: y, width: size, height: size),
                                   style: styles[key.prefix(24)] ?? Style(), seed: 1, layerID: layer))
        }
        failure = nil
        return Frame(packets: packets, metrics: metrics,
                     finish: Dictionary(response.finish.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }
}

