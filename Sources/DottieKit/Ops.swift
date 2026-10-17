import Foundation
import CoreGraphics

extension RGBA {
    /// Parses "#RGB", "#RRGGBB" or "#RRGGBBAA" (leading # optional). Returns nil if malformed.
    public init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let hasAlpha = h.count == 8
        let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
        self.init(r: r, g: g, b: b, a: a)
    }
}

public enum OpsError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case invalid(String)
    public var description: String {
        switch self {
        case .notFound(let s), .invalid(let s): return s
        }
    }
}

public enum LayoutDirection: String, Codable, Sendable { case topToBottom = "TB", leftToRight = "LR" }

/// High-level, agent-friendly edits. Pure functions over `DottieDocument` so the CLI,
/// the MCP server and (later) the live app all share one implementation.
public enum DiagramOps {
    public struct NodeSpec: Sendable {
        public var key: String
        public var text: String
        public var kind: ElementKind
        public var fill: RGBA?
        public var width: Double?
        public var height: Double?
        public init(key: String, text: String, kind: ElementKind = .rectangle, fill: RGBA? = nil, width: Double? = nil, height: Double? = nil) {
            self.key = key; self.text = text; self.kind = kind; self.fill = fill; self.width = width; self.height = height
        }
    }

    public struct EdgeSpec: Sendable {
        public var from: String, to: String
        public var routing: Routing?
        public var arrow: Bool
        public var label: String?
        /// Dash, width and arrowheads beyond `arrow` (e.g. both ends for a two-way link).
        public var look: Look
        public init(from: String, to: String, routing: Routing? = nil, arrow: Bool = true, label: String? = nil, look: Look = Look()) {
            self.from = from; self.to = to; self.routing = routing; self.arrow = arrow; self.label = label; self.look = look
        }
    }

    // MARK: Sizing

    /// Rough text width; avoids a CoreText dependency in headless callers.
    public static func defaultSize(for kind: ElementKind, text: String, fontSize: Double = 18) -> CGSize {
        let longest = text.split(separator: "\n").map(\.count).max() ?? 0
        let lines = max(1, text.split(separator: "\n").count)
        let w = Double(longest) * fontSize * 0.56
        switch kind {
        case .diamond: return CGSize(width: max(140, w * 1.7 + 40), height: max(90, Double(lines) * fontSize * 2.6))
        case .ellipse: return CGSize(width: max(120, w * 1.35 + 40), height: max(70, Double(lines) * fontSize * 1.8 + 30))
        case .text: return CGSize(width: max(40, w + 12), height: Double(lines) * fontSize * 1.4 + 6)
        case .note: return CGSize(width: min(max(200, w * 0.9 + 2 * Note.padding), 360),
                                  height: max(160, Double(lines) * fontSize * 1.5 + 2 * Note.padding))
        default: return CGSize(width: max(120, w + 40), height: max(60, Double(lines) * fontSize * 1.4 + 30))
        }
    }

    private static func activeLayerID(_ doc: inout DottieDocument) -> UUID {
        if let l = doc.layers.first(where: { !$0.locked }) { return l.id }
        let l = Layer(name: "Layer \(doc.layers.count + 1)")
        doc.layers.append(l)
        return l.id
    }

    /// Look options an agent can set on any element. Everything is optional; nil leaves the field alone.
    public struct Look: Sendable {
        public var fillStyle: FillStyle?
        public var dash: DashStyle?
        public var strokeWidth: Double?
        public var bowing: Double?
        public var startHead: Arrowhead?
        public var endHead: Arrowhead?
        /// Degrees, clockwise.
        public var rotation: Double?
        /// Cell size of a grid fill, in points.
        public var gridSize: Double?
        public init(fillStyle: FillStyle? = nil, dash: DashStyle? = nil, strokeWidth: Double? = nil, bowing: Double? = nil,
                    startHead: Arrowhead? = nil, endHead: Arrowhead? = nil, rotation: Double? = nil, gridSize: Double? = nil) {
            self.fillStyle = fillStyle; self.dash = dash; self.strokeWidth = strokeWidth; self.bowing = bowing
            self.startHead = startHead; self.endHead = endHead; self.rotation = rotation; self.gridSize = gridSize
        }

