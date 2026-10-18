import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum Exporter {
    public static func bounds(of doc: DottieDocument, padding: Double = 24) -> CGRect {
        if doc.hasInstances { return bounds(of: doc.expandingSymbols(at: 0), padding: padding) }
        let index = doc.elementIndex
        func frame(_ e: Element) -> CGRect {
            if e.kind == .connector { return Connector.bounds(of: e, in: doc, index: index) }
            // A floor's rock hatching reaches past its shape.
            let reach = DungeonGrid.isFloor(e) ? (DungeonGrid.band + 0.25) * e.style.cellSize : 0
            return e.rotatedBounds.insetBy(dx: -reach, dy: -reach)
        }
        // Fully transparent elements (an entrance about to fade up) take no room, unless nothing else is there.
        let shown = doc.elements.filter { ($0.style.opacity ?? 1) > 0 }
        let counted = shown.isEmpty ? doc.elements : shown
        guard var r = counted.first.map(frame) else { return CGRect(x: 0, y: 0, width: 200, height: 200) }
        for e in counted { r = r.union(frame(e)) }
        return r.insetBy(dx: -padding, dy: -padding)
    }

    public static func png(_ doc: DottieDocument, scale: Double = 2, background: CGColor? = CGColor(gray: 1, alpha: 1)) -> Data? {
        guard let img = bitmap(doc, bounds: bounds(of: doc), scale: scale, background: background) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The page's timeline as a looping animated GIF, every frame framed to the whole animation.
    /// A page without a timeline is a one-frame GIF.
    /// nil when the animation is too long to export (see `maxAnimationFrames`).
    public static func gif(_ doc: DottieDocument, scale: Double = 1) -> Data? {
        guard let plan = animation(doc) else { return nil }
        let size = (width: max(1, Int((plan.size.width * scale).rounded())), height: max(1, Int((plan.size.height * scale).rounded())))
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, plan.times.count, nil)
        else { return nil }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        for (i, t) in plan.times.enumerated() {
            guard let img = bitmap(doc.resolved(at: t), bounds: plan.rects[i], scale: scale,
                                   background: CGColor(gray: 1, alpha: 1), pixels: size) else { return nil }
            let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: plan.durations[i]]]
            CGImageDestinationAddImage(dest, img, delay as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The page's timeline as a looping animated PNG: the GIF's frames in full color, with alpha. Pass
    /// `background: nil` for a transparent page (a themed drawing keeps its page color otherwise).
    /// nil when the animation is too long to export (see `maxAnimationFrames`).
    public static func apng(_ doc: DottieDocument, scale: Double = 1, background: CGColor? = CGColor(gray: 1, alpha: 1)) -> Data? {
        guard let plan = animation(doc) else { return nil }
        let size = (width: max(1, Int((plan.size.width * scale).rounded())), height: max(1, Int((plan.size.height * scale).rounded())))
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, plan.times.count, nil)
        else { return nil }
        let loop = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        for (i, t) in plan.times.enumerated() {
            guard let img = bitmap(doc.resolved(at: t), bounds: plan.rects[i], scale: scale, background: background, pixels: size)
            else { return nil }
            let delay = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: plan.durations[i]]]
            CGImageDestinationAddImage(dest, img, delay as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// `doc` drawn into a bitmap covering `b`.
    /// `pixels` fixes the bitmap's size (an animation's frames must all match), scaling `b` to fill it.
    static func bitmap(_ doc: DottieDocument, bounds b: CGRect, scale: Double, background: CGColor?,
                       pixels: (width: Int, height: Int)? = nil) -> CGImage? {
        // A themed drawing exports on its own page color, unless the caller asked for transparency.
        let background = background.map { plain in doc.resolvedTheme?.background.cgColor ?? plain }
        let ink = doc.resolvedTheme?.ink ?? .black
        let w = pixels?.width ?? Int(b.width * scale), h = pixels?.height ?? Int(b.height * scale)
        let scale = pixels.map { Double($0.width) / max(b.width, 1) } ?? scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background { ctx.setFillColor(background); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        // Flip to top-left origin, then map document bounds to the bitmap.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        Renderer.draw(doc.resolvingInk(to: ink), in: ctx, background: background)
        return ctx.makeImage()
    }

    public static func pdf(_ doc: DottieDocument) -> Data? {
        let b = bounds(of: doc)
        let background = doc.resolvedTheme?.background.cgColor ?? CGColor(gray: 1, alpha: 1)
        let ink = doc.resolvedTheme?.ink ?? .black
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var box = CGRect(origin: .zero, size: b.size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: b.height); ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        ctx.setFillColor(background); ctx.fill(b)
        Renderer.draw(doc.resolvingInk(to: ink), in: ctx, background: background)
        let targets = linkTargets(in: [doc])
        addLinkDestinations(doc, bounds: b, targets: targets, in: ctx)
        addLinks(doc, bounds: b, targets: targets, in: ctx)
        ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    /// A self-contained web page: the SVG inline on the drawing's page color, scaling to the window.
    public static func html(_ doc: DottieDocument, title: String = "Dottie drawing",
                            background: RGBA? = RGBA(r: 1, g: 1, b: 1)) -> String {
        let page = background.map { plain in doc.resolvedTheme?.background ?? plain }
        func hex(_ c: RGBA) -> String {
            func h(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
            return "#\(h(c.r))\(h(c.g))\(h(c.b))"
        }
        let bg = page.map { "background:\(hex($0));" } ?? ""
        let safeTitle = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safeTitle)</title>
        <style>
        html, body { margin: 0; min-height: 100%; \(bg) }
        body { display: flex; align-items: center; justify-content: center; }
        svg { max-width: 100%; height: auto; display: block; }
        </style>
        </head>
        <body>
        \(svg(doc, background: nil))</body>
        </html>

        """
    }
}
