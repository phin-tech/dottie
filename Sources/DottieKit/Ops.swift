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
        /// The line's color; nil is the automatic ink.
        public var stroke: RGBA?
        /// A condition on page variables (`Element.when`); nil is always drawn.
        public var when: String?
        public init(from: String, to: String, routing: Routing? = nil, arrow: Bool = true, label: String? = nil, look: Look = Look(),
                    stroke: RGBA? = nil, when: String? = nil) {
            self.from = from; self.to = to; self.routing = routing; self.arrow = arrow; self.label = label; self.look = look
            self.stroke = stroke; self.when = when
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

    static func activeLayerID(_ doc: inout DottieDocument) -> UUID {
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
        /// The font text is set in (see `Fonts`); "" or "Helvetica Neue" goes back to the default.
        public var font: String?
        public var fontSize: Double?
        /// A connector's bends, start to end; empty takes them out.
        public var waypoints: [CGPoint]?
        /// Whether a connector hops over the connectors beneath it.
        public var hops: Bool?
        /// Whether an elbow connector goes round the shapes in its way.
        public var avoid: Bool?
        /// What a flow's traffic pays to take a connector; 1 (the default) clears it.
        public var cost: Double?
        /// A shape's or connector's label color; `.some(nil)` goes back to following the stroke.
        public var textColor: RGBA??
        public init(fillStyle: FillStyle? = nil, dash: DashStyle? = nil, strokeWidth: Double? = nil, bowing: Double? = nil,
                    startHead: Arrowhead? = nil, endHead: Arrowhead? = nil, rotation: Double? = nil, gridSize: Double? = nil,
                    font: String? = nil, fontSize: Double? = nil, waypoints: [CGPoint]? = nil, hops: Bool? = nil,
                    textColor: RGBA?? = nil, cost: Double? = nil, avoid: Bool? = nil) {
            self.fillStyle = fillStyle; self.dash = dash; self.strokeWidth = strokeWidth; self.bowing = bowing
            self.startHead = startHead; self.endHead = endHead; self.rotation = rotation; self.gridSize = gridSize
            self.font = font; self.fontSize = fontSize; self.waypoints = waypoints; self.hops = hops
            self.textColor = textColor; self.cost = cost; self.avoid = avoid
        }

        /// Sets the font and text size, the part of the look a shape's default size depends on.
        func applyText(to style: inout Style) {
            if let font {
                let name = font.trimmingCharacters(in: .whitespaces)
                style.font = name.isEmpty || name.caseInsensitiveCompare(Fonts.defaultFamily) == .orderedSame
                    ? nil : Fonts.bundledFamily(name) ?? name
            }
            if let fontSize { style.fontSize = min(max(fontSize, 4), 200) }
        }

        func apply(to e: inout Element) {
            applyText(to: &e.style)
            if let fillStyle { e.style.fillStyle = fillStyle }
            if let dash { e.style.dash = dash }
            if let strokeWidth { e.style.strokeWidth = min(max(strokeWidth, 0.5), 24) }
            if let bowing { e.style.bowing = max(0, bowing) }
            if let gridSize { e.style.gridSize = min(max(gridSize, 8), 400) }
            if let textColor, e.kind != .text, e.kind != .note { e.style.textColor = textColor }
            if e.kind == .connector {
                if let startHead { e.connector?.startHead = startHead }
                if let endHead { e.connector?.endHead = endHead }
                if let waypoints { e.connector?.waypoints = waypoints.isEmpty ? nil : waypoints.map(Waypoint.init) }
                if let hops { e.connector?.hops = hops ? true : nil }
                if let avoid { e.connector?.avoid = avoid ? true : nil }
                if let cost, cost.isFinite {
                    let c = min(max(cost, 0), 1_000_000)
                    e.connector?.cost = c == 1 ? nil : c
                }
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
        look.applyText(to: &style)
        let size = frame?.size ?? defaultSize(for: kind, text: text ?? "", fontSize: style.fontSize)
        let f = CGRect(origin: frame?.origin ?? origin, size: size)
        var e = Element(kind: kind, frame: f, style: style, layerID: activeLayerID(&doc), text: text)
        look.apply(to: &e)
        doc.elements.append(e)
        return e
    }

    /// Adds an extension shape generated from `params`, at `frame`, or at `origin` in the default size. The element
    /// keeps the extension's reference, so it can be regenerated when it is edited.
    @discardableResult
    public static func addExtensionShape(_ doc: inout DottieDocument, runtime: ExtensionRuntime, shape: String,
                                         params: [String: ExtensionValue], frame: CGRect?, at origin: CGPoint,
                                         text: String? = nil, fill: RGBA? = nil, stroke: RGBA? = nil,
                                         look: Look = Look()) throws -> Element {
        var style = Style()
        if let fill { style.fill = fill }
        if let stroke { style.stroke = stroke }
        let size = frame?.size ?? CGSize(width: 100, height: 100)
        var e = Element(kind: .path, frame: CGRect(origin: frame?.origin ?? origin, size: size), style: style,
                        layerID: activeLayerID(&doc), text: text)
        let normal = try runtime.normalized(params, shape: shape)
        e.extension = ExtensionRef(id: runtime.manifest.id, shape: shape, version: runtime.manifest.version, params: normal)
        e.apply(try runtime.generate(shape: shape, params: normal, width: size.width, height: size.height))
        look.apply(to: &e)
        doc.elements.append(e)
        return e
    }

    @discardableResult
    public static func addConnector(_ doc: inout DottieDocument, from: UUID, to: UUID, routing: Routing = .straight,
                                    arrow: Bool = true, port: (Port?, Port?) = (nil, nil), portIndex: (Int?, Int?) = (nil, nil),
                                    roughness: Double? = nil, label: String? = nil, look: Look = Look(),
                                    stroke: RGBA? = nil) throws -> Element {
        func shape(_ id: UUID) throws -> Element {
            guard let e = doc.elements.first(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
            guard e.kind != .connector else { throw OpsError.invalid("Connectors can only attach to shapes") }
            return e
        }
        /// An end bound to `id`, pinned to its connection point `index` (an extension shape's `ports`) when given.
        func end(_ id: UUID, _ named: Port?, _ index: Int?) throws -> Endpoint {
            var ep = Endpoint.bound(id, port: named)
            guard let index else { return ep }
            let count = try shape(id).ports?.count ?? 0
            guard (0..<count).contains(index) else {
                throw OpsError.invalid(count == 0 ? "That shape has no numbered connection points; use top, right, bottom or left"
                    : "Connection point \(index) is out of range: that shape has \(count) (0 to \(count - 1))")
            }
            ep.portIndex = index
            return ep
        }
        _ = try shape(from); _ = try shape(to)
        var style = Style()
        if let roughness { style.roughness = roughness }
        if let stroke { style.stroke = stroke }
        let data = ConnectorData(start: try end(from, port.0, portIndex.0), end: try end(to, port.1, portIndex.1),
                                 routing: routing, endArrow: arrow)
        var e = Element(kind: .connector, frame: .zero, style: style, layerID: activeLayerID(&doc), text: label, connector: data)
        // A new elbow goes round the shapes in its way unless told not to.
        if routing == .elbow { e.connector?.avoid = true }
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
                              link: UUID?? = nil, url: String?? = nil, anchor: String?? = nil, click: ClickAction?? = nil,
                              hover: HoverLook?? = nil, otherPages: [DottieDocument] = []) throws {
        guard let i = doc.elements.firstIndex(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
        if let anchor { doc.elements[i].anchor = anchor.flatMap { $0.isEmpty ? nil : $0 } }
        if doc.elements[i].kind == .symbol, (hover ?? nil) != nil {
            throw OpsError.invalid("A symbol's copy takes no hover colors; make the symbol a button and draw its over state")
        }
        if let click { doc.elements[i].click = click.flatMap { $0.isEmpty ? nil : $0 } }
        if let hover { doc.elements[i].hover = hover.flatMap { $0.isEmpty ? nil : $0 } }
        if let link { try doc.setLink([id], to: link, otherPages: otherPages) }
        if let url { try doc.setURL([id], to: url) }
        if let text { doc.elements[i].text = text }
        if doc.elements[i].kind != .connector {
            if let x { doc.elements[i].x = x }
            if let y { doc.elements[i].y = y }
            if let width { doc.elements[i].width = max(1, width) }
            if let height { doc.elements[i].height = max(1, height) }
        }
        if let fill { doc.elements[i].style.fill = fill }
        if let stroke { // recolors the label too, as in Excalidraw, unless `look` gives it its own color
            doc.elements[i].style.stroke = stroke
            doc.elements[i].style.textColor = nil
        }
        if let roughness { doc.elements[i].style.roughness = roughness }
        if let routing { doc.elements[i].connector?.setRouting(routing) }
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
                             defaultRouting: Routing = .elbow, font: String? = nil) throws -> [String: UUID] {
        let text = Look(font: font)
        var seen = Set<String>()
        for n in nodes {
            guard n.kind != .image, n.kind != .connector else { throw OpsError.invalid("Node '\(n.key)' cannot be a \(n.kind.rawValue)") }
            guard !n.key.isEmpty else { throw OpsError.invalid("Node key must not be empty") }
            guard seen.insert(n.key).inserted else { throw OpsError.invalid("Duplicate node key '\(n.key)'") }
        }
        for e in edges where !seen.contains(e.from) || !seen.contains(e.to) {
            throw OpsError.invalid("Edge \(e.from) -> \(e.to) references an unknown node key")
        }
        let whens = try edges.map { try $0.when.flatMap { try PageState.checked($0) } }

        let top = doc.elements.isEmpty ? 40 : Exporter.bounds(of: doc, padding: 0).maxY + 80
        let layerID = activeLayerID(&doc)
        var ids: [String: UUID] = [:]
        var added: [Element] = []
        for n in nodes {
            var style = Style()
            style.roughness = roughness
            if let f = n.fill { style.fill = f }
            if n.kind == .note { style = Note.style(from: style) }
            text.applyText(to: &style)
            let auto = defaultSize(for: n.kind, text: n.text, fontSize: style.fontSize)
            let size = CGSize(width: n.width ?? auto.width, height: n.height ?? auto.height)
            let e = Element(kind: n.kind, frame: CGRect(origin: .zero, size: size), style: style, layerID: layerID,
                            text: n.text.isEmpty ? nil : n.text)
            ids[n.key] = e.id
            added.append(e)
        }
        var tmp = DottieDocument(layers: doc.layers, elements: added)
        let looks = edges.map { edge -> Look in var l = edge.look; l.font = l.font ?? font; return l }
        let laid = edges.enumerated().map { k, edge in
            Layout.Edge(from: ids[edge.from]!, to: ids[edge.to]!, label: labelSize(edge.label, look: looks[k], layerID: layerID))
        }
        let lanes = Layout.layered(&tmp, edges: laid, direction: direction)
        var origin = Exporter.bounds(of: tmp, padding: 0).origin
        if tmp.elements.isEmpty { origin = .zero }
        let shift = CGPoint(x: 40 - origin.x, y: top - origin.y)
        for var e in tmp.elements {
            e.x += shift.x; e.y += shift.y
            doc.elements.append(e)
        }
        let pairs = Set(laid.map { [$0.from, $0.to] })
        for (k, edge) in edges.enumerated() {
            // Ports follow the flow direction so laid-out diagrams read as clean flowcharts, and an edge that skips
            // ranks runs through its lane between them (see Layout.layered).
            let routing = edge.routing ?? defaultRouting
            var ports: (Port?, Port?) = direction == .topToBottom ? (.bottom, .top) : (.right, .left)
            var bends: [CGPoint] = []
            if let lane = lanes[k] {
                let r = Layout.route(lane, routing: routing, direction: direction, twin: pairs.contains([laid[k].to, laid[k].from]))
                ports = (r.0, r.1)
                bends = r.2.map { CGPoint(x: $0.x + shift.x, y: $0.y + shift.y) }
            }
            let c = try addConnector(&doc, from: ids[edge.from]!, to: ids[edge.to]!, routing: routing,
                                     arrow: edge.arrow, port: ports, roughness: roughness, label: edge.label, look: looks[k])
            if let i = doc.elements.lastIndex(where: { $0.id == c.id }) {
                // The layout has routed it, lanes and labels and all: it goes round shapes only when asked to.
                if looks[k].avoid != true { doc.elements[i].connector?.avoid = nil }
                if !bends.isEmpty { doc.elements[i].connector?.waypoints = bends.map { Waypoint($0) } }
                if let stroke = edge.stroke { doc.elements[i].style.stroke = stroke }
                doc.elements[i].when = whens[k]
            }
        }
        return ids
    }

    /// The size a connector label `text` takes with `look` (nil for no label), for making room for it.
    private static func labelSize(_ text: String?, look: Look, layerID: UUID) -> CGSize? {
        guard let text, !text.isEmpty else { return nil }
        var probe = Element(kind: .connector, frame: .zero, layerID: layerID, text: text)
        look.apply(to: &probe)
        return Renderer.labelSize(for: probe)
    }

    /// Re-lays out every shape using the existing connectors as edges. Their bends and ports were placed for the old
    /// layout, so they go: a connector between two shapes is pinned along the new flow and runs through its lane, as
    /// `build` lays one out. An end on an extension shape's numbered connection point keeps it.
    public static func autoLayout(_ doc: inout DottieDocument, direction: LayoutDirection = .topToBottom) {
        let connectors = doc.elements.indices.filter {
            doc.elements[$0].connector?.start.elementID != nil && doc.elements[$0].connector?.end.elementID != nil
        }
        let laid = connectors.map { i -> Layout.Edge in
            let e = doc.elements[i]
            return Layout.Edge(from: e.connector!.start.elementID!, to: e.connector!.end.elementID!,
                               label: (e.text ?? "").isEmpty ? nil : Renderer.labelSize(for: e))
        }
        let lanes = Layout.layered(&doc, edges: laid, direction: direction)
        for i in doc.elements.indices where doc.elements[i].connector?.waypoints != nil { doc.elements[i].connector?.waypoints = nil }
        let pairs = Set(laid.map { [$0.from, $0.to] })
        for (k, i) in connectors.enumerated() {
            guard let lane = lanes[k], var c = doc.elements[i].connector else { continue }
            let r = Layout.route(lane, routing: c.routing, direction: direction, twin: pairs.contains([laid[k].to, laid[k].from]))
            if c.start.portIndex == nil { c.start.port = r.0 }
            if c.end.portIndex == nil { c.end.port = r.1 }
            c.waypoints = r.2.isEmpty ? nil : r.2.map { Waypoint($0) }
            doc.elements[i].connector = c
        }
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

    /// The pixel scale to render `doc` at: `scale` (0.25-4), lowered so the image is at most `maxWidth` pixels wide.
    public static func exportScale(_ doc: DottieDocument, scale: Double?, maxWidth: Double?) -> Double {
        var s = min(max(scale ?? 2, 0.25), 4)
        if let maxWidth, maxWidth >= 1 {
            let width = Exporter.bounds(of: doc).width
            if width * s > maxWidth { s = max(0.01, maxWidth / width) }
        }
        return s
    }

    /// `annotations` as one short line each, `id kind x,y wxh "text"`, with whole pixels and the first line of the
    /// text cut to 40 characters: a fraction of the JSON map's size, for a page with many elements.
    public static func compactAnnotations(_ list: [Annotation]) -> String {
        list.map { a in
            var line = "\(a.id) \(a.kind) \(Int(a.x.rounded())),\(Int(a.y.rounded())) \(Int(a.width.rounded()))x\(Int(a.height.rounded()))"
            if let t = a.text?.components(separatedBy: "\n").first, !t.isEmpty {
                line += " \"" + (t.count > 40 ? t.prefix(39) + "…" : t) + "\""
            }
            return line
        }.joined(separator: "\n")
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
        /// A web address or another drawing it links to, instead of `link`.
        public var url: String?
        public var anchor: String?
        /// The scene a click plays, or the link it opens, in the web players.
        public var clickScene: String?
        public var clickURL: String?
        /// For a symbol instance: its symbol's name, and how it plays.
        public var symbol: String?
        public var playback: String?
        /// For a symbol instance: its values for the symbol's params.
        public var args: [String: String]?
        /// For a connector: the bends it runs through, and whether it hops the lines beneath it.
        public var waypoints: [Waypoint]?
        public var hops: Bool?
        /// For an elbow connector: whether it goes round the shapes in its way.
        public var avoid: Bool?
        /// For a connector: what a flow's traffic pays to take it, when not 1.
        public var cost: Double? = nil
        /// The page variables a click sets and flips, and the condition the element is drawn under.
        public var clickSet: [String: Bool]? = nil
        public var clickToggle: [String]? = nil
        public var when: String? = nil
        /// Its overrides, one line each: "down: opacity 0.3, text …, reroutes 1".
        public var overrides: [String]? = nil
    }

    public static func summarize(_ doc: DottieDocument) -> [ElementSummary] {
        let index = doc.elementIndex
        return doc.elements.map { e in
            let b = e.kind == .connector ? Connector.bounds(of: e, in: doc, index: index) : e.frame
            var s = ElementSummary(id: e.id.uuidString, kind: e.kind.rawValue,
                                  x: (b.minX * 10).rounded() / 10, y: (b.minY * 10).rounded() / 10,
                                  width: (b.width * 10).rounded() / 10, height: (b.height * 10).rounded() / 10,
                                  text: e.text, from: e.connector?.start.elementID?.uuidString,
                                  to: e.connector?.end.elementID?.uuidString,
                                  routing: e.connector?.routing.rawValue, sketchy: e.style.roughness > 0,
                                  rotation: e.rotation.map { ($0 * 180 / .pi * 10).rounded() / 10 },
                                  fillStyle: e.style.fillStyle == .solid ? nil : e.style.fillStyle.rawValue,
                                  dash: e.style.dash == .solid ? nil : e.style.dash.rawValue,
                                  link: e.link?.uuidString, url: e.url, anchor: e.anchor,
                                  clickScene: e.click?.scene, clickURL: e.click?.url,
                                  symbol: e.symbol.map { id in doc.symbolIndex[id]?.name ?? id.uuidString },
                                  playback: e.kind == .symbol ? (e.playback ?? .loop).rawValue : nil, args: e.args,
                                  waypoints: e.connector?.waypoints, hops: e.connector?.hops)
            s.avoid = e.connector?.avoid
            s.clickSet = e.click?.set; s.clickToggle = e.click?.toggle; s.when = e.when
            s.cost = e.connector?.cost
            s.overrides = e.overrides.map { $0.map(\.summary) }
            return s
        }
    }
}

