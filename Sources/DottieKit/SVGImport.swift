import Foundation
import CoreGraphics

/// Reads an SVG file into `.path` elements: the common subset that icon sets, stencil kits and
/// diagram libraries use. Geometry (paths, basic shapes, transforms, `<use>`) and paint (fill, stroke,
/// opacity, CSS classes, gradients flattened to their first stop) come through; text, clipping, masks,
/// filters and images do not.
public enum SVGImporter {
    public struct Options: Sendable {
        /// true keeps each shape's own colors and exact geometry. false restyles: strokes become the
        /// document's automatic ink and shapes take `roughness`, while fills are kept.
        public var keepOriginalColors = true
        /// Used when restyling; ignored (0, precise) when keeping original colors.
        public var roughness: Double = Style().roughness
        /// Uniform scale applied to the whole drawing.
        public var scale: Double = 1
        public init() {}
    }

    public struct Result: Sendable {
        /// Positioned with the drawing's top-left corner at the origin; grouped when there are several.
        public var elements: [Element]
        public var size: CGSize
    }

    public enum ImportError: Error, Equatable { case notSVG, tooLarge, empty }

    public static func importElements(from data: Data, layerID: UUID, options: Options = Options()) throws -> Result {
        guard data.count <= 8_000_000 else { throw ImportError.tooLarge }
        let root = try SVGTree.parse(data)
        guard root.name == "svg" else { throw ImportError.notSVG }
        var walker = Walker(root: root)
        walker.run()
        let shapes = walker.shapes
        guard !shapes.isEmpty else { throw ImportError.empty }

        var box = CGRect.null
        for s in shapes { box = box.union(s.path.boundingBoxOfPath) }
        var origin = box.origin, size = box.size
        if let vb = walker.viewBox, vb.width > 0, vb.height > 0 { origin = vb.origin; size = vb.size }
        let k = options.scale > 0 ? options.scale : 1
        var t = CGAffineTransform(translationX: -origin.x, y: -origin.y).concatenating(CGAffineTransform(scaleX: k, y: k))

        let group = shapes.count > 1 ? UUID() : nil
        var out: [Element] = []
        for s in shapes {
            guard let moved = s.path.copy(using: &t) else { continue }
            var st = Style()
            st.roughness = options.keepOriginalColors ? 0 : options.roughness
            st.fill = s.fill ?? .clear
            st.fillStyle = .solid
            if options.keepOriginalColors {
                st.stroke = s.stroke ?? .clear
                st.strokeWidth = s.stroke == nil ? 0 : max(0.25, s.strokeWidth * k)
            } else {
                st.stroke = .black
                st.strokeWidth = max(1, min(4, (s.stroke == nil ? 1.5 : s.strokeWidth) * k))
            }
            guard var e = Element.shape(moved, style: st, layerID: layerID, groupID: group) else { continue }
            if s.evenOdd { e.evenOdd = true }
            out.append(e)
        }
        guard !out.isEmpty else { throw ImportError.empty }
        return Result(elements: out, size: CGSize(width: size.width * k, height: size.height * k))
    }

    // MARK: Walking the tree

    struct Shape {
        var path: CGPath
        var fill: RGBA?
        var stroke: RGBA?
        var strokeWidth: Double
        var evenOdd: Bool
    }

    /// Paint and transform state that flows down the tree.
    struct Inherited {
        var fill: RGBA? = RGBA(r: 0, g: 0, b: 0)
        var stroke: RGBA?
        var color = RGBA(r: 0, g: 0, b: 0)
        var strokeWidth = 1.0
        var fillOpacity = 1.0, strokeOpacity = 1.0, opacity = 1.0
        var evenOdd = false
        var hidden = false
        var transform = CGAffineTransform.identity
    }

    struct Walker {
        let root: SVGTree
        var shapes: [Shape] = []
        var viewBox: CGRect?
        private var byID: [String: SVGTree] = [:]
        private var rules: [(selector: String, decls: [(String, String)])] = []
        private let skipped: Set<String> = ["defs", "symbol", "clipPath", "mask", "marker", "pattern", "linearGradient",
                                            "radialGradient", "style", "title", "desc", "metadata", "filter", "script",
                                            "text", "image", "foreignObject", "switch"]

