import Foundation
import CoreGraphics
import CoreText

/// Single drawing path shared by the canvas, PNG and PDF export.
public enum Renderer {
    /// Outline path for an element. roughness == 0 gives exact geometry.
    public static func outline(for e: Element) -> CGPath {
        let r = e.frame
        var rng = SeededRNG(seed: e.seed)
        let rough = e.style.roughness
        switch e.kind {
        case .rectangle:
            if rough <= 0 { return CGPath(rect: r, transform: nil) }
            return Rough.polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                  CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)],
                                 rng: &rng, roughness: rough)
        case .diamond:
            let pts = [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                       CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
            if rough <= 0 {
                let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
            }
            return Rough.polygon(pts, rng: &rng, roughness: rough)
        case .ellipse:
            if rough <= 0 { return CGPath(ellipseIn: r, transform: nil) }
            return Rough.ellipse(in: r, rng: &rng, roughness: rough)
        case .text, .connector:
            return CGPath(rect: r, transform: nil)
        case .freehand:
            return freehandPath(for: e)
        }
    }

    /// A committed stroke is its fitted Bézier chain; one still being drawn (or from an older file)
    /// is smoothed through its raw points.
    static func freehandPath(for e: Element) -> CGPath {
        let r = e.frame
        if let flat = e.path, flat.count >= 8, (flat.count - 2) % 6 == 0 {
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: r.minX + flat[2 * i] * r.width, y: r.minY + flat[2 * i + 1] * r.height)
            }
            let path = CGMutablePath()
            path.move(to: pt(0))
            for s in 0..<((flat.count / 2 - 1) / 3) {
                path.addCurve(to: pt(3 * s + 3), control1: pt(3 * s + 1), control2: pt(3 * s + 2))
            }
            return path
        }
        let pts = (e.points ?? []).map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 { path.addLine(to: first); return path }
        if pts.count == 2 { path.addLine(to: pts[1]); return path }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// Stroked path for a connector, including arrowheads. Sketchy when roughness > 0.
    public static func connectorPath(for e: Element, in doc: DottieDocument) -> CGPath {
        guard let c = e.connector else { return CGMutablePath() }
        var rng = SeededRNG(seed: e.seed)
        let rough = e.style.roughness
        let path = CGMutablePath()
        let route = Connector.route(of: e, in: doc)

        switch route {
        case .polyline(let pts):
            for i in 0..<max(pts.count - 1, 0) {
                if rough <= 0 { path.move(to: pts[i]); path.addLine(to: pts[i + 1]) }
                else { Rough.line(pts[i], pts[i + 1], rng: &rng, roughness: rough, preserveEnds: true, into: path) }
            }
        case .cubic(let a, let b, let c2, let d):
            path.move(to: a)
            let w = rough * 3
            func j() -> CGFloat { CGFloat(rng.signed() * w) }
            path.addCurve(to: d, control1: CGPoint(x: b.x + j(), y: b.y + j()), control2: CGPoint(x: c2.x + j(), y: c2.y + j()))
        }

        let pts = route.points
        let size = max(10, e.style.strokeWidth * 5)
        func head(tip: CGPoint, from: CGPoint) {
            let (w1, w2) = Connector.arrowhead(tip: tip, from: from, size: size)
            if rough <= 0 {
                path.move(to: w1); path.addLine(to: tip); path.addLine(to: w2)
            } else {
                Rough.line(w1, tip, rng: &rng, roughness: rough * 0.5, into: path)
                Rough.line(w2, tip, rng: &rng, roughness: rough * 0.5, into: path)
            }
        }
        if c.endArrow, pts.count > 1 { head(tip: pts[pts.count - 1], from: pts[pts.count - 2]) }
        if c.startArrow, pts.count > 1 { head(tip: pts[0], from: pts[1]) }
        return path
    }

    /// Precise shape used for fills and hit areas.
    static func fillPath(for e: Element) -> CGPath {
        let r = e.frame
        switch e.kind {
        case .ellipse: return CGPath(ellipseIn: r, transform: nil)
        case .diamond:
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                                 CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)])
            p.closeSubpath(); return p
        default: return CGPath(rect: r, transform: nil)
        }
    }

    /// Draws with a top-left origin (y down). Callers must flip the context if needed.
    public static func draw(_ doc: DottieDocument, in ctx: CGContext) {
        let visible = Set(doc.layers.filter(\.visible).map(\.id))
        for e in doc.elements where visible.contains(e.layerID) {
            draw(e, in: ctx, document: doc)
        }
    }

    public static func draw(_ e: Element, in ctx: CGContext, document: DottieDocument? = nil) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        if e.kind == .connector {
            guard let document else { return }
            ctx.addPath(connectorPath(for: e, in: document))
            ctx.setStrokeColor(e.style.stroke.cgColor)
            ctx.setLineWidth(e.style.strokeWidth)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.strokePath()
            return
        }
        if e.kind == .text {
            drawText(e.text ?? "", in: e.frame, fontSize: e.style.fontSize, color: e.style.stroke.cgColor, ctx: ctx)
            return
        }
        if e.style.fill.a > 0, e.kind != .freehand {
            ctx.addPath(fillPath(for: e))
            ctx.setFillColor(e.style.fill.cgColor)
            ctx.fillPath()
        }
        ctx.addPath(outline(for: e))
        ctx.setStrokeColor(e.style.stroke.cgColor)
        ctx.setLineWidth(e.style.strokeWidth)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.strokePath()
        if let t = e.text, !t.isEmpty {
            drawText(t, in: e.frame.insetBy(dx: 6, dy: 6), fontSize: e.style.fontSize, color: e.style.stroke.cgColor, ctx: ctx, centered: true)
        }
    }

    static func drawText(_ s: String, in rect: CGRect, fontSize: Double, color: CGColor, ctx: CGContext, centered: Bool = false) {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
        var align: CTTextAlignment = centered ? .center : .left
        let para = withUnsafeBytes(of: &align) { buf -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: buf.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color, kCTParagraphStyleAttributeName: para]
        let str = CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary)!
        let setter = CTFramesetterCreateWithAttributedString(str)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        let y = centered ? rect.midY - size.height / 2 : rect.minY
        let box = CGRect(x: rect.minX, y: y, width: rect.width, height: size.height)
        // CoreText draws y-up; flip locally within the top-left-origin context.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: box.minY + box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: box, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
