import XCTest
import ImageIO
@testable import DottieKit

final class FadeTests: XCTestCase {
    private func redBox(_ doc: inout DottieDocument) throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 100), at: .zero,
                                text: nil, fill: RGBA(r: 1, g: 0, b: 0), stroke: RGBA(r: 1, g: 0, b: 0), roughness: 0)
    }

    /// The middle pixel of a PNG render, on white.
    private func centerPixel(_ doc: DottieDocument) throws -> (r: Int, g: Int, b: Int) {
        let png = try XCTUnwrap(Exporter.png(doc, scale: 1))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil))
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    func testFadeInPassesThroughPartialOpacityInBothRenderers() throws {
        var doc = DottieDocument()
        let a = try redBox(&doc)
        try doc.addTransition(.fadeIn, to: a.id, at: 0, duration: 1)
        XCTAssertEqual(doc.resolved(at: 0).elements[0].style.opacity, 0)
        let mid = doc.resolved(at: 0.5)
        let o = try XCTUnwrap(mid.elements[0].style.opacity)
        XCTAssertTrue(o > 0.2 && o < 0.95, "\(o)")
        XCTAssertNil(doc.resolved(at: 1).elements[0].style.opacity, "fully opaque at rest")
        let p = try centerPixel(mid)
        XCTAssertEqual(p.r, 255)
        XCTAssertTrue(p.g > 10 && p.g < 245, "pink, not red or white: \(p)")
        XCTAssertTrue(Exporter.svg(mid).contains("<g opacity=\""))
        XCTAssertFalse(Exporter.svg(doc.resolved(at: 1)).contains("opacity=\""))
    }

    func testFadeOutHidesAndArrowsCanFade() throws {
        var doc = DottieDocument()
        let a = try redBox(&doc)
        let b = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 300, y: 0, width: 50, height: 50), at: .zero,
                                        text: nil, fill: nil, stroke: nil, roughness: 0)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        try doc.addTransition(.fadeOut, to: c.id, at: 1, duration: 1)
        XCTAssertNotNil(doc.resolved(at: 1.5).elements.first { $0.id == c.id }?.style.opacity)
        XCTAssertNil(doc.resolved(at: 2).elements.first { $0.id == c.id }, "gone once faded")
        XCTAssertThrowsError(try doc.addTransition(.popIn, to: c.id, at: 0))
    }

    func testOpacityRoundTripsAndPosesAsAKey() throws {
        var doc = DottieDocument()
        let a = try redBox(&doc)
        doc.elements[0].style.opacity = 0.5
        XCTAssertEqual(try DottieDocument.decode(doc.encoded()).elements[0].style.opacity, 0.5)
        doc.startAnimation()
        var frame = doc.resolved(at: 1)
        frame.elements[0].style.opacity = 0.2
        let posed = doc.applyingPose(frame, at: 1)
        XCTAssertEqual(posed.resolved(at: 1).elements[0].style.opacity ?? 1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(posed.resolved(at: 0).elements[0].style.opacity ?? 1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(posed.timeline?.track(for: a.id)?.keys.first?.opacity, 0.5)
    }

    func testScriptsKeyOpacityAndReveal() {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const a = dottie.rect({x: 0, y: 0});
            dottie.key(a, 0, {opacity: 0, reveal: 0});
            dottie.key(a, 1, {opacity: 1, reveal: 1});
            dottie.transition(a, "fadeOut", 2);
            """, on: &doc)
        XCTAssertNil(r.error)
        let keys = doc.timeline?.tracks.first?.keys ?? []
        XCTAssertEqual(keys.first?.opacity, 0)
        XCTAssertEqual(keys.first?.reveal, 0)
        XCTAssertEqual(keys.count, 4)
    }
}