        init(root: SVGTree) {
            self.root = root
            index(root)
        }

        private mutating func index(_ n: SVGTree) {
            if let id = n.attrs["id"] { byID[id] = n }
            if n.name == "style" { rules += CSS.parse(n.text) }
            for c in n.children { index(c) }
        }

        mutating func run() {
            if let vb = root.attrs["viewBox"] {
                let v = Numbers.list(vb)
                if v.count == 4 { viewBox = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
            }
            visit(root, inherited: Inherited(), depth: 0, isRoot: true)
        }

        private mutating func visit(_ n: SVGTree, inherited: Inherited, depth: Int, isRoot: Bool = false) {
            guard depth < 40, shapes.count < 20_000 else { return }
            if !isRoot, skipped.contains(n.name) { return }
            var st = inherited
            applyStyle(of: n, to: &st)
            if let t = n.attrs["transform"] { st.transform = Transform.parse(t).concatenating(st.transform) }
            guard !st.hidden else { return }

            switch n.name {
            case "g", "svg", "a":
                for c in n.children { visit(c, inherited: st, depth: depth + 1) }
            case "use":
                guard let ref = (n.attrs["href"] ?? n.attrs["xlink:href"]), ref.hasPrefix("#"),
                      let target = byID[String(ref.dropFirst())] else { return }
                let dx = Numbers.length(n.attrs["x"]), dy = Numbers.length(n.attrs["y"])
                var u = st
                u.transform = CGAffineTransform(translationX: dx, y: dy).concatenating(st.transform)
                if target.name == "symbol" || target.name == "svg" {
                    for c in target.children { visit(c, inherited: u, depth: depth + 1) }
                } else {
                    visit(target, inherited: u, depth: depth + 1)
                }
            default:
                guard let geometry = Geometry.path(for: n) else { return }
                var t = st.transform
                guard let moved = geometry.copy(using: &t) else { return }
                let scale = sqrt(abs(st.transform.a * st.transform.d - st.transform.b * st.transform.c))
                var fill = st.fill, stroke = st.stroke
                fill?.a *= st.fillOpacity * st.opacity
                stroke?.a *= st.strokeOpacity * st.opacity
                if (fill?.a ?? 0) <= 0 { fill = nil }
                if (stroke?.a ?? 0) <= 0 || st.strokeWidth <= 0 { stroke = nil }
                // Lines and open polylines have nothing to fill.
                if n.name == "line" { fill = nil }
                guard fill != nil || stroke != nil else { return }
                shapes.append(Shape(path: moved, fill: fill, stroke: stroke,
                                    strokeWidth: st.strokeWidth * scale, evenOdd: st.evenOdd))
            }
        }

        /// Presentation attributes, then matching CSS rules (tag, class, id), then the `style` attribute.
        private func applyStyle(of n: SVGTree, to st: inout Inherited) {
            var decls: [(String, String)] = n.attrs.map { ($0.key, $0.value) }
            let classes = (n.attrs["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            for pass in 0..<3 {
                for r in rules {
                    for sel in r.selector.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        let hit: Bool
                        switch pass {
                        case 0: hit = sel == n.name
                        case 1: hit = sel.hasPrefix(".") ? classes.contains(String(sel.dropFirst()))
                            : (sel.hasPrefix(n.name + ".") && classes.contains(String(sel.dropFirst(n.name.count + 1))))
                        default: hit = sel.hasPrefix("#") && n.attrs["id"] == String(sel.dropFirst())
                        }
                        if hit { decls += r.decls }
                    }
                }
            }
            decls += CSS.declarations(n.attrs["style"] ?? "")
            // `color` first, so currentColor resolves against this element's own value.
            for (k, v) in decls where k == "color" { if let c = Colors.parse(v, current: st.color) { st.color = c } }
            for (k, v) in decls {
                let value = v.trimmingCharacters(in: .whitespaces)
                switch k {
                case "fill": st.fill = paint(value, current: st.color, fallback: st.fill)
                case "stroke": st.stroke = paint(value, current: st.color, fallback: st.stroke)
                case "stroke-width": st.strokeWidth = Numbers.length(value, default: st.strokeWidth)
                case "opacity": st.opacity *= min(max(Double(value) ?? 1, 0), 1)
                case "fill-opacity": st.fillOpacity = min(max(Double(value) ?? 1, 0), 1)
                case "stroke-opacity": st.strokeOpacity = min(max(Double(value) ?? 1, 0), 1)
                case "fill-rule": st.evenOdd = value == "evenodd"
                case "display": if value == "none" { st.hidden = true }
                case "visibility": if value == "hidden" || value == "collapse" { st.hidden = true }
                default: break
                }
            }
        }

        private func paint(_ v: String, current: RGBA, fallback: RGBA?) -> RGBA? {
            if v == "none" || v == "transparent" { return nil }
            if v == "inherit" { return fallback }
            if v.hasPrefix("url(") {
                // A gradient or pattern: use the first stop's color so the shape keeps its hue.
                guard let open = v.firstIndex(of: "#"), let close = v.firstIndex(of: ")"), open < close else { return fallback }
                let id = String(v[v.index(after: open)..<close]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                return gradientColor(id, depth: 0) ?? fallback
            }
            return Colors.parse(v, current: current) ?? fallback
        }

        private func gradientColor(_ id: String, depth: Int) -> RGBA? {
            guard depth < 6, let g = byID[id] else { return nil }
            if let stop = g.children.first(where: { $0.name == "stop" }) {
                var value = stop.attrs["stop-color"]
                for (k, v) in CSS.declarations(stop.attrs["style"] ?? "") where k == "stop-color" { value = v }
                return Colors.parse(value ?? "#000", current: RGBA(r: 0, g: 0, b: 0))
            }
            if let ref = g.attrs["href"] ?? g.attrs["xlink:href"], ref.hasPrefix("#") {
                return gradientColor(String(ref.dropFirst()), depth: depth + 1)
            }
            return nil
        }
    }
}

// MARK: - XML tree

final class SVGTree {
    let name: String
    var attrs: [String: String]
    var children: [SVGTree] = []
    var text = ""
    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }

    static func parse(_ data: Data) throws -> SVGTree {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else { throw SVGImporter.ImportError.notSVG }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: SVGTree?
        var stack: [SVGTree] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let n = SVGTree(name: local, attrs: attributes)
            if let top = stack.last { top.children.append(n) } else if root == nil { root = n }
            stack.append(n)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}

// MARK: - CSS

enum CSS {
    static func declarations(_ s: String) -> [(String, String)] {
        s.split(separator: ";").compactMap { part in
            guard let colon = part.firstIndex(of: ":") else { return nil }
            let k = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let v = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return k.isEmpty ? nil : (k, v.replacingOccurrences(of: "!important", with: ""))
        }
    }

    /// Flat `selector { declarations }` rules; at-rules and anything nested are skipped.
    static func parse(_ css: String) -> [(selector: String, decls: [(String, String)])] {
        var s = css
        while let a = s.range(of: "/*"), let b = s.range(of: "*/", range: a.upperBound..<s.endIndex) {
            s.removeSubrange(a.lowerBound..<b.upperBound)
        }
        var out: [(String, [(String, String)])] = []
        for block in s.split(separator: "}") {
            guard let open = block.firstIndex(of: "{") else { continue }
            let selector = block[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selector.isEmpty, !selector.hasPrefix("@") else { continue } // compound selectors never match later
            out.append((selector, declarations(String(block[block.index(after: open)...]))))
        }
        return out
    }
}

// MARK: - Numbers, transforms, colors

enum Numbers {
    /// A leading number with an optional unit, in CSS pixels.
    static func length(_ s: String?, default d: Double = 0) -> Double {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return d }
        var sc = PathScanner(s)
        guard let v = sc.number() else { return d }
        let unit = s.dropFirst(sc.position).trimmingCharacters(in: .whitespaces)
        switch unit {
        case "pt": return v * 4 / 3
        case "mm": return v * 96 / 25.4
        case "cm": return v * 96 / 2.54
        case "in": return v * 96
        case "pc": return v * 16
        case "em", "rem": return v * 16
        default: return v
        }
    }

