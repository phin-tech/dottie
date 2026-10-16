import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum Exporter {
    public static func bounds(of doc: DottieDocument, padding: Double = 24) -> CGRect {
        let index = doc.elementIndex
        func frame(_ e: Element) -> CGRect {
            if e.kind == .connector { return Connector.bounds(of: e, in: doc, index: index) }
            // A floor's rock hatching reaches past its shape.
            let reach = DungeonGrid.isFloor(e) ? (DungeonGrid.band + 0.25) * e.style.cellSize : 0
            return e.rotatedBounds.insetBy(dx: -reach, dy: -reach)
        }
        guard var r = doc.elements.first.map(frame) else { return CGRect(x: 0, y: 0, width: 200, height: 200) }
        for e in doc.elements { r = r.union(frame(e)) }
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
    public static func gif(_ doc: DottieDocument, scale: Double = 1) -> Data? {
        let (timeline, frames, b) = animation(doc)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil)
        else { return nil }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / timeline.fps]]
        for f in frames {
            guard let img = bitmap(f, bounds: b, scale: scale, background: CGColor(gray: 1, alpha: 1)) else { return nil }
            CGImageDestinationAddImage(dest, img, delay as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// `doc` drawn into a bitmap covering `b`.
    static func bitmap(_ doc: DottieDocument, bounds b: CGRect, scale: Double, background: CGColor?) -> CGImage? {
        // A themed drawing exports on its own page color, unless the caller asked for transparency.
        let background = background.map { plain in doc.resolvedTheme?.background.cgColor ?? plain }
        let ink = doc.resolvedTheme?.ink ?? .black
        let w = Int(b.width * scale), h = Int(b.height * scale)
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