        func apply(to e: inout Element) {
            if let fillStyle { e.style.fillStyle = fillStyle }
            if let dash { e.style.dash = dash }
            if let strokeWidth { e.style.strokeWidth = min(max(strokeWidth, 0.5), 24) }
            if let bowing { e.style.bowing = max(0, bowing) }
            if let gridSize { e.style.gridSize = min(max(gridSize, 8), 400) }
            if e.kind == .connector {
                if let startHead { e.connector?.startHead = startHead }
                if let endHead { e.connector?.endHead = endHead }
            } else if let rotation {
                let a = (rotation * .pi / 180).truncatingRemainder(dividingBy: 2 * .pi)
                e.rotation = abs(a) < 1e-9 ? nil : a
            }
        }
    }

    // MARK: Primitive edits

    @discardableResult
    public static func addShape(_ doc: inout DottieDocument, kind: ElementKind, frame: CGRect?, at origin: CGPoint,
                                text: String?, fill: RGBA?, stroke: RGBA?, roughness: Double?,
                                look: Look = Look()) throws -> Element {
        guard kind != .connector else { throw OpsError.invalid("Use add_connector for connectors") }
        guard kind != .image else { throw OpsError.invalid("Use add_image for pictures") }
        var style = Style()
        if let fill { style.fill = fill }
        if let stroke { style.stroke = stroke }
        if let roughness { style.roughness = roughness }
        if kind == .text { style.roughness = 0 }
        if kind == .note { style = Note.style(from: style) }
        let size = frame?.size ?? defaultSize(for: kind, text: text ?? "", fontSize: style.fontSize)
        let f = CGRect(origin: frame?.origin ?? origin, size: size)
        var e = Element(kind: kind, frame: f, style: style, layerID: activeLayerID(&doc), text: text)
        look.apply(to: &e)
        doc.elements.append(e)
        return e
    }