    static func list(_ s: String) -> [Double] {
        var sc = PathScanner(s), out: [Double] = []
        while let v = sc.number() { out.append(v) }
        return out
    }
}

enum Transform {
    static func parse(_ s: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")"), open < close {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ",")))
            let a = Numbers.list(String(rest[rest.index(after: open)..<close]))
            var t = CGAffineTransform.identity
            switch name {
            case "matrix" where a.count == 6: t = CGAffineTransform(a: a[0], b: a[1], c: a[2], d: a[3], tx: a[4], ty: a[5])
            case "translate" where a.count >= 1: t = CGAffineTransform(translationX: a[0], y: a.count > 1 ? a[1] : 0)
            case "scale" where a.count >= 1: t = CGAffineTransform(scaleX: a[0], y: a.count > 1 ? a[1] : a[0])
            case "rotate" where a.count >= 1:
                let r = CGAffineTransform(rotationAngle: a[0] * .pi / 180)
                if a.count == 3 {
                    t = CGAffineTransform(translationX: -a[1], y: -a[2]).concatenating(r)
                        .concatenating(CGAffineTransform(translationX: a[1], y: a[2]))
                } else { t = r }
            case "skewX" where a.count == 1: t = CGAffineTransform(a: 1, b: 0, c: tan(a[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewY" where a.count == 1: t = CGAffineTransform(a: 1, b: tan(a[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: break
            }
            // SVG lists apply left to right in the parent's frame: later ones are applied first to points.
            result = t.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}

enum Colors {
    static func parse(_ raw: String, current: RGBA) -> RGBA? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "currentcolor" { return current }
        if s.hasPrefix("#") {
            let h = Array(s.dropFirst())
            func hex(_ i: Int, _ n: Int) -> Double? {
                Int(String(h[i..<(i + n)]), radix: 16).map { Double($0) / (n == 1 ? 15 : 255) }
            }
            switch h.count {
            case 3, 4:
                guard let r = hex(0, 1), let g = hex(1, 1), let b = hex(2, 1) else { return nil }
                return RGBA(r: r, g: g, b: b, a: h.count == 4 ? (hex(3, 1) ?? 1) : 1)
            case 6, 8:
                guard let r = hex(0, 2), let g = hex(2, 2), let b = hex(4, 2) else { return nil }
                return RGBA(r: r, g: g, b: b, a: h.count == 8 ? (hex(6, 2) ?? 1) : 1)
            default: return nil
            }
        }
        if (s.hasPrefix("rgb(") || s.hasPrefix("rgba(")), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") {
            let parts = s[s.index(after: open)..<close].split(whereSeparator: { ",/ ".contains($0) }).map(String.init)
            guard parts.count >= 3 else { return nil }
            func channel(_ p: String) -> Double? {
                p.hasSuffix("%") ? Double(p.dropLast()).map { $0 / 100 } : Double(p).map { $0 / 255 }
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            var a = 1.0
            if parts.count > 3 { a = parts[3].hasSuffix("%") ? (Double(parts[3].dropLast()) ?? 100) / 100 : (Double(parts[3]) ?? 1) }
            return RGBA(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1), a: min(max(a, 0), 1))
        }
        return named[s].map { RGBA(r: Double($0 >> 16 & 255) / 255, g: Double($0 >> 8 & 255) / 255, b: Double($0 & 255) / 255) }
    }

    static let named: [String: Int] = [
        "black": 0x000000, "white": 0xffffff, "red": 0xff0000, "green": 0x008000, "blue": 0x0000ff,
        "yellow": 0xffff00, "orange": 0xffa500, "purple": 0x800080, "gray": 0x808080, "grey": 0x808080,
        "silver": 0xc0c0c0, "maroon": 0x800000, "olive": 0x808000, "lime": 0x00ff00, "aqua": 0x00ffff,
        "cyan": 0x00ffff, "teal": 0x008080, "navy": 0x000080, "fuchsia": 0xff00ff, "magenta": 0xff00ff,
        "pink": 0xffc0cb, "brown": 0xa52a2a, "gold": 0xffd700, "indigo": 0x4b0082, "violet": 0xee82ee,
        "lightgray": 0xd3d3d3, "lightgrey": 0xd3d3d3, "darkgray": 0xa9a9a9, "darkgrey": 0xa9a9a9,
        "dimgray": 0x696969, "dimgrey": 0x696969, "whitesmoke": 0xf5f5f5, "lightblue": 0xadd8e6,
        "lightgreen": 0x90ee90, "darkblue": 0x00008b, "darkgreen": 0x006400, "darkred": 0x8b0000,
        "crimson": 0xdc143c, "coral": 0xff7f50, "salmon": 0xfa8072, "tomato": 0xff6347, "khaki": 0xf0e68c,
        "skyblue": 0x87ceeb, "steelblue": 0x4682b4, "royalblue": 0x4169e1, "slategray": 0x708090,
        "slategrey": 0x708090, "orangered": 0xff4500, "turquoise": 0x40e0d0, "tan": 0xd2b48c,
        "beige": 0xf5f5dc, "ivory": 0xfffff0, "lavender": 0xe6e6fa, "wheat": 0xf5deb3, "plum": 0xdda0dd,
    ]
}

// MARK: - Geometry

enum Geometry {
    static func path(for n: SVGTree) -> CGPath? {
        func v(_ k: String) -> Double { Numbers.length(n.attrs[k]) }
        let p = CGMutablePath()
        switch n.name {
        case "path":
            guard let d = n.attrs["d"] else { return nil }
            return PathData.parse(d)
        case "rect":
            let w = v("width"), h = v("height")
            guard w > 0, h > 0 else { return nil }
            var rx = n.attrs["rx"].map { Numbers.length($0) }, ry = n.attrs["ry"].map { Numbers.length($0) }
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let r = CGRect(x: v("x"), y: v("y"), width: w, height: h)
            let cx = min(max(rx ?? 0, 0), w / 2), cy = min(max(ry ?? 0, 0), h / 2)
            if cx > 0, cy > 0 { p.addRoundedRect(in: r, cornerWidth: cx, cornerHeight: cy) } else { p.addRect(r) }
        case "circle":
            let r = v("r")
            guard r > 0 else { return nil }
            p.addEllipse(in: CGRect(x: v("cx") - r, y: v("cy") - r, width: 2 * r, height: 2 * r))
        case "ellipse":
            let rx = v("rx"), ry = v("ry")
            guard rx > 0, ry > 0 else { return nil }
            p.addEllipse(in: CGRect(x: v("cx") - rx, y: v("cy") - ry, width: 2 * rx, height: 2 * ry))
        case "line":
            p.move(to: CGPoint(x: v("x1"), y: v("y1")))
            p.addLine(to: CGPoint(x: v("x2"), y: v("y2")))
        case "polyline", "polygon":
            let nums = Numbers.list(n.attrs["points"] ?? "")
            guard nums.count >= 4 else { return nil }
            p.move(to: CGPoint(x: nums[0], y: nums[1]))
            for i in stride(from: 2, to: nums.count - 1, by: 2) { p.addLine(to: CGPoint(x: nums[i], y: nums[i + 1])) }
            if n.name == "polygon" { p.closeSubpath() }
        default:
            return nil
        }
        return p
    }
}

struct PathScanner {
    private let s: [UInt8]
    private(set) var position = 0
    init(_ str: String) { s = Array(str.utf8) }

