import Foundation
import CoreGraphics

extension Exporter {
    /// SVG built from the same paths the renderer draws, so the sketchy look is identical.
    /// Automatic ink is exported as black. Pass `background: nil` for a transparent page.
    public static func svg(_ doc: DottieDocument, background: RGBA? = RGBA(r: 1, g: 1, b: 1)) -> String {
        let d = doc.resolvingInk(to: .black)
        let b = bounds(of: d)
        let visible = Set(d.layers.filter(\.visible).map(\.id))
        var out = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(num(b.width))" height="\(num(b.height))" \
        viewBox="\(num(b.minX)) \(num(b.minY)) \(num(b.width)) \(num(b.height))">

        """
        if let background {
            out += "<rect x=\"\(num(b.minX))\" y=\"\(num(b.minY))\" width=\"\(num(b.width))\" height=\"\(num(b.height))\" fill=\"\(color(background))\"/>\n"
        }
        let index = d.elementIndex
        for e in d.orderedElements where visible.contains(e.layerID) {
            let body = svgElement(e, in: d, index: index, labelBackground: background)
            if e.angle != 0, e.kind != .connector {
                out += "<g transform=\"rotate(\(num(e.angle * 180 / .pi)) \(num(e.frame.midX)) \(num(e.frame.midY)))\">\n\(body)</g>\n"
            } else {
                out += body
            }
        }
        return out + "</svg>\n"
    }

    private static func svgElement(_ e: Element, in doc: DottieDocument, index: [UUID: Element], labelBackground: RGBA?) -> String {
        let stroke = color(e.style.stroke)
        var strokeAttrs = "stroke=\"\(stroke)\" stroke-width=\"\(num(e.style.strokeWidth))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
        if let d = Renderer.dashPattern(e.style.dash, width: e.style.strokeWidth) {
            strokeAttrs += " stroke-dasharray=\"\(d.map { num($0) }.joined(separator: " "))\""
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
        case .freehand:
            return "<path d=\"\(pathData(Renderer.outline(for: e)))\" fill=\"none\" \(strokeAttrs)/>\n"
        case .rectangle, .ellipse, .diamond, .path:
            var s = ""
            if e.style.fill.a > 0 {
                if e.style.fillStyle == .solid {
                    s += "<path d=\"\(pathData(Renderer.fillPath(for: e)))\" fill=\"\(color(e.style.fill))\"\(opacity(e.style.fill, attr: "fill-opacity")) stroke=\"none\"/>\n"
                } else {
                    s += "<path d=\"\(pathData(Renderer.hachurePath(for: e)))\" fill=\"none\" stroke=\"\(color(e.style.fill))\"\(opacity(e.style.fill, attr: "stroke-opacity")) stroke-width=\"\(num(max(1, e.style.strokeWidth / 2)))\" stroke-linecap=\"round\"/>\n"
                }
            }
            s += "<path d=\"\(pathData(Renderer.outline(for: e)))\" fill=\"none\" \(strokeAttrs)/>\n"
            if let t = e.text, !t.isEmpty { s += textElement(t, frame: e.frame, e: e, centered: true) }
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
