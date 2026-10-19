import Foundation
import CoreGraphics
import Compression

/// Reads diagrams.io / draw.io files (`.drawio`, `.xml`), compressed or not. Vertices become shapes
/// (flowchart, cylinder, cloud and similar draw.io shapes map onto Dottie's built-in shapes), edges become
/// connectors that stay attached, and labels, colors, dashes, rotation and arrowheads come across.
/// Pages become separate items. Waypoints, gradients, images, shadows and custom shape libraries are dropped.
public enum DrawioImporter {
    public struct Item: Sendable {
        public var name: String
        /// Positioned with the top-left corner at the origin.
        public var elements: [Element]
        public var size: CGSize
    }

    public enum ImportError: Error, Equatable { case notDrawio, empty }

    public static func importItems(from data: Data, layerID: UUID) throws -> [Item] {
        guard data.count <= 20_000_000, let root = try? SVGTree.parse(data) else { throw ImportError.notDrawio }
        var pages: [(name: String, model: SVGTree)] = []
        switch root.name {
        case "mxfile":
            for (i, d) in root.children.filter({ $0.name == "diagram" }).enumerated() {
                let name = d.attrs["name"] ?? "Page \(i + 1)"
                if let model = d.children.first(where: { $0.name == "mxGraphModel" }) {
                    pages.append((name, model))
                } else if let inner = decodeCompressed(d.text), let tree = try? SVGTree.parse(inner), tree.name == "mxGraphModel" {
                    pages.append((name, tree))
                }
            }
        case "mxGraphModel":
            pages.append(("Diagram", root))
        default:
            throw ImportError.notDrawio
        }
        let items = pages.compactMap { page -> Item? in
            var els = convert(page.model, layerID: layerID)
            guard !els.isEmpty else { return nil }
            let box = StencilLibrary.normalizeToOrigin(&els)
            return Item(name: page.name, elements: els, size: box.size)
        }
        guard !items.isEmpty else { throw ImportError.empty }
        return items
    }

    /// draw.io's compressed form: base64 of raw-deflated, percent-encoded XML.
    static func decodeCompressed(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let raw = Data(base64Encoded: trimmed) else { return nil }
        guard let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data,
              let s = String(data: inflated, encoding: .utf8)?.removingPercentEncoding else { return nil }
        return Data(s.utf8)
    }

    // MARK: Conversion

    private static func parseStyle(_ s: String?) -> (base: [String], kv: [String: String]) {
        var base: [String] = [], kv: [String: String] = [:]
        for part in (s ?? "").split(separator: ";") {
            if let eq = part.firstIndex(of: "=") {
                kv[String(part[..<eq])] = String(part[part.index(after: eq)...])
            } else {
                base.append(String(part))
            }
        }
        return (base, kv)
    }