    @discardableResult
    public static func addConnector(_ doc: inout DottieDocument, from: UUID, to: UUID, routing: Routing = .straight,
                                    arrow: Bool = true, port: (Port?, Port?) = (nil, nil), roughness: Double? = nil,
                                    label: String? = nil, look: Look = Look()) throws -> Element {
        func shape(_ id: UUID) throws -> Element {
            guard let e = doc.elements.first(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
            guard e.kind != .connector else { throw OpsError.invalid("Connectors can only attach to shapes") }
            return e
        }
        _ = try shape(from); _ = try shape(to)
        var style = Style()
        if let roughness { style.roughness = roughness }
        let data = ConnectorData(start: .bound(from, port: port.0), end: .bound(to, port: port.1), routing: routing, endArrow: arrow)
        var e = Element(kind: .connector, frame: .zero, style: style, layerID: activeLayerID(&doc), text: label, connector: data)
        look.apply(to: &e)
        doc.elements.append(e)
        return e
    }

    /// Places a stencil item with its top-left corner at (`x`, `y`) on the first open layer.
    /// Returns the new element ids and the size it was placed at.
    @discardableResult
    public static func addStencil(_ doc: inout DottieDocument, item: StencilItem, x: Double, y: Double, scale: Double = 1,
                                  keepOriginalColors: Bool = false, roughness: Double? = nil) -> (ids: Set<UUID>, size: CGSize) {
        let k = item.readableScale * max(0.05, scale)
        let size = CGSize(width: item.width * k, height: item.height * k)
        let layer = doc.layers.first { !$0.locked && $0.visible }?.id ?? doc.layers[0].id
        let art = item.placed(keepOriginalColors: keepOriginalColors, roughness: roughness ?? Style().roughness, scale: k)
        let ids = doc.insert(art, size: size, center: CGPoint(x: x + size.width / 2, y: y + size.height / 2), layerID: layer,
                             symbols: item.symbols ?? [])
        return (ids, size)
    }

    public static func update(_ doc: inout DottieDocument, id: UUID, text: String?? = nil, x: Double? = nil, y: Double? = nil,
                              width: Double? = nil, height: Double? = nil, fill: RGBA? = nil, stroke: RGBA? = nil,
                              roughness: Double? = nil, routing: Routing? = nil, look: Look = Look(),
                              link: UUID?? = nil, anchor: String?? = nil, click: ClickAction?? = nil, hover: HoverLook?? = nil,
                              otherPages: [DottieDocument] = []) throws {
        guard let i = doc.elements.firstIndex(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
        if let anchor { doc.elements[i].anchor = anchor.flatMap { $0.isEmpty ? nil : $0 } }
        if let click { doc.elements[i].click = click.flatMap { $0.isEmpty ? nil : $0 } }
        if let hover { doc.elements[i].hover = hover.flatMap { $0.isEmpty ? nil : $0 } }
        if let link { try doc.setLink([id], to: link, otherPages: otherPages) }
        if let text { doc.elements[i].text = text }
        if doc.elements[i].kind != .connector {
            if let x { doc.elements[i].x = x }
            if let y { doc.elements[i].y = y }
            if let width { doc.elements[i].width = max(1, width) }
            if let height { doc.elements[i].height = max(1, height) }
        }
        if let fill { doc.elements[i].style.fill = fill }
        if let stroke { doc.elements[i].style.stroke = stroke }
        if let roughness { doc.elements[i].style.roughness = roughness }
        if let routing { doc.elements[i].connector?.routing = routing }
        look.apply(to: &doc.elements[i])
    }

    public static func delete(_ doc: inout DottieDocument, id: UUID) throws {
        guard doc.elements.contains(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
        doc.remove([id])
    }

    // MARK: Bulk build

    /// Adds nodes and edges as one laid-out block placed below existing content. Returns key -> element id.
    @discardableResult
    public static func build(_ doc: inout DottieDocument, nodes: [NodeSpec], edges: [EdgeSpec],
                             direction: LayoutDirection = .topToBottom, roughness: Double = 1,
                             defaultRouting: Routing = .elbow) throws -> [String: UUID] {
        var seen = Set<String>()
        for n in nodes {
            guard n.kind != .image, n.kind != .connector else { throw OpsError.invalid("Node '\(n.key)' cannot be a \(n.kind.rawValue)") }
            guard !n.key.isEmpty else { throw OpsError.invalid("Node key must not be empty") }
            guard seen.insert(n.key).inserted else { throw OpsError.invalid("Duplicate node key '\(n.key)'") }
        }
        for e in edges where !seen.contains(e.from) || !seen.contains(e.to) {
            throw OpsError.invalid("Edge \(e.from) -> \(e.to) references an unknown node key")
        }

        let top = doc.elements.isEmpty ? 40 : Exporter.bounds(of: doc, padding: 0).maxY + 80
        let layerID = activeLayerID(&doc)
        var ids: [String: UUID] = [:]
        var added: [Element] = []
        for n in nodes {
            var style = Style()
            style.roughness = roughness
            if let f = n.fill { style.fill = f }
            if n.kind == .note { style = Note.style(from: style) }
            let auto = defaultSize(for: n.kind, text: n.text, fontSize: style.fontSize)
            let size = CGSize(width: n.width ?? auto.width, height: n.height ?? auto.height)
            let e = Element(kind: n.kind, frame: CGRect(origin: .zero, size: size), style: style, layerID: layerID,
                            text: n.text.isEmpty ? nil : n.text)
            ids[n.key] = e.id
            added.append(e)
        }
        var tmp = DottieDocument(layers: doc.layers, elements: added)
        let pairs = edges.map { (ids[$0.from]!, ids[$0.to]!) }
        Layout.layered(&tmp, edges: pairs, direction: direction)
        var origin = Exporter.bounds(of: tmp, padding: 0).origin
        if tmp.elements.isEmpty { origin = .zero }
        for var e in tmp.elements {
            e.x += 40 - origin.x; e.y += top - origin.y
            doc.elements.append(e)
        }
        let placed = doc.elementIndex
        for edge in edges {
            // Ports follow the flow direction so laid-out diagrams read as clean flowcharts. An edge that goes
            // back up the flow (a loop) leaves and enters from the side instead of cutting through the shapes between.
            var ports: (Port?, Port?) = direction == .topToBottom ? (.bottom, .top) : (.right, .left)
            if let a = placed[ids[edge.from]!]?.frame, let b = placed[ids[edge.to]!]?.frame,
               direction == .topToBottom ? b.minY < a.maxY : b.minX < a.maxX {
                ports = direction == .topToBottom ? (.right, .right) : (.bottom, .bottom)
            }
            try addConnector(&doc, from: ids[edge.from]!, to: ids[edge.to]!, routing: edge.routing ?? defaultRouting,
                             arrow: edge.arrow, port: ports, roughness: roughness, label: edge.label, look: edge.look)
        }
        return ids
    }

    /// Re-lays out every shape using the existing connectors as edges.
    public static func autoLayout(_ doc: inout DottieDocument, direction: LayoutDirection = .topToBottom) {
        let edges: [(UUID, UUID)] = doc.elements.compactMap { e in
            guard let c = e.connector, let a = c.start.elementID, let b = c.end.elementID else { return nil }
            return (a, b)
        }
        Layout.layered(&doc, edges: edges, direction: direction)
    }

    // MARK: Inspection

    /// Where each element landed in an exported PNG, so an agent can point at things it sees in the image.
    public struct Annotation: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var text: String?
        /// Pixels from the image's top-left corner.
        public var x, y, width, height: Double
    }

    public static func annotations(_ doc: DottieDocument, scale: Double) -> [Annotation] {
        let origin = Exporter.bounds(of: doc).origin
        let index = doc.elementIndex
        let visible = Set(doc.layers.filter(\.visible).map(\.id))
        func px(_ v: Double) -> Double { (v * scale * 10).rounded() / 10 }
        return doc.orderedElements.filter { visible.contains($0.layerID) }.map { e in
            let b = e.kind == .connector ? Connector.bounds(of: e, in: doc, index: index) : e.rotatedBounds
            return Annotation(id: e.id.uuidString, kind: e.kind.rawValue, text: e.text,
                              x: px(b.minX - origin.x), y: px(b.minY - origin.y), width: px(b.width), height: px(b.height))
        }
    }

    public struct ElementSummary: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var x, y, width, height: Double
        public var text: String?
        public var from: String?
        public var to: String?
        public var routing: String?
        public var sketchy: Bool
        public var rotation: Double?
        public var fillStyle: String?
        public var dash: String?
        public var link: String?
        public var anchor: String?
        /// The scene a click plays, or the link it opens, in the web players.
        public var clickScene: String?
        public var clickURL: String?
        /// For a symbol instance: its symbol's name, and how it plays.
        public var symbol: String?
        public var playback: String?
    }

    public static func summarize(_ doc: DottieDocument) -> [ElementSummary] {
        let index = doc.elementIndex
        return doc.elements.map { e in
            let b = e.kind == .connector ? Connector.bounds(of: e, in: doc, index: index) : e.frame
            return ElementSummary(id: e.id.uuidString, kind: e.kind.rawValue,
                                  x: (b.minX * 10).rounded() / 10, y: (b.minY * 10).rounded() / 10,
                                  width: (b.width * 10).rounded() / 10, height: (b.height * 10).rounded() / 10,
                                  text: e.text, from: e.connector?.start.elementID?.uuidString,
                                  to: e.connector?.end.elementID?.uuidString,
                                  routing: e.connector?.routing.rawValue, sketchy: e.style.roughness > 0,
                                  rotation: e.rotation.map { ($0 * 180 / .pi * 10).rounded() / 10 },
                                  fillStyle: e.style.fillStyle == .solid ? nil : e.style.fillStyle.rawValue,
                                  dash: e.style.dash == .solid ? nil : e.style.dash.rawValue,
                                  link: e.link?.uuidString, anchor: e.anchor,
                                  clickScene: e.click?.scene, clickURL: e.click?.url,
                                  symbol: e.symbol.map { id in doc.symbolIndex[id]?.name ?? id.uuidString },
                                  playback: e.kind == .symbol ? (e.playback ?? .loop).rawValue : nil)
        }
    }
}

/// Simple layered (Sugiyama-lite) layout: longest-path ranks, barycenter ordering, centered ranks.
public enum Layout {
    public static func layered(_ doc: inout DottieDocument, edges: [(UUID, UUID)], direction: LayoutDirection,
                               rankGap: Double = 90, nodeGap: Double = 50) {
        let nodeIdx = doc.elements.indices.filter { doc.elements[$0].kind != .connector }
        guard !nodeIdx.isEmpty else { return }
        let ids = nodeIdx.map { doc.elements[$0].id }
        let pos = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })

        // Keep edges between known nodes; drop self-loops and duplicates.
        var seenEdge = Set<[Int]>()
        var out = [[Int]](repeating: [], count: ids.count)
        for (a, b) in edges {
            guard let i = pos[a], let j = pos[b], i != j, seenEdge.insert([i, j]).inserted else { continue }
            out[i].append(j)
        }

        // Break cycles with DFS: ignore back edges.
        var state = [Int](repeating: 0, count: ids.count) // 0 new, 1 on stack, 2 done
        var dag = [[Int]](repeating: [], count: ids.count)
        func visit(_ u: Int) {
            state[u] = 1
            for v in out[u] {
                if state[v] == 1 { continue }
                dag[u].append(v)
                if state[v] == 0 { visit(v) }
            }
            state[u] = 2
        }
        for u in ids.indices where state[u] == 0 { visit(u) }

        // Longest-path ranking in topological order.
        var indeg = [Int](repeating: 0, count: ids.count)
        for u in dag.indices { for v in dag[u] { indeg[v] += 1 } }
        var rank = [Int](repeating: 0, count: ids.count)
        var queue = ids.indices.filter { indeg[$0] == 0 }
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            for v in dag[u] {
                rank[v] = max(rank[v], rank[u] + 1)
                indeg[v] -= 1
                if indeg[v] == 0 { queue.append(v) }
            }
        }

        let maxRank = rank.max() ?? 0
        var layers = [[Int]](repeating: [], count: maxRank + 1)
        for u in ids.indices { layers[rank[u]].append(u) }

        // Barycenter sweeps to cut crossings.
        var preds = [[Int]](repeating: [], count: ids.count)
        for u in dag.indices { for v in dag[u] { preds[v].append(u) } }
        var order = [Int](repeating: 0, count: ids.count)
        func reindex() { for l in layers { for (k, u) in l.enumerated() { order[u] = k } } }
        reindex()
        for _ in 0..<4 {
            for r in 1..<max(layers.count, 1) where r < layers.count {
                layers[r].sort { a, b in
                    func bc(_ n: Int) -> Double {
                        preds[n].isEmpty ? Double(order[n]) : preds[n].map { Double(order[$0]) }.reduce(0, +) / Double(preds[n].count)
                    }
                    let (x, y) = (bc(a), bc(b))
                    return x == y ? a < b : x < y
                }
                reindex()
            }
        }

        // Coordinates: along-rank axis is "breadth", across ranks is "depth".
        func size(_ u: Int) -> (breadth: Double, depth: Double) {
            let f = doc.elements[nodeIdx[u]].frame
            return direction == .topToBottom ? (f.width, f.height) : (f.height, f.width)
        }
        let breadths = layers.map { l in l.map { size($0).breadth }.reduce(0, +) + Double(max(l.count - 1, 0)) * nodeGap }
        let widest = breadths.max() ?? 0
        var depthCursor = 0.0
        for (r, l) in layers.enumerated() {
            let layerDepth = l.map { size($0).depth }.max() ?? 0
            var cursor = (widest - breadths[r]) / 2
            for u in l {
                let s = size(u)
                let depth = depthCursor + (layerDepth - s.depth) / 2
                var f = doc.elements[nodeIdx[u]].frame
                if direction == .topToBottom { f.origin = CGPoint(x: cursor, y: depth) }
                else { f.origin = CGPoint(x: depth, y: cursor) }
                doc.elements[nodeIdx[u]].frame = f
                cursor += s.breadth + nodeGap
            }
            depthCursor += layerDepth + rankGap
        }
    }
}
