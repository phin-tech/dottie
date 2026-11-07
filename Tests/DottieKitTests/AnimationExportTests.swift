import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import DottieKit

final class AnimationExportTests: XCTestCase {
    private func animated() throws -> DottieDocument {
        var doc = DottieDocument()
        let a = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 81, height: 41), at: .zero,
                                        text: "A", fill: nil, stroke: nil, roughness: 1)
        var tl = Timeline(fps: 10, duration: 1)
        tl.setKey(Keyframe(t: 0, x: 0), for: a.id)
        tl.setKey(Keyframe(t: 1, x: 300), for: a.id)
        doc.timeline = tl
        return doc
    }

    func testAPNGRoundTripsWithItsFramesDelaysAndAlpha() throws {
        let doc = try animated()
        let data = try XCTUnwrap(Exporter.apng(doc, scale: 1, background: nil))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.png.identifier)
        XCTAssertEqual(CGImageSourceGetCount(src), 11, "ten frames, then the end pose itself")
        let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        XCTAssertEqual(png?[kCGImagePropertyAPNGLoopCount] as? Int, 0, "loops forever")
        for i in 0..<CGImageSourceGetCount(src) {
            let frame = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let delay = (frame?[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyAPNGDelayTime] as? Double
            XCTAssertEqual(delay ?? 0, 0.1, accuracy: 0.005, "frame \(i)")
        }
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertGreaterThan(first.width, 300, "framed to the whole motion")
        XCTAssertTrue([.premultipliedLast, .last, .premultipliedFirst, .first].contains(first.alphaInfo), "keeps alpha")
        // A transparent corner, and an opaque one when there's a background.
        func corner(_ img: CGImage) -> UInt8 {
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 1 - img.height, width: img.width, height: img.height))
            return ctx.data!.load(fromByteOffset: 3, as: UInt8.self)
        }
        XCTAssertEqual(corner(first), 0)
        let opaque = try XCTUnwrap(Exporter.apng(doc, scale: 1))
        XCTAssertEqual(corner(try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(opaque as CFData, nil)!, 0, nil))), 255)
    }

    func testMP4HasEvenSizeAndTheTimelinesLength() async throws {
        let data = try XCTUnwrap(Exporter.mp4(try animated(), scale: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.1, accuracy: 0.05, "ten frames, then the end pose for one more")
        let track = try await XCTUnwrapAsync(await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
        XCTAssertGreaterThan(size.width, 300, "framed to the whole motion")
    }

    func testThePlayerIsDottieJSAndDoesntGrowWithTheAnimation() throws {
        let doc = try animated()
        let html = try XCTUnwrap(Exporter.player(doc, title: "<demo>"))
        XCTAssertTrue(html.contains("<title>&lt;demo&gt;</title>"))
        XCTAssertTrue(html.contains("dottie-player"))
        XCTAssertTrue(html.contains(doc.elements[0].id.uuidString), "the drawing travels as data")
        var long = doc
        long.timeline?.duration = 600
        let longer = try XCTUnwrap(Exporter.player(long))
        XCTAssertLessThan(abs(longer.utf8.count - html.utf8.count), 64, "no frames are baked in")
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?) async throws -> T {
    let v = try await value()
    return try XCTUnwrap(v)
}