    private static func plain(_ html: String) -> String {
        var s = html
        for br in ["<br>", "<br/>", "<br />", "</div>", "</p>", "</li>"] { s = s.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive) }
        if s.contains("<") {
            s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        for (a, b) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func color(_ s: String?) -> RGBA?? {
        guard let s, !s.isEmpty else { return .none }       // unset
        if s == "none" { return .some(nil) }                 // explicitly no paint
        if s == "default" || s == "inherit" { return .none }
        return Colors.parse(s, current: .black).map { .some($0) } ?? .none
    }

    private static func head(_ v: String?, default d: Arrowhead) -> Arrowhead {
        switch v {
        case nil: return d
        case "none": return .none
        case "open", "openThin": return .arrow
        case "oval", "circle": return .dot
        case "dash", "dashThin", "ERone", "ERmandOne": return .bar
        default: return .triangle // classic, block, diamond, ...
        }
    }

    /// Dottie built-in shape for a draw.io shape name, if there is a close one.
    private static func builtIn(for shape: String) -> String? {
        switch shape {
        case "cylinder", "cylinder3", "mxgraph.flowchart.database", "datastore": return "Database"
        case "parallelogram", "mxgraph.flowchart.data", "mxgraph.flowchart.manual_input": return "Input / Output"
        case "hexagon", "mxgraph.flowchart.preparation": return "Preparation"
        case "cloud": return "Cloud"
        case "document", "mxgraph.flowchart.document": return "Document"
        case "triangle": return "Triangle"
        case "note": return "Note"
        case "umlActor", "actor": return "Actor"
        case "mxgraph.flowchart.terminator", "mxgraph.flowchart.start_1", "mxgraph.flowchart.start_2": return "Terminator"
        case "mxgraph.flowchart.decision": return "Decision"
        case "mxgraph.flowchart.process", "mxgraph.flowchart.predefined_process": return "Process"
        case "step", "singleArrow": return "Block Arrow"
        case "callout": return "Speech Bubble"
        default: return nil
        }
    }

    private static func convert(_ model: SVGTree, layerID: UUID) -> [Element] {
        guard let rootNode = model.children.first(where: { $0.name == "root" }) else { return [] }
        let cells = rootNode.children.filter { $0.name == "mxCell" || $0.name == "object" || $0.name == "UserObject" }

        // `object` wrappers carry the id and label; the mxCell inside has the style and geometry.
        struct Cell { var id: String; var attrs: [String: String]; var geometry: SVGTree?; var value: String }
        var byID: [String: Cell] = [:]
        var order: [String] = []
        for c in cells {
            var attrs = c.attrs
            var geometry = c.children.first { $0.name == "mxGeometry" }
            if c.name != "mxCell", let inner = c.children.first(where: { $0.name == "mxCell" }) {
                attrs = inner.attrs.merging(["id": c.attrs["id"] ?? "", "label": c.attrs["label"] ?? ""]) { a, _ in a }
                geometry = inner.children.first { $0.name == "mxGeometry" }
            }
            guard let id = attrs["id"], !id.isEmpty else { continue }
            byID[id] = Cell(id: id, attrs: attrs, geometry: geometry, value: attrs["value"] ?? attrs["label"] ?? "")
            order.append(id)
        }

        // Absolute origin of a vertex: its geometry plus its parent vertices'.
        var originCache: [String: CGPoint] = [:]
        func origin(of id: String, depth: Int = 0) -> CGPoint {
            if let o = originCache[id] { return o }
            guard depth < 20, let c = byID[id] else { return .zero }
            var o = CGPoint.zero
            if c.attrs["vertex"] == "1", let g = c.geometry {
                o = CGPoint(x: Double(g.attrs["x"] ?? "0") ?? 0, y: Double(g.attrs["y"] ?? "0") ?? 0)
            }
            if let p = c.attrs["parent"], p != id, byID[p]?.attrs["vertex"] == "1" {
                let po = origin(of: p, depth: depth + 1)
                o = CGPoint(x: o.x + po.x, y: o.y + po.y)
            }
            originCache[id] = o
            return o
        }

        var uuids: [String: UUID] = [:]
        for id in order { uuids[id] = UUID() }
        let starter = StencilLibrary.starter

        // Labels of edges live in child cells.
        var edgeLabels: [String: String] = [:]
        var labelCells = Set<String>()
        for id in order {
            guard let c = byID[id], c.attrs["vertex"] == "1", let p = c.attrs["parent"], byID[p]?.attrs["edge"] == "1",
                  !c.value.isEmpty else { continue }
            edgeLabels[p] = plain(c.value); labelCells.insert(id)
        }

        var out: [Element] = []
        for id in order {
            guard let cell = byID[id], let uid = uuids[id], !labelCells.contains(id) else { continue }
            let (base, kv) = parseStyle(cell.attrs["style"])
            var st = Style()
            st.roughness = kv["sketch"] == "1" ? 1 : 0
            st.strokeWidth = Double(kv["strokeWidth"] ?? "") ?? 1
            let opacity = (Double(kv["opacity"] ?? "") ?? 100) / 100
            if let c = color(kv["strokeColor"]) { st.stroke = c ?? .clear } else { st.stroke = RGBA(r: 0, g: 0, b: 0) }
            if let c = color(kv["fillColor"]) { st.fill = c ?? .clear } else { st.fill = .clear }
            st.stroke.a *= opacity; st.fill.a *= opacity
            if kv["dashed"] == "1" { st.dash = kv["dashPattern"].map { $0.hasPrefix("1 ") ? .dotted : .dashed } ?? .dashed }
            st.fontSize = Double(kv["fontSize"] ?? "") ?? 12

            if cell.attrs["edge"] == "1" {
                func end(_ key: String, point: String) -> Endpoint? {
                    if let t = cell.attrs[key], let tid = uuids[t], byID[t]?.attrs["vertex"] == "1" { return .bound(tid) }
                    if let p = cell.geometry?.children.first(where: { $0.name == "mxPoint" && $0.attrs["as"] == point }) {
                        return .free(CGPoint(x: Double(p.attrs["x"] ?? "0") ?? 0, y: Double(p.attrs["y"] ?? "0") ?? 0))
                    }
                    return nil
                }
                guard let s = end("source", point: "sourcePoint"), let e = end("target", point: "targetPoint") else { continue }
                var cd = ConnectorData(start: s, end: e)
                cd.endHead = head(kv["endArrow"], default: .triangle)
                cd.startHead = head(kv["startArrow"], default: .none)
                let es = kv["edgeStyle"] ?? ""
                if es.contains("orthogonal") || es.contains("elbow") { cd.routing = .elbow }
                else if kv["curved"] == "1" { cd.routing = .curved }
                // Bends are relative to the edge's parent, when that is a container.
                let base = cell.attrs["parent"].flatMap { byID[$0]?.attrs["vertex"] == "1" ? origin(of: $0) : nil } ?? .zero
                let bends = (cell.geometry?.children.first { $0.name == "Array" && $0.attrs["as"] == "points" }?.children ?? [])
                    .filter { $0.name == "mxPoint" }
                    .map { Waypoint(x: base.x + (Double($0.attrs["x"] ?? "0") ?? 0), y: base.y + (Double($0.attrs["y"] ?? "0") ?? 0)) }
                if !bends.isEmpty { cd.waypoints = bends }
                if let jump = kv["jumpStyle"], jump != "none" { cd.hops = true }
                st.fill = .clear
                st.strokeWidth = max(1, st.strokeWidth * 1.5)
                var el = Element(id: uid, kind: .connector, frame: .zero, style: st, seed: .random(in: 1...UInt32.max),
                                 layerID: layerID, text: edgeLabels[id] ?? (cell.value.isEmpty ? nil : plain(cell.value)), connector: cd)
                el.style.stroke = st.stroke
                out.append(el)
                continue
            }

            guard cell.attrs["vertex"] == "1", let g = cell.geometry else { continue }
            let o = origin(of: id)
            let w = Double(g.attrs["width"] ?? "") ?? 0, h = Double(g.attrs["height"] ?? "") ?? 0
            guard w > 0 || h > 0 else { continue }
            let frame = CGRect(x: o.x, y: o.y, width: max(w, 1), height: max(h, 1))
            let label = plain(cell.value)
            let rotation = (Double(kv["rotation"] ?? "") ?? 0) * .pi / 180
            let name = kv["shape"] ?? base.first ?? ""
            var fontStyle = st
            if let c = color(kv["fontColor"]), let col = c { fontStyle.stroke = col }

            func common(_ e: inout Element) {
                if rotation != 0 { e.rotation = rotation }
            }

            if name == "text" || (base.contains("text") && kv["shape"] == nil) {
                var e = Element(id: uid, kind: .text, frame: frame, style: fontStyle, layerID: layerID, text: label)
                e.style.fill = .clear
                common(&e)
                out.append(e)
                continue
            }
            if let builtInName = builtIn(for: name), let item = starter.items.first(where: { $0.name == builtInName }),
               item.width > 0, item.height > 0 {
                let gid = item.elements.count > 1 ? UUID() : nil
                let sx = frame.width / item.width, sy = frame.height / item.height
                var biggest = 0
                for (i, src) in item.elements.enumerated() where src.frame.width * src.frame.height > item.elements[biggest].frame.width * item.elements[biggest].frame.height { biggest = i }
                for (i, src) in item.elements.enumerated() {
                    var e = src
                    e.id = i == 0 ? uid : UUID()
                    e.layerID = layerID
                    e.groupID = gid
                    e.x = frame.minX + src.x * sx; e.y = frame.minY + src.y * sy
                    e.width = src.width * sx; e.height = src.height * sy
                    e.style = st
                    e.style.stroke = st.stroke
                    e.seed = .random(in: 1...UInt32.max)
                    e.text = i == biggest && !label.isEmpty ? label : nil
                    if i == biggest { e.style.fontSize = fontStyle.fontSize }
                    common(&e)
                    out.append(e)
                }
                continue
            }
            let kind: ElementKind
            switch name {
            case "ellipse", "doubleEllipse": kind = .ellipse
            case "rhombus": kind = .diamond
            default: kind = .rectangle
            }
            var e = Element(id: uid, kind: kind, frame: frame, style: st, layerID: layerID,
                            text: label.isEmpty ? nil : label)
            if !label.isEmpty { e.style.fontSize = fontStyle.fontSize }
            common(&e)
            out.append(e)
        }
        return out
    }
}
