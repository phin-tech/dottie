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

    func testPlayerHasEveryFrameOnOneViewBox() throws {
        let html = try XCTUnwrap(Exporter.player(try animated(), title: "<demo>"))
        XCTAssertEqual(html.components(separatedBy: "<div class=\"f").count - 1, 11)
        let boxes = Set(html.components(separatedBy: "viewBox=\"").dropFirst().map { $0.prefix { $0 != "\"" } })
        XCTAssertEqual(boxes.count, 1)
        XCTAssertTrue(html.contains("&lt;demo&gt;"))
        let frames = html.components(separatedBy: "<div class=\"f").dropFirst().joined()
        XCTAssertFalse(frames.prefix { _ in true }.split(separator: "<div class=\"bar").first!.contains(" id=\""),
                       "frames inline side by side, so SVG ids would collide")
    }
}

extension AnimationExportTests {
    /// Each player frame with its `<use>` references expanded, beside the frame drawn whole the old way.
    private func expandedFrames(_ doc: DottieDocument) throws -> [(slim: String, whole: String)] {
        let plan = try XCTUnwrap(Exporter.animation(doc))
        let (holder, frames) = Exporter.playerFrames(doc, plan: plan)
        var defs: [String: String] = [:]
        let pattern = try NSRegularExpression(pattern: #"<g id="(d[sp]\d+)">\n(.*?)</g>\n(?=<g id="d[sp]\d+">|</defs>)"#,
                                              options: [.dotMatchesLineSeparators])
        for m in pattern.matches(in: holder, range: NSRange(holder.startIndex..., in: holder)) {
            defs[String(holder[Range(m.range(at: 1), in: holder)!])] = String(holder[Range(m.range(at: 2), in: holder)!])
        }
        return zip(frames, plan.times.indices).map { frame, i in
            var slim = frame
            for (id, markup) in defs { slim = slim.replacingOccurrences(of: "<use href=\"#\(id)\"/>\n", with: markup) }
            return (slim, Exporter.svg(doc.resolved(at: plan.times[i]), background: nil, bounds: plan.rects[i]))
        }
    }

    func testThePlayerSharesWhatRepeatsAndStaysExact() throws {
        // Interleaved on purpose: a still shape above a moving one, a boiling one, and one that appears later.
        var doc = DottieDocument()
        let below = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 40), at: .zero,
                                            text: "below", fill: nil, stroke: nil, roughness: 1)
        let mover = try DiagramOps.addShape(&doc, kind: .ellipse, frame: CGRect(x: 0, y: 60, width: 40, height: 40), at: .zero,
                                            text: nil, fill: RGBA(r: 1, g: 0, b: 0), stroke: nil, roughness: 1)
        _ = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 20, y: 50, width: 80, height: 60), at: .zero,
                                    text: "above", fill: RGBA(r: 0.8, g: 0.9, b: 1), stroke: nil, roughness: 1)
        let late = try DiagramOps.addShape(&doc, kind: .diamond, frame: CGRect(x: 200, y: 0, width: 60, height: 60), at: .zero,
                                           text: nil, fill: nil, stroke: nil, roughness: 1)
        _ = try DiagramOps.addConnector(&doc, from: below.id, to: late.id)
        var tl = Timeline(fps: 8, duration: 2, boil: 2, settle: true)
        tl.setKey(Keyframe(t: 0, x: 0), for: mover.id)
        tl.setKey(Keyframe(t: 1, x: 150), for: mover.id)
        doc.timeline = tl
        try doc.addTransition(.popIn, to: late.id, at: 0.5)
        for (slim, whole) in try expandedFrames(doc) { XCTAssertEqual(slim, whole) }

        let plan = try XCTUnwrap(Exporter.animation(doc))
        let (holder, frames) = Exporter.playerFrames(doc, plan: plan)
        let wholeSize = plan.times.indices.map { Exporter.svg(doc.resolved(at: plan.times[$0]), background: nil, bounds: plan.rects[$0]).utf8.count }.reduce(0, +)
        XCTAssertLessThan(holder.utf8.count + frames.map(\.utf8.count).reduce(0, +), wholeSize / 2, "shared, it's much smaller")
    }

    func testTheTourDemoStaysExact() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Design/demos/tour.dottie")
        let doc = try DottieFile.decode(Data(contentsOf: url)).pages[0]
        let frames = try expandedFrames(doc)
        XCTAssertGreaterThan(frames.count, 100)
        for (slim, whole) in frames { XCTAssertEqual(slim, whole) }
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?) async throws -> T {
    let v = try await value()
    return try XCTUnwrap(v)
}
