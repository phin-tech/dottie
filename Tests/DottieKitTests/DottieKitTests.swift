import XCTest
import CoreGraphics
@testable import DottieKit

final class DottieKitTests: XCTestCase {
    func sampleDoc() -> DottieDocument {
        var doc = DottieDocument()
        let l = doc.layers[0].id
        var fill = Style(); fill.fill = RGBA(r: 1, g: 0.93, b: 0.6)
        doc.elements = [
            Element(kind: .rectangle, frame: CGRect(x: 40, y: 40, width: 160, height: 90), style: fill, seed: 1, layerID: l, text: "Hello"),
            Element(kind: .ellipse, frame: CGRect(x: 260, y: 50, width: 130, height: 80), seed: 2, layerID: l),
            Element(kind: .diamond, frame: CGRect(x: 120, y: 190, width: 140, height: 100), seed: 3, layerID: l),
            Element(kind: .text, frame: CGRect(x: 300, y: 220, width: 160, height: 30), seed: 4, layerID: l, text: "dottie"),
        ]
        return doc
    }

    func testJSONRoundTrip() throws {
        let doc = sampleDoc()
        let back = try DottieDocument.decode(try doc.encoded())
        XCTAssertEqual(doc, back)
    }

    func testJSONIsDeterministic() throws {
        let doc = sampleDoc()
        XCTAssertEqual(try doc.encoded(), try doc.encoded())
    }

    func testSameSeedSamePath() {
        let e = sampleDoc().elements[1]
        XCTAssertEqual(Renderer.outline(for: e), Renderer.outline(for: e))
    }

    func testDifferentSeedDifferentPath() {
        var a = sampleDoc().elements[0], b = a
        b.seed = 99
        XCTAssertNotEqual(Renderer.outline(for: a), Renderer.outline(for: b))
        a.style.roughness = 0
        XCTAssertEqual(Renderer.outline(for: a).boundingBox, a.frame)
    }

    func testHitTestRespectsZOrderAndLocks() {
        var doc = sampleDoc()
        XCTAssertEqual(doc.element(at: CGPoint(x: 50, y: 50))?.kind, .rectangle)
        doc.layers[0].locked = true
        XCTAssertNil(doc.element(at: CGPoint(x: 50, y: 50)))
    }

    func testCleanVersionIsExactGeometry() {
        let clean = sampleDoc().withRoughness(0)
        for e in clean.elements where e.kind != .text {
            XCTAssertEqual(Renderer.outline(for: e).boundingBox, e.frame)
        }
    }

    func testExportPNGAndPDF() throws {
        let doc = sampleDoc()
        let png = try XCTUnwrap(Exporter.png(doc))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertNotNil(Exporter.pdf(doc))
        if let dir = ProcessInfo.processInfo.environment["DOTTIE_OUT"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample.png"))
            let clean = try XCTUnwrap(Exporter.png(doc.withRoughness(0)))
            try clean.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample-clean.png"))
        }
    }
}
