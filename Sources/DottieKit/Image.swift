import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// The picture inside an `.image` element: PNG or JPEG bytes, stored in the file as base64 so a drawing
/// stays one self-contained file. Imports are normalized (`ImageImport`) so every export, SVG included,
/// can use the bytes as they are.
public struct EmbeddedImage: Codable, Equatable, Sendable {
    public var data: Data
    /// "png" or "jpeg".
    public var format: String
    /// SHA-256 of `data`, for caching decoded images. Worked out on load, never saved, so a hand-edited file
    /// cannot carry a hash that disagrees with its bytes.
    public let digest: String

    public init(data: Data, format: String) {
        self.data = data
        self.format = format
        self.digest = Self.hash(data)
    }

    private enum CodingKeys: String, CodingKey { case data, format }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let data = try c.decode(Data.self, forKey: .data)
        self.init(data: data, format: try c.decodeIfPresent(String.self, forKey: .format) ?? "png")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(data, forKey: .data)
        try c.encode(format, forKey: .format)
    }

    public static func == (a: EmbeddedImage, b: EmbeddedImage) -> Bool { a.digest == b.digest }

    public var mimeType: String { format == "jpeg" ? "image/jpeg" : "image/png" }

    /// The decoded picture, cached by digest.
    public var cgImage: CGImage? { ImageCache.shared.image(for: self) }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private let limit = 64

    func image(for e: EmbeddedImage) -> CGImage? {
        lock.lock()
        if let img = images[e.digest] { lock.unlock(); return img }
        lock.unlock()
        guard let src = CGImageSourceCreateWithData(e.data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if images.count >= limit { images.removeAll(keepingCapacity: true) }
        images[e.digest] = img
        return img
    }
}

/// Turns whatever image the user or an agent hands over (PNG, JPEG, HEIC, TIFF, GIF, a phone photo with an
/// EXIF rotation) into an `EmbeddedImage` and the size, in points, to place it at.
public enum ImageImport {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable
        public var description: String { "Not an image Dottie can read" }
    }

    /// Longest side kept, in pixels. Bigger pictures are scaled down so drawings stay a sensible size.
    public static let maxPixels = 2048

    public static func normalize(_ data: Data) throws -> (image: EmbeddedImage, size: CGSize) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            throw Failure.unreadable
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        // Applying the EXIF orientation and capping the size in one pass; the result is always a fresh bitmap.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw Failure.unreadable }

        // Points, not pixels: a Retina screenshot (144 dpi) lands at the size it looked on screen.
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let fullW = Double(props[kCGImagePropertyPixelWidth] as? Int ?? img.width)
        let fullH = Double(props[kCGImagePropertyPixelHeight] as? Int ?? img.height)
        let rotated = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5 // orientations 5...8 swap the axes
        let (pw, ph) = rotated ? (fullH, fullW) : (fullW, fullH)
        var size = CGSize(width: pw * 72 / dpi, height: ph * 72 / dpi)
        let longest = max(size.width, size.height)
        if longest > 640 { size = CGSize(width: size.width * 640 / longest, height: size.height * 640 / longest) }

        // Photos without transparency are much smaller as JPEG; everything else stays PNG.
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(img.alphaInfo)
        let wasJPEG = (CGImageSourceGetType(src) as String?) == UTType.jpeg.identifier
        let jpeg = opaque && (wasJPEG || img.width * img.height > 1_000_000)
        guard let out = encode(img, as: jpeg ? .jpeg : .png) else { throw Failure.unreadable }
        return (EmbeddedImage(data: out, format: jpeg ? "jpeg" : "png"), size)
    }

    static func encode(_ img: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

extension DiagramOps {
    /// Places a picture with its top-left corner at `origin`. Without a `width` or `height` it keeps its own
    /// size (capped at 640 points); with one of them the other follows the aspect ratio.
    @discardableResult
    public static func addImage(_ doc: inout DottieDocument, data: Data, at origin: CGPoint,
                                width: Double? = nil, height: Double? = nil) throws -> Element {
        let (image, natural) = try ImageImport.normalize(data)
        let aspect = natural.height > 0 ? natural.width / natural.height : 1
        var size = natural
        switch (width, height) {
        case let (w?, h?): size = CGSize(width: max(1, w), height: max(1, h))
        case let (w?, nil): size = CGSize(width: max(1, w), height: max(1, w / aspect))
        case let (nil, h?): size = CGSize(width: max(1, h * aspect), height: max(1, h))
        case (nil, nil): break
        }
        var e = Element.image(image, frame: CGRect(origin: origin, size: size), layerID: doc.firstOpenLayerID)
        e.style.roughness = Style().roughness
        doc.elements.append(e)
        return e
    }
}

extension Element {
    /// A new `.image` element: no border until the user picks a stroke color.
    public static func image(_ image: EmbeddedImage, frame: CGRect, layerID: UUID) -> Element {
        var style = Style()
        style.stroke = .clear
        var e = Element(kind: .image, frame: frame, style: style, layerID: layerID)
        e.image = image
        return e
    }
}

extension DottieDocument {
    /// The first visible, unlocked layer, adding one if every layer is locked.
    var firstOpenLayerID: UUID {
        mutating get {
            if let l = layers.first(where: { !$0.locked && $0.visible }) ?? layers.first(where: { !$0.locked }) { return l.id }
            let l = Layer(name: "Layer \(layers.count + 1)")
            layers.append(l)
            return l.id
        }
    }
}
