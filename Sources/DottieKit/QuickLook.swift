import Foundation
import CoreGraphics

/// Rendering for the Quick Look extensions: a multi-page PDF for the preview, a fitted drawing for Finder
/// thumbnails, and a sheet of a stencil library's items so `.dottielib` files preview too.
extension Exporter {
    /// Every page of `file` as one PDF, one PDF page per Dottie page, each sized to its own drawing, with its links.
    public static func pdf(_ file: DottieFile) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
        let targets = linkTargets(in: file.pages)
        for page in file.pages {
            let doc = page.still
            let b = bounds(of: doc)
            var box = CGRect(origin: .zero, size: b.size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            draw(doc, in: ctx, size: b.size)
            // Links jump between pages, and web links open, as they do in the app.
            addLinkDestinations(page, bounds: b, targets: targets, in: ctx)
            addLinks(page, bounds: b, targets: targets, in: ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// The size of `doc`'s drawing scaled to fit inside `maxSize`, keeping its aspect ratio. Never upscales
    /// past 1:1 unless `allowUpscale`, so a tiny drawing doesn't turn into a blurry blown-up thumbnail.
    public static func fittedSize(of doc: DottieDocument, in maxSize: CGSize, allowUpscale: Bool = true) -> CGSize {
        let b = bounds(of: doc.still)
        guard b.width > 0, b.height > 0, maxSize.width > 0, maxSize.height > 0 else { return .zero }
        var s = min(maxSize.width / b.width, maxSize.height / b.height)
        if !allowUpscale { s = min(s, 1) }
        return CGSize(width: max(1, (b.width * s).rounded()), height: max(1, (b.height * s).rounded()))
    }

    /// Draws `doc` on its theme's page color (white without a theme), scaled to fill `size`, into a y-up
    /// context whose origin is the bottom-left corner of that area (a PDF page, a Quick Look thumbnail).
    public static func draw(_ doc: DottieDocument, in ctx: CGContext, size: CGSize) {
        let doc = doc.still
        let b = bounds(of: doc)
        guard b.width > 0, b.height > 0 else { return }
        let background = doc.resolvedTheme?.background.cgColor ?? CGColor(gray: 1, alpha: 1)
        let ink = doc.resolvedTheme?.ink ?? .black
        ctx.saveGState()
        ctx.setFillColor(background)
        ctx.fill(CGRect(origin: .zero, size: size))
        let s = min(size.width / b.width, size.height / b.height)
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        Renderer.draw(doc.resolvingInk(to: ink), in: ctx, background: background)
        ctx.restoreGState()
    }
}

extension StencilLibrary {
    /// Every item laid out in a grid on one page, each scaled into a `cell`-point square, for previews.
    public func sheet(columns: Int = 4, cell: Double = 120, gap: Double = 24) -> DottieDocument {
        var doc = DottieDocument(name: name)
        let layer = doc.layers[0].id
        let columns = max(1, columns)
        for (i, item) in items.enumerated() {
            let longest = max(item.width, item.height)
            let scale = longest > 0 ? cell / longest : 1
            let dx = Double(i % columns) * (cell + gap) + (cell - item.width * scale) / 2
            let dy = Double(i / columns) * (cell + gap) + (cell - item.height * scale) / 2
            for var e in item.placed(keepOriginalColors: false, scale: scale) {
                e.layerID = layer
                e.x += dx; e.y += dy
                if var c = e.connector {
                    c.translateFree(dx: dx, dy: dy)
                    e.connector = c
                }
                doc.elements.append(e)
            }
            doc.adoptSymbols(item.symbols ?? [])
        }
        return doc
    }
}
