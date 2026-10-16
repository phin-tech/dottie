import Foundation
import CoreGraphics
import CoreText

extension Exporter {
    /// SVG built from the same paths the renderer draws, so the sketchy look is identical.
    /// Automatic ink is exported as black. Pass `background: nil` for a transparent page.
    public static func svg(_ doc: DottieDocument, background: RGBA? = RGBA(r: 1, g: 1, b: 1)) -> String {
        svg(doc, background: background, bounds: nil)
    }

    /// `bounds` fixes the viewBox, so every frame of an animation lines up.
    static func svg(_ doc: DottieDocument, background: RGBA?, bounds fixed: CGRect?) -> String {
        let (b, parts) = svgParts(doc, background: background, bounds: fixed)
        return svgOpen(b, background: doc.resolvedTheme?.background ?? background.map { $0 }, paint: background != nil)
            + parts.map(\.markup).joined() + "</svg>\n"
    }

    /// The opening `<svg>` tag for `b`, with the page color behind everything when `paint`.
    static func svgOpen(_ b: CGRect, background: RGBA?, paint: Bool) -> String {
        var out = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(num(b.width))" height="\(num(b.height))" \
        viewBox="\(num(b.minX)) \(num(b.minY)) \(num(b.width)) \(num(b.height))">

        """
        if paint, let background {
            out += "<rect x=\"\(num(b.minX))\" y=\"\(num(b.minY))\" width=\"\(num(b.width))\" height=\"\(num(b.height))\" fill=\"\(color(background))\"/>\n"
        }
        return out
    }

    /// The SVG for each thing drawn, back to front, keyed by element id (dungeon rock hatching as "rock"),
    /// and the bounds they were drawn for. Joined, they are the body of `svg(_:background:bounds:)`; kept
    /// apart, an animation export can store what doesn't change between frames once.
    static func svgParts(_ doc: DottieDocument, background: RGBA?, bounds fixed: CGRect?) -> (CGRect, [(key: String, markup: String)]) {
        let theme = doc.resolvedTheme
        let background = background.map { plain in theme?.background ?? plain }
        let d = doc.resolvingInk(to: theme?.ink ?? .black)
        let b = fixed ?? bounds(of: d)
        let visible = Set(d.layers.filter(\.visible).map(\.id))
        var parts: [(key: String, markup: String)] = []
        let index = d.elementIndex
        let floors = d.orderedElements.filter { visible.contains($0.layerID) && DungeonGrid.isFloor($0) }
        let rock = DungeonGrid.rock(for: floors).map { rock in
            "<path d=\"\(pathData(rock.path))\" fill=\"none\" stroke=\"\(color(rock.ink))\"\(opacity(rock.ink, attr: "stroke-opacity")) stroke-width=\"\(num(rock.width))\" stroke-linecap=\"round\"/>\n"
        }.joined()
        if !rock.isEmpty { parts.append(("rock", rock)) }
        for e in d.orderedElements where visible.contains(e.layerID) {
            let alpha = min(max(e.style.opacity ?? 1, 0), 1)
            if alpha <= 0 { continue }
            var body = svgElement(e, in: d, index: index, labelBackground: background)
            if e.angle != 0, e.kind != .connector {
                body = "<g transform=\"rotate(\(num(e.angle * 180 / .pi)) \(num(e.frame.midX)) \(num(e.frame.midY)))\">\n\(body)</g>\n"
            }
            parts.append((e.id.uuidString, alpha < 1 ? "<g opacity=\"\(num(alpha))\">\n\(body)</g>\n" : body))
        }
        return (b, parts)
    }

    private static func svgElement(_ e: Element, in doc: DottieDocument, index: [UUID: Element], labelBackground: RGBA?) -> String {
        let stroke = color(e.style.stroke)
        var strokeAttrs = "stroke=\"\(stroke)\" stroke-width=\"\(num(e.style.strokeWidth))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
        if let d = Renderer.dashPattern(e.style.dash, width: e.style.strokeWidth) {
            strokeAttrs += " stroke-dasharray=\"\(d.map { num($0) }.joined(separator: " "))\""
            if let o = e.style.dashOffset, num(o) != "0" { strokeAttrs += " stroke-dashoffset=\"\(num(o))\"" }
        }
        var e = e
        if let r = e.revealProgress { // drawing on: a partial stroke, as Renderer.draw does
            switch e.kind {
            case .text: e.text = e.typed(e.text ?? "", r)
            case .connector:
                let line = Renderer.connectorParts(for: e, in: doc, index: index).line.trimmed(to: r)
                return "<path d=\"\(pathData(line))\" fill=\"none\" \(strokeAttrs)/>\n"
            default:
                return "<path d=\"\(pathData(Renderer.outline(for: e).trimmed(to: r)))\" fill=\"none\" \(strokeAttrs)/>\n"
            }
        }
        switch e.kind {
        case .connector:
            let (line, filled) = Renderer.connectorParts(for: e, in: doc, index: index)
            var s = "<path d=\"\(pathData(line))\" fill=\"none\" \(strokeAttrs)/>\n"
            if !filled.isEmpty {
                s += "<path d=\"\(pathData(filled))\" fill=\"\(stroke)\" stroke=\"none\"/>\n"
            }
            if let t = e.text, !t.isEmpty {
                let r = Renderer.labelRect(for: e, in: doc, index: index)
                if let bg = labelBackground {
                    s += "<rect x=\"\(num(r.minX))\" y=\"\(num(r.minY))\" width=\"\(num(r.width))\" height=\"\(num(r.height))\" fill=\"\(color(bg))\"/>\n"
                }
                s += textElement(t, frame: r, e: e, centered: true)
            }
            return s
        case .text:
            return textElement(e.text ?? "", frame: e.frame, e: e, centered: false)
        case .image:
            let r = e.frame
            var s = ""
            if let img = e.image {
                s += "<image x=\"\(num(r.minX))\" y=\"\(num(r.minY))\" width=\"\(num(r.width))\" height=\"\(num(r.height))\" preserveAspectRatio=\"none\" href=\"data:\(img.mimeType);base64,\(img.data.base64EncodedString())\"/>\n"
            }
            if e.style.stroke.a > 0, e.style.strokeWidth > 0 {
                s += "<path d=\"\(pathData(Renderer.outline(for: e)))\" fill=\"none\" \(strokeAttrs)/>\n"
            }
            return s
        case .freehand:
            return "<path d=\"\(pathData(Renderer.outline(for: e)))\" fill=\"none\" \(strokeAttrs)/>\n"
        case .rectangle, .ellipse, .diamond, .path, .note:
            var s = ""
            if e.kind == .note, e.style.fill.a > 0 {
                let shadow = Renderer.fillPath(for: e).copy(using: [CGAffineTransform(translationX: Note.shadowOffset.width, y: Note.shadowOffset.height)])!
                s += "<path d=\"\(pathData(shadow))\" fill=\"#000000\" fill-opacity=\"\(num(0.14 * e.style.fill.a))\" stroke=\"none\"/>\n"
            }
            if e.style.fill.a > 0 {
                if e.style.fillStyle == .solid {
                    s += "<path d=\"\(pathData(Renderer.fillPath(for: e)))\" fill=\"\(color(e.style.fill))\"\(opacity(e.style.fill, attr: "fill-opacity"))\(e.evenOdd == true ? " fill-rule=\"evenodd\"" : "") stroke=\"none\"/>\n"
                } else if e.style.fillStyle == .grid {
                    let line = DungeonGrid.lineColor(for: e.style.fill)
                    s += "<path d=\"\(pathData(Renderer.fillPath(for: e)))\" fill=\"\(color(e.style.fill))\"\(opacity(e.style.fill, attr: "fill-opacity"))\(e.evenOdd == true ? " fill-rule=\"evenodd\"" : "") stroke=\"none\"/>\n"
                    s += "<path d=\"\(pathData(Renderer.hachurePath(for: e)))\" fill=\"none\" stroke=\"\(color(line))\"\(opacity(line, attr: "stroke-opacity")) stroke-width=\"1\" stroke-linecap=\"round\"/>\n"
                } else {
                    s += "<path d=\"\(pathData(Renderer.hachurePath(for: e)))\" fill=\"none\" stroke=\"\(color(e.style.fill))\"\(opacity(e.style.fill, attr: "stroke-opacity")) stroke-width=\"\(num(max(1, e.style.strokeWidth / 2)))\" stroke-linecap=\"round\"/>\n"
                }
            }
            s += "<path d=\"\(pathData(Renderer.outline(for: e)))\" fill=\"none\" \(strokeAttrs)/>\n"
            if let t = e.text, !t.isEmpty {
                s += e.kind == .note ? noteText(t, e: e) : textElement(t, frame: e.frame, e: e, centered: true)
            }
            return s
        }
    }

    private static func textElement(_ text: String, frame: CGRect, e: Element, centered: Bool) -> String {
        let size = e.style.fontSize
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lineHeight = size * 1.2
        let total = lineHeight * Double(lines.count)
        let x = centered ? frame.midX : frame.minX
        let top = centered ? frame.midY - total / 2 : frame.minY
        var s = "<text x=\"\(num(x))\" font-family=\"Helvetica Neue, Helvetica, Arial, sans-serif\" font-size=\"\(num(size))\" fill=\"\(color(e.style.stroke))\"\(centered ? " text-anchor=\"middle\"" : "")>"
        for (i, line) in lines.enumerated() {
            s += "<tspan x=\"\(num(x))\" y=\"\(num(top + lineHeight * (Double(i) + 0.8)))\">\(escape(line))</tspan>"
        }
        return s + "</text>\n"
    }

    /// A note's Markdown as positioned runs: the same CoreText layout the renderer draws, one `<text>` per
    /// line and a `<tspan>` per style run, so the SVG wraps exactly where the PNG does.
    private static func noteText(_ source: String, e: Element) -> String {
        let rect = Note.textRect(e.frame)
        let (text, frame) = Note.layout(source, in: rect, fontSize: e.style.fontSize, color: e.style.stroke.cgColor)
        let lines = Note.lines(of: frame, in: rect)
        let string = text.string as NSString
        var s = ""
        for l in lines {
            var spans = ""
            for run in CTLineGetGlyphRuns(l.line) as! [CTRun] {
                let range = CTRunGetStringRange(run)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = attrs[kCTFontAttributeName as String] as! CTFont
                let traits = CTFontGetSymbolicTraits(font)
                var a = "font-size=\"\(num(Double(CTFontGetSize(font))))\""
                if traits.contains(.traitMonoSpace) { a += " font-family=\"Menlo, Consolas, monospace\"" }
                if traits.contains(.traitBold) { a += " font-weight=\"bold\"" }
                if traits.contains(.traitItalic) { a += " font-style=\"italic\"" }
                if attrs[kCTUnderlineStyleAttributeName as String] != nil { a += " text-decoration=\"underline\"" }
                if let c = attrs[kCTForegroundColorAttributeName as String], CFGetTypeID(c as CFTypeRef) == CGColor.typeID,
                   (c as! CGColor).alpha < 1 {
                    a += " fill-opacity=\"\(num(Double((c as! CGColor).alpha)))\""
                }
                // A run can span tabs (a list marker, or table cells in the same style): each piece between
                // them gets its own x, where CoreText put it.
                var start = range.location
                for piece in string.substring(with: NSRange(location: range.location, length: range.length)).components(separatedBy: "\t") {
                    let length = (piece as NSString).length
                    defer { start += length + 1 }
                    let shown = piece.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: Note.lineSeparator, with: "")
                    guard !shown.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    let x = l.origin.x + CTLineGetOffsetForStringIndex(l.line, start, nil)
                    spans += "<tspan x=\"\(num(x))\" \(a)>\(escape(shown))</tspan>"
                }
            }
            guard !spans.isEmpty else { continue }
            s += "<text y=\"\(num(l.origin.y))\" font-family=\"Helvetica Neue, Helvetica, Arial, sans-serif\" fill=\"\(color(e.style.stroke))\" xml:space=\"preserve\">\(spans)</text>\n"
        }
        for (a, b) in Note.decorations(lines, in: rect) {
            s += "<line x1=\"\(num(a.x))\" y1=\"\(num(a.y))\" x2=\"\(num(b.x))\" y2=\"\(num(b.y))\" stroke=\"\(color(e.style.stroke))\" stroke-width=\"\(num(max(1, e.style.fontSize / 14)))\"/>\n"
        }
        return s
    }

    static func pathData(_ path: CGPath) -> String {
        var d: [String] = []
        path.applyWithBlock { el in
            let p = el.pointee.points
            switch el.pointee.type {
            case .moveToPoint: d.append("M\(num(p[0].x)) \(num(p[0].y))")
            case .addLineToPoint: d.append("L\(num(p[0].x)) \(num(p[0].y))")
            case .addQuadCurveToPoint: d.append("Q\(num(p[0].x)) \(num(p[0].y)) \(num(p[1].x)) \(num(p[1].y))")
            case .addCurveToPoint:
                d.append("C\(num(p[0].x)) \(num(p[0].y)) \(num(p[1].x)) \(num(p[1].y)) \(num(p[2].x)) \(num(p[2].y))")
            case .closeSubpath: d.append("Z")
            @unknown default: break
            }
        }
        return d.joined(separator: " ")
    }

    private static func num(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
    private static func num(_ v: CGFloat) -> String { num(Double(v)) }

    private static func color(_ c: RGBA) -> String {
        func h(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#\(h(c.r))\(h(c.g))\(h(c.b))"
    }
    private static func opacity(_ c: RGBA, attr: String) -> String { c.a < 1 ? " \(attr)=\"\(num(c.a))\"" : "" }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