    var atEnd: Bool { position >= s.count }
    var peek: UInt8? { position < s.count ? s[position] : nil }

    mutating func skipSeparators() {
        while position < s.count, s[position] == 0x20 || s[position] == 0x2c || s[position] == 0x0a
                || s[position] == 0x0d || s[position] == 0x09 { position += 1 }
    }

    mutating func number() -> Double? {
        skipSeparators()
        let start = position
        var i = position
        func digits() -> Bool {
            let b = i
            while i < s.count, s[i] >= 0x30, s[i] <= 0x39 { i += 1 }
            return i > b
        }
        if i < s.count, s[i] == 0x2b || s[i] == 0x2d { i += 1 }
        let whole = digits()
        var frac = false
        if i < s.count, s[i] == 0x2e { i += 1; frac = digits() }
        guard whole || frac else { return nil }
        if i < s.count, s[i] == 0x65 || s[i] == 0x45 {
            var j = i + 1
            if j < s.count, s[j] == 0x2b || s[j] == 0x2d { j += 1 }
            if j < s.count, s[j] >= 0x30, s[j] <= 0x39 {
                while j < s.count, s[j] >= 0x30, s[j] <= 0x39 { j += 1 }
                i = j
            }
        }
        position = i
        return Double(String(decoding: s[start..<i], as: UTF8.self))
    }

