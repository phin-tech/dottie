import Foundation
import CoreGraphics

extension Exporter {
    /// The page as a Mermaid flowchart, readable back by `MermaidImporter`.
    ///
    /// Shapes on visible layers become nodes (a rectangle `[ ]`, an ellipse `(( ))` or, when wide, `([ ])`, a
    /// diamond `{ }`; notes and text `[ ]`) and connectors attached at both ends become links: `-->` or `---`,
    /// `-.->` when dashed, `==>` when thick, `<-->` for two heads, `--o` / `--x` for dot and bar heads, with
    /// `|label|`. Node ids are `n1`, `n2`, ... in element order, or the element's `anchor` when that is a valid id.
    /// Fills are kept as `style` lines. Freehand strokes, paths and anything else Mermaid cannot show are skipped,
    /// and a `%%` comment says how many.
    public static func mermaid(_ doc: DottieDocument) -> String {
        let visible = Set(doc.layers.filter(\.visible).map(\.id))
        let elements = doc.elements.filter { visible.contains($0.layerID) }

        var nodes: [Element] = []
        var skippedShapes = 0
        for e in elements where e.kind != .connector {
            switch e.kind {
            case .rectangle, .ellipse, .diamond, .note, .text: nodes.append(e)
            default: skippedShapes += 1
            }
        }

        // Ids: valid, unique anchors first, then n1, n2, ... for the rest.
        let reserved: Set<String> = ["end", "graph", "flowchart", "subgraph", "style", "class", "classDef", "click",
                                     "linkStyle", "direction", "default", "accTitle", "accDescr"]
        var ids: [UUID: String] = [:]
        var used = Set<String>()
        for e in nodes {
            guard let a = e.anchor, isValidID(a), !reserved.contains(a), !used.contains(a) else { continue }
            ids[e.id] = a; used.insert(a)
        }
        var counter = 0
        for e in nodes where ids[e.id] == nil {
            var id: String
            repeat { counter += 1; id = "n\(counter)" } while used.contains(id)
            ids[e.id] = id; used.insert(id)
        }

        var edges: [(from: Element, to: Element, connector: Element)] = []
        var skippedConnectors = 0
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in elements where c.kind == .connector {
            guard let data = c.connector, let a = data.start.elementID.flatMap({ byID[$0] }),
                  let b = data.end.elementID.flatMap({ byID[$0] }) else { skippedConnectors += 1; continue }
            edges.append((a, b, c))
        }

        // LR when most links run left to right, else top-down.
        let rightward = edges.filter { e in
            let dx = e.to.frame.midX - e.from.frame.midX, dy = e.to.frame.midY - e.from.frame.midY
            return dx > abs(dy)
        }.count
        let direction = !edges.isEmpty && rightward * 2 > edges.count ? "LR" : "TD"

        var lines = ["flowchart \(direction)"]
        var skipped: [String] = []
        if skippedShapes > 0 { skipped.append("\(skippedShapes) shape\(skippedShapes == 1 ? "" : "s") (freehand, paths, ...)") }
        if skippedConnectors > 0 {
            skipped.append("\(skippedConnectors) connector\(skippedConnectors == 1 ? "" : "s") not attached at both ends")
        }
        if !skipped.isEmpty { lines.append("    %% Skipped " + skipped.joined(separator: " and ")) }

        for e in nodes {
            let label = "\"" + escape(e.text ?? "") + "\""
            let shape: String
            switch e.kind {
            case .ellipse: shape = e.width > e.height * 1.6 ? "([\(label)])" : "((\(label)))"
            case .diamond: shape = "{\(label)}"
            default: shape = "[\(label)]"
            }
            lines.append("    \(ids[e.id]!)\(shape)")
        }
        for (a, b, c) in edges {
            var from = a, to = b
            var start = c.connector!.startHead, end = c.connector!.endHead
            if end == .none, start != .none { swap(&from, &to); swap(&start, &end) }
            let link = linkToken(start: start, end: end, style: c.style)
            // Quoted so `;` and `%%` in a label are not read as a statement break or a comment.
            let label = c.text.map(escape).flatMap { $0.isEmpty ? nil : "|\"\($0.replacingOccurrences(of: "|", with: "#124;"))\"|" } ?? ""
            lines.append("    \(ids[from.id]!) \(link)\(label) \(ids[to.id]!)")
        }
        for e in nodes where e.style.fill.a > 0 {
            lines.append("    style \(ids[e.id]!) fill:\(hex(e.style.fill))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isValidID(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" } && s.allSatisfy(\.isASCII)
    }

    /// Quoted-label text: quotes and angle brackets as Mermaid entity codes, newlines as `<br>`.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "#", with: "#35;")
            .replacingOccurrences(of: "\"", with: "#quot;")
            .replacingOccurrences(of: "<", with: "#lt;")
            .replacingOccurrences(of: ">", with: "#gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func linkToken(start: Arrowhead, end: Arrowhead, style: Style) -> String {
        let dashed = style.dash != .solid
        let thick = !dashed && style.strokeWidth >= 3.5
        let hasEnd = end != .none, hasStart = start != .none
        if dashed { return (hasStart && hasEnd ? "<" : "") + (hasEnd ? "-.->" : "-.-") }
        if thick { return (hasStart && hasEnd ? "<" : "") + (hasEnd ? "==>" : "===") }
        func mark(_ h: Arrowhead, isStart: Bool) -> String {
            switch h {
            case .none: return ""
            case .dot: return "o"
            case .bar: return "x"
            case .arrow, .triangle: return isStart ? "<" : ">"
            }
        }
        if !hasEnd { return "---" }
        return mark(start, isStart: true) + "--" + mark(end, isStart: false)
    }

    private static func hex(_ c: RGBA) -> String {
        func b(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + b(c.r) + b(c.g) + b(c.b) + (c.a < 1 ? b(c.a) : "")
    }
}
