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
        case .text:
            return CGPath(rect: r, transform: nil)
        }
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
            draw(e, in: ctx)
        }
    }

    public static func draw(_ e: Element, in ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        if e.kind == .text {
            drawText(e.text ?? "", in: e.frame, fontSize: e.style.fontSize, color: e.style.stroke.cgColor, ctx: ctx)
            return
        }
        if e.style.fill.a > 0 {
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
