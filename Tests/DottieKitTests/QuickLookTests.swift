import XCTest
import CoreGraphics
@testable import DottieKit

final class QuickLookTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, frame: CGRect) throws {
        _ = try DiagramOps.addShape(&doc, kind: .rectangle, frame: frame, at: .zero, text: nil, fill: nil, stroke: nil,
                                    roughness: 0)
    }

    func testPDFHasOnePagePerDottiePageEachSizedToItsDrawing() throws {
        var file = DottieFile()
        try box(&file.pages[0], frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let tall = file.addPage(name: "Tall")
        let second = try XCTUnwrap(file.index(of: tall))
        try box(&file.pages[second], frame: CGRect(x: 50, y: 50, width: 100, height: 400))

        let data = try XCTUnwrap(Exporter.pdf(file))
        let pdf = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(pdf.numberOfPages, 2)
        for (n, doc) in file.pages.enumerated() {
            let media = try XCTUnwrap(pdf.page(at: n + 1)).getBoxRect(.mediaBox)
            let b = Exporter.bounds(of: doc)
            XCTAssertEqual(media.width, b.width, accuracy: 0.5)
            XCTAssertEqual(media.height, b.height, accuracy: 0.5)
        }
    }

    func testFittedSizeKeepsAspectRatio() throws {
        var wide = DottieDocument()
        try box(&wide, frame: CGRect(x: 0, y: 0, width: 952, height: 452)) // 1000 x 500 with the padding
        XCTAssertEqual(Exporter.fittedSize(of: wide, in: CGSize(width: 512, height: 512)), CGSize(width: 512, height: 256))

        var tall = DottieDocument()
        try box(&tall, frame: CGRect(x: 0, y: 0, width: 152, height: 352)) // 200 x 400
        XCTAssertEqual(Exporter.fittedSize(of: tall, in: CGSize(width: 100, height: 100)), CGSize(width: 50, height: 100))
        XCTAssertEqual(Exporter.fittedSize(of: tall, in: CGSize(width: 1000, height: 1000), allowUpscale: false),
                       CGSize(width: 200, height: 400))

        // An empty page still has a 200 x 200 placeholder area, so it gets a square thumbnail.
        XCTAssertEqual(Exporter.fittedSize(of: DottieDocument(), in: CGSize(width: 64, height: 64)), CGSize(width: 64, height: 64))
        XCTAssertEqual(Exporter.fittedSize(of: tall, in: .zero), .zero)
    }

    func testThumbnailDrawsOnTheThemesPageColor() throws {
        var doc = DottieDocument()
        doc.theme = Theme.blueprint.id
        try box(&doc, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let size = CGSize(width: 32, height: 32)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        Exporter.draw(doc, in: ctx, size: size)
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        // The corner is page color, outside the box: Blueprint's dark blue.
        let (r, g, b) = (Double(pixels[0]) / 255, Double(pixels[1]) / 255, Double(pixels[2]) / 255)
        XCTAssertEqual(r, Theme.blueprint.background.r, accuracy: 0.02)
        XCTAssertEqual(g, Theme.blueprint.background.g, accuracy: 0.02)
        XCTAssertEqual(b, Theme.blueprint.background.b, accuracy: 0.02)
    }

    func testLibrarySheetLaysItemsOutInAGrid() {
        func item(_ name: String, _ w: Double, _ h: Double) -> StencilItem {
            let e = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: w, height: h), layerID: UUID())
            return StencilItem(name: name, width: w, height: h, elements: [e], imported: true)
        }
        let library = StencilLibrary(name: "Shapes", items: [item("a", 60, 60), item("b", 240, 120), item("c", 10, 10)])
        let sheet = library.sheet(columns: 2, cell: 100, gap: 20)
        XCTAssertEqual(sheet.name, "Shapes")
        XCTAssertEqual(sheet.elements.count, 3)
        XCTAssertTrue(sheet.elements.allSatisfy { $0.layerID == sheet.layers[0].id })
        let frames = sheet.elements.map(\.frame)
        XCTAssertEqual(frames[0], CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(frames[1], CGRect(x: 120, y: 25, width: 100, height: 50)) // second column, centered
        XCTAssertEqual(frames[2], CGRect(x: 0, y: 120, width: 100, height: 100)) // wraps to the second row
    }
}
