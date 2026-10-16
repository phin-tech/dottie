import XCTest
import AVFoundation
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

    func testMP4HasEvenSizeAndTheTimelinesLength() async throws {
        let data = try XCTUnwrap(Exporter.mp4(try animated(), scale: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.05)
        let track = try await XCTUnwrapAsync(await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
        XCTAssertGreaterThan(size.width, 300, "framed to the whole motion")
    }

    func testPlayerHasEveryFrameOnOneViewBox() throws {
        let html = Exporter.player(try animated(), title: "<demo>")
        XCTAssertEqual(html.components(separatedBy: "<div class=\"f").count - 1, 10)
        let boxes = Set(html.components(separatedBy: "viewBox=\"").dropFirst().map { $0.prefix { $0 != "\"" } })
        XCTAssertEqual(boxes.count, 1)
        XCTAssertTrue(html.contains("&lt;demo&gt;"))
        let frames = html.components(separatedBy: "<div class=\"f").dropFirst().joined()
        XCTAssertFalse(frames.prefix { _ in true }.split(separator: "<div class=\"bar").first!.contains(" id=\""),
                       "frames inline side by side, so SVG ids would collide")
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?) async throws -> T {
    let v = try await value()
    return try XCTUnwrap(v)
}
