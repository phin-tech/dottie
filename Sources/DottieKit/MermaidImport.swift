import Foundation
import CoreGraphics

/// Why some Mermaid text could not be imported. Line numbers are 1-based in the text as given.
public enum MermaidError: Error, LocalizedError, CustomStringConvertible, Equatable {
    /// A Mermaid diagram that is not a flowchart, e.g. `sequenceDiagram`.
    case unsupportedDiagram(String)
    /// The text does not start with `flowchart` or `graph`.
    case notMermaid
    /// A flowchart with no nodes.
    case empty
    case syntax(line: Int, String)

    public var description: String {
        switch self {
        case .unsupportedDiagram(let kind):
            return "This is a Mermaid \(kind) diagram; Dottie only imports flowcharts (text starting with `flowchart` or `graph`)."
        case .notMermaid:
            return "Not a Mermaid flowchart: the text should start with `flowchart` or `graph`, e.g. `flowchart TD`."
        case .empty:
            return "The Mermaid flowchart has no nodes."
        case .syntax(let line, let message):
            return "Mermaid line \(line): \(message)"
        }
    }
    public var errorDescription: String? { description }
}

/// Turns Mermaid flowchart text (`flowchart` / `graph`) into nodes and edges for `DiagramOps.build`, which lays
/// them out the same way `build_diagram` does.
///
/// Shapes map to the nearest Dottie kind: `((circle))`, `(((double)))` and `([stadium])` are ellipses, `{diamond}` a
/// diamond, everything else (`[rect]`, `(rounded)`, `[[subroutine]]`, `[(database)]`, `>flag]`, `{{hexagon}}`,
/// parallelograms and trapezoids) a rectangle. Subgraphs are flattened: their nodes are kept, the frame is not drawn.
/// `style X fill:#hex` and `classDef` / `class` / `:::` fills are applied; other styling is ignored.
public enum MermaidImporter {
    public struct Diagram: Sendable {
        public var nodes: [DiagramOps.NodeSpec]
        public var edges: [DiagramOps.EdgeSpec]
        public var direction: LayoutDirection
        /// Things the import changed or left out, worth telling the user (flattened subgraphs, flipped direction, ...).
        public var notes: [String]
    }

    public static let fileExtensions = ["mmd", "mermaid"]

    /// Whether `text` looks like a Mermaid flowchart: its first real token is `flowchart` or `graph`
    /// (after an optional ```` ```mermaid ```` fence, front matter, comments and `%%{init}%%` directives).
    public static func isFlowchart(_ text: String) -> Bool {
        guard let first = statements(in: text).first else { return false }
        let word = first.text.prefix { !$0.isWhitespace && $0 != ";" }
        return word == "flowchart" || word == "graph" || word == "flowchart-elk"
    }

    // MARK: Building

    /// Parses `text` and adds the diagram to `doc` below existing content. Returns node id -> element id and notes.
    @discardableResult
    public static func build(_ doc: inout DottieDocument, mermaid text: String, roughness: Double = 1) throws
        -> (ids: [String: UUID], notes: [String]) {
        let d = try parse(text)
        let ids = try DiagramOps.build(&doc, nodes: d.nodes, edges: d.edges, direction: d.direction, roughness: roughness)
        return (ids, d.notes)
    }

    /// The diagram as loose elements with its top-left corner at (0, 0), ready for `DottieDocument.insert`.
    public static func elements(from text: String, roughness: Double = 1) throws
        -> (elements: [Element], size: CGSize, notes: [String]) {
        var doc = DottieDocument()
        let notes = try build(&doc, mermaid: text, roughness: roughness).notes
        let b = Exporter.bounds(of: doc, padding: 0)
        for i in doc.elements.indices where doc.elements[i].kind != .connector {
            doc.elements[i].x -= b.minX; doc.elements[i].y -= b.minY
        }
        return (doc.elements, b.size, notes)
    }