    /// An arc flag: a single `0` or `1`, which may be glued to what follows.
    mutating func flag() -> Bool? {
        skipSeparators()
        guard let c = peek, c == 0x30 || c == 0x31 else { return nil }
        position += 1
        return c == 0x31
    }

    mutating func command() -> Character? {
        skipSeparators()
        guard let c = peek, (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) else { return nil }
        position += 1
        return Character(UnicodeScalar(c))
    }
}

enum PathData {
    static func parse(_ d: String) -> CGPath {
        var sc = PathScanner(d)
        let path = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var cmd: Character = "M"
        var first = true

        func num() -> Double? { sc.number() }
        while !sc.atEnd {
            if let c = sc.command() { cmd = c } else if first { return path } // data must open with a command
            else if sc.peek == nil { break }
            first = false
            let rel = cmd.isLowercase
            var nextCubic: CGPoint?, nextQuad: CGPoint?
            func pt(_ x: Double, _ y: Double) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            switch cmd {
            case "M", "m":
                guard let x = num(), let y = num() else { return path }
                cur = pt(x, y); start = cur
                path.move(to: cur)
                cmd = rel ? "l" : "L" // further pairs are implicit line-tos
            case "L", "l":
                guard let x = num(), let y = num() else { return path }
                cur = pt(x, y); path.addLine(to: cur)
            case "H", "h":
                guard let x = num() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
            case "V", "v":
                guard let y = num() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
            case "C", "c":
                guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return path }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), e = pt(x, y)
                path.addCurve(to: e, control1: c1, control2: c2)
                nextCubic = c2; cur = e
            case "S", "s":
                guard let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return path }
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(x2, y2), e = pt(x, y)
                path.addCurve(to: e, control1: c1, control2: c2)
                nextCubic = c2; cur = e
            case "Q", "q":
                guard let x1 = num(), let y1 = num(), let x = num(), let y = num() else { return path }
                let c = pt(x1, y1), e = pt(x, y)
                path.addQuadCurve(to: e, control: c)
                nextQuad = c; cur = e
            case "T", "t":
                guard let x = num(), let y = num() else { return path }
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let e = pt(x, y)
                path.addQuadCurve(to: e, control: c)
                nextQuad = c; cur = e
            case "A", "a":
                guard let rx = num(), let ry = num(), let rot = num(), let large = sc.flag(), let sweep = sc.flag(),
                      let x = num(), let y = num() else { return path }
                let e = pt(x, y)
                addArc(to: path, from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, end: e)
                cur = e
            case "Z", "z":
                path.closeSubpath()
                cur = start
            default:
                return path
            }
            lastCubic = nextCubic; lastQuad = nextQuad
        }
        return path
    }

    /// SVG elliptical arc (spec F.6.5) as cubic Béziers of at most a quarter turn each.
    static func addArc(to path: CGMutablePath, from p0: CGPoint, rx: Double, ry: Double, rotation: Double,
                       large: Bool, sweep: Bool, end p1: CGPoint) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = (large == sweep ? -1.0 : 1.0) * sqrt(max(0, num / den))
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2
        let cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let n = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / Double(n)
        let t = 4.0 / 3.0 * tan(step / 4)
        func point(_ a: Double) -> CGPoint {
            CGPoint(x: cx + cp * rx * cos(a) - sp * ry * sin(a), y: cy + sp * rx * cos(a) + cp * ry * sin(a))
        }
        func deriv(_ a: Double) -> CGPoint {
            CGPoint(x: -cp * rx * sin(a) - sp * ry * cos(a), y: -sp * rx * sin(a) + cp * ry * cos(a))
        }
        for i in 0..<n {
            let a = theta1 + step * Double(i), b = a + step
            let pa = point(a), pb = i == n - 1 ? p1 : point(b), da = deriv(a), db = deriv(b)
            path.addCurve(to: pb, control1: CGPoint(x: pa.x + t * da.x, y: pa.y + t * da.y),
                          control2: CGPoint(x: pb.x - t * db.x, y: pb.y - t * db.y))
        }
    }
}
