import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Hiding part of a screenshot. The picture's own pixels are pixelated, not covered by something drawn on top,
/// so the original is gone from the file and from every export, SVG and web page included.
public enum Redaction {
    /// Pixelates the part of every picture under `rect` (in page coordinates) whose layer is in `layers`,
    /// following each picture's position, size and rotation. Returns the ids of the pictures changed.
    @discardableResult
    public static func pixelate(_ doc: inout DottieDocument, in rect: CGRect, layers: Set<UUID>) -> [UUID] {
        var changed: [UUID] = []
        for i in doc.elements.indices {
            let e = doc.elements[i]
            guard e.kind == .image, layers.contains(e.layerID), let picture = e.image, let img = picture.cgImage,
                  let region = pixelRegion(of: rect, in: e, width: img.width, height: img.height),
                  let out = pixelated(img, region: region, block: blockSize(for: region, pixelsPerPoint: Double(img.width) / max(e.width, 1))),
                  let data = ImageImport.encode(out, as: picture.format == "jpeg" ? .jpeg : .png) else { continue }
            doc.elements[i].image = EmbeddedImage(data: data, format: picture.format)
            changed.append(e.id)
        }
        return changed
    }

    /// The pixels of a `width` × `height` picture shown by `e` that `rect` covers, from the picture's top left;
    /// nil when it covers none. A rotated picture takes the box around the covered part.
    static func pixelRegion(of rect: CGRect, in e: Element, width: Int, height: Int) -> CGRect? {
        let f = e.frame
        guard f.width > 0, f.height > 0 else { return nil }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map { p -> CGPoint in
            let q = e.unrotated(p) // into the picture's unrotated frame, then into its pixels
            return CGPoint(x: (q.x - f.minX) / f.width * Double(width), y: (q.y - f.minY) / f.height * Double(height))
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        return box.isNull || box.width < 1 || box.height < 1 ? nil : box
    }

    /// The side of a pixelation block, in pixels: at least 10 points as the picture is shown, and half the
    /// region's short side, so a box around a line of text leaves it about two blocks tall. Coarse pixelation
    /// like this is hard to read back, but the real guarantee is that the original pixels are replaced.
    static func blockSize(for region: CGRect, pixelsPerPoint: Double) -> Int {
        max(Int((10 * pixelsPerPoint).rounded(.up)), Int(min(region.width, region.height) / 2), 1)
    }

    /// `img` with `region` (from the top left) replaced by blocks, each the average color of what it covers.
    static func pixelated(_ img: CGImage, region: CGRect, block: Int) -> CGImage? {
        let w = img.width, h = img.height
        // The picture's own color space (Display P3 for a modern screenshot), so the rest of it doesn't shift.
        let own = img.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let space = own ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The bitmap's rows run from the top, like `region`.
        let px = base.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h), stride = ctx.bytesPerRow
        let x0 = Int(region.minX), x1 = Int(region.maxX), y0 = Int(region.minY), y1 = Int(region.maxY)
        for by in Swift.stride(from: y0, to: y1, by: block) {
            for bx in Swift.stride(from: x0, to: x1, by: block) {
                let xs = bx..<min(bx + block, x1), ys = by..<min(by + block, y1)
                var sum = [0, 0, 0, 0]
                for y in ys { for x in xs { for c in 0..<4 { sum[c] += Int(px[y * stride + x * 4 + c]) } } }
                let n = xs.count * ys.count
                for y in ys { for x in xs { for c in 0..<4 { px[y * stride + x * 4 + c] = UInt8(sum[c] / n) } } }
            }
        }
        return ctx.makeImage()
    }
}