    /// A one-page Dottie file holding the diagram.
    public static func file(from text: String, roughness: Double = 1) throws -> DottieFile {
        var doc = DottieDocument()
        try build(&doc, mermaid: text, roughness: roughness)
        var file = DottieFile()
        file.pages[0].elements = doc.elements
        file.pages[0].layers = doc.layers
        return file
    }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> Diagram {
        var p = Parser()
        try p.run(statements(in: text))
        return try p.diagram()
    }

    struct Statement { var text: String; var line: Int }

    /// Splits the text into trimmed statements (lines, then `;` outside quotes), dropping comments, directives,
    /// front matter and code fences.
    static func statements(in text: String) -> [Statement] {
        var out: [Statement] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var inFrontMatter = false
        var sawContent = false
        for (n, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---", !sawContent || inFrontMatter { inFrontMatter.toggle(); sawContent = true; continue }
            if inFrontMatter { continue }
            if trimmed.hasPrefix("```") { continue }
            var current = ""
            var inQuote = false
            let chars = Array(raw)
            var i = 0
            func flush() {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(Statement(text: t, line: n + 1)); sawContent = true }
                current = ""
            }
            while i < chars.count {
                let c = chars[i]
                if c == "\"" { inQuote.toggle() }
                if !inQuote, c == "%", i + 1 < chars.count, chars[i + 1] == "%" { break }
                if !inQuote, c == ";" { flush() } else { current.append(c) }
                i += 1
            }
            flush()
        }
        return out
    }

    enum Head { case arrow, dot, cross }

    struct Link {
        var start: Head?
        var end: Head?
        var dash = false
        var thick = false
        var invisible = false
        var label: String?
    }

    struct Parser {
        var order: [String] = []
        var nodes: [String: DiagramOps.NodeSpec] = [:]
        var explicitLabel: Set<String> = []
        var nodeClasses: [String: [String]] = [:]
        var classFills: [String: RGBA] = [:]
        var styleFills: [String: RGBA] = [:]
        var edges: [DiagramOps.EdgeSpec] = []
        var direction: LayoutDirection = .topToBottom
        var notes: [String] = []
        var subgraphTitles: [String: String] = [:]
        var subgraphs = 0
        var subgraphDepth = 0
        var ignored: [String: Int] = [:]
        var invisibleLinks = 0
        var headerSeen = false

        mutating func run(_ statements: [Statement]) throws {
            guard !statements.isEmpty else { throw MermaidError.notMermaid }
            for s in statements {
                if !headerSeen { try header(s); continue }
                try statement(s)
            }
            if subgraphDepth > 0 { throw MermaidError.syntax(line: statements.last!.line, "`subgraph` without a matching `end`") }
        }

        mutating func header(_ s: Statement) throws {
            let words = s.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let kind = words[0]
            guard kind == "flowchart" || kind == "graph" || kind == "flowchart-elk" else {
                let known = ["sequenceDiagram", "classDiagram", "classDiagram-v2", "stateDiagram", "stateDiagram-v2",
                             "erDiagram", "gantt", "pie", "journey", "gitGraph", "mindmap", "timeline", "quadrantChart",
                             "requirementDiagram", "C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment",
                             "sankey-beta", "xychart-beta", "block-beta", "packet-beta", "architecture-beta", "kanban",
                             "radar-beta", "treemap-beta", "zenuml"]
                if known.contains(kind) { throw MermaidError.unsupportedDiagram(kind) }
                throw MermaidError.notMermaid
            }
            headerSeen = true
            if words.count > 1 { try setDirection(words[1], line: s.line) }
            if words.count > 2 { throw MermaidError.syntax(line: s.line, "unexpected text after `\(kind) \(words[1])`") }
        }

        mutating func setDirection(_ d: String, line: Int) throws {
            switch d.uppercased() {
            case "TD", "TB": direction = .topToBottom
            case "BT": direction = .topToBottom; note("Bottom-to-top (BT) is drawn top to bottom.")
            case "LR": direction = .leftToRight
            case "RL": direction = .leftToRight; note("Right-to-left (RL) is drawn left to right.")
            default: throw MermaidError.syntax(line: line, "unknown direction `\(d)` (use TD, TB, BT, LR or RL)")
            }
        }

        mutating func note(_ s: String) { if !notes.contains(s) { notes.append(s) } }

        mutating func statement(_ s: Statement) throws {
            let t = s.text
            let word = String(t.prefix { !$0.isWhitespace })
            let rest = t.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            switch word {
            case "end":
                guard subgraphDepth > 0 else { throw MermaidError.syntax(line: s.line, "`end` without a `subgraph`") }
                subgraphDepth -= 1
            case "subgraph":
                subgraphDepth += 1; subgraphs += 1
                subgraph(rest)
            case "direction":
                break // Per-subgraph direction; subgraphs are flattened.
            case "style":
                let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
                if parts.count == 2, let fill = Self.fill(in: parts[1]) {
                    for id in parts[0].split(separator: ",") { styleFills[String(id)] = fill }
                }
            case "classDef":
                let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
                if parts.count == 2, let fill = Self.fill(in: parts[1]) {
                    for name in parts[0].split(separator: ",") { classFills[String(name)] = fill }
                }
            case "class":
                let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
                if parts.count == 2 {
                    for id in parts[0].split(separator: ",") { nodeClasses[String(id), default: []].append(parts[1]) }
                }
            case "linkStyle", "click", "accTitle", "accTitle:", "accDescr", "accDescr:", "title":
                ignored[word.trimmingCharacters(in: CharacterSet(charactersIn: ":")), default: 0] += 1
            default:
                if word.hasPrefix("accTitle") || word.hasPrefix("accDescr") { return }
                try chain(s)
            }
        }

        /// `subgraph id`, `subgraph id [Title]`, `subgraph id["Title"]` or `subgraph Some title`.
        mutating func subgraph(_ rest: String) {
            guard !rest.isEmpty else { return }
            var s = Scanner(rest, line: 0)
            let id = s.identifier()
            s.skipSpace()
            if !id.isEmpty, s.peek == "[" {
                s.advance()
                if let label = try? s.label(until: ["]"]) { subgraphTitles[id] = label }
            } else if !id.isEmpty, s.atEnd {
                subgraphTitles[id] = id
            } else {
                subgraphTitles[rest] = MermaidImporter.cleanLabel(rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }

        static func fill(in style: String) -> RGBA? {
            for part in style.split(separator: ",") {
                let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, kv[0] == "fill" { return RGBA(hex: kv[1]) }
            }
            return nil
        }

        /// `A --> B & C -- label --> D`
        mutating func chain(_ st: Statement) throws {
            var s = Scanner(st.text, line: st.line)
            var previous = try nodeGroup(&s)
            while true {
                s.skipSpace()
                if s.atEnd { break }
                let link = try s.link()
                s.skipSpace()
                let next = try nodeGroup(&s)
                if link.invisible { invisibleLinks += 1 } else {
                    for a in previous { for b in next { edges.append(Self.edge(a, b, link)) } }
                }
                previous = next
            }
        }

        static func edge(_ from: String, _ to: String, _ l: Link) -> DiagramOps.EdgeSpec {
            func head(_ h: Head?) -> Arrowhead {
                switch h { case .arrow: .arrow; case .dot: .dot; case .cross: .bar; case nil: .none }
            }
            var look = DiagramOps.Look()
            if l.dash { look.dash = .dashed }
            if l.thick { look.strokeWidth = 4 }
            if l.start != nil { look.startHead = head(l.start) }
            if l.end != nil, l.end != .arrow { look.endHead = head(l.end) }
            return DiagramOps.EdgeSpec(from: from, to: to, arrow: l.end != nil, label: l.label, look: look)
        }

        mutating func nodeGroup(_ s: inout Scanner) throws -> [String] {
            var ids = [try node(&s)]
            while true {
                let save = s.i
                s.skipSpace()
                if s.peek == "&" {
                    s.advance(); s.skipSpace()
                    ids.append(try node(&s))
                } else { s.i = save; break }
            }
            return ids
        }

        /// A node reference, with an optional shape and label and an optional `:::class`.
        mutating func node(_ s: inout Scanner) throws -> String {
            let id = s.identifier()
            guard !id.isEmpty else {
                throw MermaidError.syntax(line: s.line, s.atEnd ? "expected a node after the link"
                                          : "expected a node id at `\(s.remainder.prefix(20))`")
            }
            if let (kind, label) = try s.shape() {
                define(id, kind: kind, label: label)
            } else {
                define(id, kind: nil, label: nil)
            }
            if s.consume(":::") {
                let cls = s.identifier()
                nodeClasses[id, default: []].append(cls)
            }
            return id
        }

        mutating func define(_ id: String, kind: ElementKind?, label: String?) {
            if nodes[id] == nil {
                order.append(id)
                nodes[id] = DiagramOps.NodeSpec(key: id, text: id)
            }
            if let kind { nodes[id]!.kind = kind }
            if let label { nodes[id]!.text = label; explicitLabel.insert(id) }
        }

        func diagram() throws -> Diagram {
            guard !order.isEmpty else { throw MermaidError.empty }
            var notes = self.notes
            var list: [DiagramOps.NodeSpec] = []
            for id in order {
                var n = nodes[id]!
                if !explicitLabel.contains(id), let title = subgraphTitles[id] { n.text = title }
                if let f = classFills["default"] { n.fill = f }
                for cls in nodeClasses[id] ?? [] { if let f = classFills[cls] { n.fill = f } }
                if let f = styleFills[id] { n.fill = f }
                list.append(n)
            }
            if subgraphs > 0 {
                notes.append("Flattened \(subgraphs) subgraph\(subgraphs == 1 ? "" : "s"): their nodes are kept, the frames are not drawn.")
            }
            if invisibleLinks > 0 { notes.append("Skipped \(invisibleLinks) invisible link\(invisibleLinks == 1 ? "" : "s") (~~~).") }
            let skipped = ignored.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            if !skipped.isEmpty { notes.append("Ignored " + skipped.joined(separator: ", ") + " line(s).") }
            return Diagram(nodes: list, edges: edges, direction: direction, notes: notes)
        }
    }

    /// Mermaid label text to plain text: `<br>` becomes a newline, other tags are dropped, entities decoded.
    static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") { s = String(s.dropFirst().dropLast()) } // Markdown string
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        for (entity, char) in [("#quot;", "\""), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
                               ("#59;", ";"), ("#35;", "#"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        // Remaining numeric entities: #9829; or &#9829;
        while let r = s.range(of: #"&?#[0-9]+;"#, options: .regularExpression) {
            let digits = s[r].filter(\.isNumber)
            let scalar = UInt32(digits).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            s.replaceSubrange(r, with: scalar)
        }
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    /// Index scanner over one statement.
    struct Scanner {
        var c: [Character]
        var i = 0
        let line: Int
        init(_ text: String, line: Int) { c = Array(text); self.line = line }

        var atEnd: Bool { i >= c.count }
        var peek: Character? { i < c.count ? c[i] : nil }
        func peek(_ k: Int) -> Character? { i + k < c.count ? c[i + k] : nil }
        var remainder: String { String(c[min(i, c.count)...]) }
        mutating func advance(_ n: Int = 1) { i += n }
        mutating func skipSpace() { while let p = peek, p.isWhitespace { i += 1 } }
        func starts(with s: String) -> Bool {
            let a = Array(s)
            guard i + a.count <= c.count else { return false }
            return Array(c[i..<i + a.count]) == a
        }
        mutating func consume(_ s: String) -> Bool {
            guard starts(with: s) else { return false }
            i += s.count
            return true
        }

        func error(_ m: String) -> MermaidError { .syntax(line: line, m) }

        static func isIDChar(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }

        /// Letters, digits and `_`; `-` and `.` only between id characters, so `a-b` is one id but `a-->b` is not.
        mutating func identifier() -> String {
            var out = ""
            while let ch = peek {
                if Self.isIDChar(ch) { out.append(ch); i += 1; continue }
                if ch == "-" || ch == ".", !out.isEmpty, let n = peek(1), Self.isIDChar(n) {
                    out.append(ch); i += 1; continue
                }
                break
            }
            return out
        }

        /// Shape openers, longest first, with their closers and Dottie kind.
        static let shapes: [(open: String, close: [String], kind: ElementKind)] = [
            ("(((", [")))"], .ellipse), ("((", ["))"], .ellipse), ("([", ["])"], .ellipse),
            ("[[", ["]]"], .rectangle), ("[(", [")]"], .rectangle),
            ("[/", ["/]", "\\]"], .rectangle), ("[\\", ["\\]", "/]"], .rectangle),
            ("{{", ["}}"], .rectangle), (">", ["]"], .rectangle),
            ("[", ["]"], .rectangle), ("(", [")"], .rectangle), ("{", ["}"], .diamond),
        ]

        /// The shape and label right after a node id, if any.
        mutating func shape() throws -> (ElementKind, String)? {
            if starts(with: "@{") { return try expandedShape() }
            for s in Self.shapes where starts(with: s.open) {
                // `>` right after an id could also be the end of `--->`; ids never end in `-`, so it is a flag here.
                i += s.open.count
                let label = try self.label(until: s.close)
                return (s.kind, label)
            }
            return nil
        }

        /// Reads a label up to and past one of `closers`. A quoted label runs to its closing quote first.
        mutating func label(until closers: [String]) throws -> String {
            skipSpace()
            var text = ""
            if peek == "\"" {
                i += 1
                while let ch = peek, ch != "\"" { text.append(ch); i += 1 }
                guard peek == "\"" else { throw error("unterminated quoted label") }
                i += 1
                skipSpace()
                guard let close = closers.first(where: { starts(with: $0) }) else {
                    throw error("expected `\(closers[0])` after the quoted label")
                }
                i += close.count
                return MermaidImporter.cleanLabel(text)
            }
            while !atEnd {
                if let close = closers.first(where: { starts(with: $0) }) {
                    i += close.count
                    return MermaidImporter.cleanLabel(text)
                }
                text.append(c[i]); i += 1
            }
            throw error("unterminated label: missing `\(closers[0])`")
        }

        /// `A@{ shape: circle, label: "Start" }` (Mermaid 11).
        mutating func expandedShape() throws -> (ElementKind, String)? {
            i += 2
            var body = ""
            var inQuote = false
            while let ch = peek {
                i += 1
                if ch == "\"" { inQuote.toggle() }
                if ch == "}", !inQuote { break }
                body.append(ch)
            }
            var kind = ElementKind.rectangle
            var label: String?
            for part in body.split(separator: ",") {
                let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                let v = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                switch kv[0] {
                case "shape":
                    switch v {
                    case "circle", "circ", "sm-circ", "small-circle", "dbl-circ", "double-circle", "fr-circ", "stop",
                         "stadium", "pill", "terminal", "ellipse", "f-circ", "start", "junction":
                        kind = .ellipse
                    case "diam", "diamond", "decision", "question":
                        kind = .diamond
                    default: kind = .rectangle
                    }
                case "label": label = MermaidImporter.cleanLabel(v)
                default: break
                }
            }
            return (kind, label ?? "")
        }

        /// One link: `-->`, `---`, `-.->`, `==>`, `<-->`, `--o`, `--x`, `~~~`, with `|label|` or `-- label -->`.
        mutating func link() throws -> Link {
            var l = Link()
            let begin = i
            if peek == "<" { l.start = .arrow; i += 1 }
            else if let p = peek, p == "o" || p == "x", let n = peek(1), "-=.".contains(n) {
                l.start = p == "o" ? .dot : .cross; i += 1
            }
            guard let first = peek else { throw error("expected a link") }

            /// An end head right after the stroke: `>`, or `o` / `x` when not the start of a node id.
            func endHead(_ s: inout Scanner) -> Head? {
                if s.peek == ">" { s.i += 1; return .arrow }
                if let p = s.peek, p == "o" || p == "x" {
                    let n = s.peek(1)
                    if n == nil || n!.isWhitespace || n == "|" { s.i += 1; return p == "o" ? .dot : .cross }
                }
                return nil
            }

            func run(_ ch: Character) -> Int { var n = 0; while peek == ch { n += 1; i += 1 }; return n }

            switch first {
            case "~":
                guard run("~") >= 3 else { throw error("invalid link") }
                l.invisible = true
            case "=":
                let n = run("=")
                guard n >= 2 else { i = begin; throw error("invalid link at `\(remainder.prefix(12))`") }
                if let h = endHead(&self) { l.end = h }
                else if n == 2 && peek != nil && peek != "=" {
                    try textLink(&l, closeChar: "=", dotted: false)
                }
                l.thick = true
            case "-":
                if peek(1) == "." {
                    i += 1
                    let dots = run(".")
                    if peek == "-" {
                        i += 1
                        l.end = endHead(&self)
                    } else if dots == 1 {
                        try textLink(&l, closeChar: "-", dotted: true)
                    } else { throw error("invalid dotted link") }
                    l.dash = true
                } else {
                    let n = run("-")
                    guard n >= 2 else { i = begin; throw error("invalid link at `\(remainder.prefix(12))`") }
                    if let h = endHead(&self) { l.end = h }
                    else if n == 2 { try textLink(&l, closeChar: "-", dotted: false) }
                }
            default:
                throw error("expected a link (such as -->) at `\(remainder.prefix(20))`")
            }
            if l.start == .arrow, l.end == nil, !l.invisible { throw error("`<` link needs an arrow at the other end too, like <-->") }

            // |label|
            let save = i
            skipSpace()
            if peek == "|" {
                i += 1
                var text = ""
                var inQuote = false
                while let ch = peek, ch != "|" || inQuote {
                    if ch == "\"" { inQuote.toggle() }
                    text.append(ch); i += 1
                }
                guard peek == "|" else { throw error("unterminated |label|") }
                i += 1
                let t = text.trimmingCharacters(in: .whitespaces)
                let unquoted = t.count >= 2 && t.hasPrefix("\"") && t.hasSuffix("\"") ? String(t.dropFirst().dropLast()) : t
                l.label = MermaidImporter.cleanLabel(unquoted)
            } else { i = save }
            return l
        }

        /// The `-- text -->`, `-. text .->` and `== text ==>` forms; the opening token is already consumed.
        mutating func textLink(_ l: inout Link, closeChar: Character, dotted: Bool) throws {
            var text = ""
            while !atEnd {
                if dotted {
                    // closing `.-`, `..-`, then optional head
                    if peek == ".", peek(1) == "." || peek(1) == "-" {
                        var j = i; while j < c.count, c[j] == "." { j += 1 }
                        if j < c.count, c[j] == "-" {
                            i = j + 1
                            if peek == ">" { i += 1; l.end = .arrow }
                            l.label = MermaidImporter.cleanLabel(text.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
                            return
                        }
                    }
                } else if peek == closeChar, peek(1) == closeChar {
                    var n = 0; while peek == closeChar { n += 1; i += 1 }
                    if peek == ">" { i += 1; l.end = .arrow }
                    else if let p = peek, p == "o" || p == "x", peek(1) == nil || peek(1)!.isWhitespace {
                        i += 1; l.end = p == "o" ? .dot : .cross
                    } else if n < 3 { throw error("a labelled link needs `\(closeChar)\(closeChar)>` or `\(closeChar)\(closeChar)\(closeChar)` to close it") }
                    l.label = MermaidImporter.cleanLabel(text.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
                    return
                }
                text.append(c[i]); i += 1
            }
            throw error("unterminated link label: missing `\(closeChar)\(closeChar)>`")
        }
    }
}
