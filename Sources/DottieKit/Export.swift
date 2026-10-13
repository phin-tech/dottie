import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum Exporter {
    public static func bounds(of doc: DottieDocument, padding: Double = 24) -> CGRect {
        func frame(_ e: Element) -> CGRect { e.kind == .connector ? Connector.bounds(of: e, in: doc) : e.frame }
        guard var r = doc.elements.first.map(frame) else { return CGRect(x: 0, y: 0, width: 200, height: 200) }
        for e in doc.elements { r = r.union(frame(e)) }
        return r.insetBy(dx: -padding, dy: -padding)
    }

    public static func png(_ doc: DottieDocument, scale: Double = 2, background: CGColor? = CGColor(gray: 1, alpha: 1)) -> Data? {
        let b = bounds(of: doc)
        let w = Int(b.width * scale), h = Int(b.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background { ctx.setFillColor(background); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        // Flip to top-left origin, then map document bounds to the bitmap.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        Renderer.draw(doc.resolvingInk(to: .black), in: ctx)
        guard let img = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    public static func pdf(_ doc: DottieDocument) -> Data? {
        let b = bounds(of: doc)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var box = CGRect(origin: .zero, size: b.size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: b.height); ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        Renderer.draw(doc.resolvingInk(to: .black), in: ctx)
        ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }
}
