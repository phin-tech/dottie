import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import DottieKit

final class ImageTests: XCTestCase {
    /// A picture whose top half is red and bottom half blue, so a flipped draw is caught.
    private func redOverBlue(width: Int = 40, height: Int = 20, type: UTType = .png, dpi: Double? = nil, orientation: Int? = nil) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext is y-up: the top half is the upper y range.
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let dpi { props[kCGImagePropertyDPIWidth] = dpi; props[kCGImagePropertyDPIHeight] = dpi }
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func pixel(_ png: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so that image pixel (x, y from the top) lands on the single context pixel.
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (buf[0], buf[1], buf[2])
    }

    func testAddImageKeepsSizeAndAspect() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addImage(&doc, data: redOverBlue(), at: CGPoint(x: 10, y: 20))
        XCTAssertEqual(e.kind, .image)
        XCTAssertEqual(e.frame, CGRect(x: 10, y: 20, width: 40, height: 20))
        XCTAssertEqual(e.image?.format, "png")
        let scaled = try DiagramOps.addImage(&doc, data: redOverBlue(), at: .zero, width: 100)
        XCTAssertEqual(scaled.height, 50)
        XCTAssertEqual(doc.elements.count, 2)
    }

    func testRetinaImageIsPlacedInPoints() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addImage(&doc, data: redOverBlue(width: 200, height: 100, dpi: 144), at: .zero)
        XCTAssertEqual(e.frame.size, CGSize(width: 100, height: 50))
    }

    func testHugeImagesAreCapped() throws {
        let (image, size) = try ImageImport.normalize(redOverBlue(width: 4000, height: 1000))
        XCTAssertEqual(size, CGSize(width: 640, height: 160))
        let img = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(max(img.width, img.height), ImageImport.maxPixels)
    }

    func testExifRotationIsApplied() throws {
        // Orientation 6: stored landscape, shown rotated 90° clockwise, so portrait.
        let (image, size) = try ImageImport.normalize(redOverBlue(width: 40, height: 20, type: .jpeg, orientation: 6))
        XCTAssertEqual(size, CGSize(width: 20, height: 40))
        let img = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(img.width, 20); XCTAssertEqual(img.height, 40)
        XCTAssertEqual(image.format, "jpeg")
    }

    func testRejectsNonImages() {
        var doc = DottieDocument()
        XCTAssertThrowsError(try DiagramOps.addImage(&doc, data: Data("hello".utf8), at: .zero))
        XCTAssertTrue(doc.elements.isEmpty)
    }

    func testShapePathsCannotMakeEmptyImages() {
        var doc = DottieDocument()
        XCTAssertThrowsError(try DiagramOps.addShape(&doc, kind: .image, frame: nil, at: .zero, text: nil, fill: nil, stroke: nil, roughness: nil))
        XCTAssertThrowsError(try DiagramOps.build(&doc, nodes: [.init(key: "a", text: "", kind: .image)], edges: []))
    }

    func testPNGExportDrawsImageUprightAndInPlace() throws {
        var doc = DottieDocument()
        try DiagramOps.addImage(&doc, data: redOverBlue(), at: .zero)
        let png = try XCTUnwrap(Exporter.png(doc, scale: 1))
        // Exports pad by 24 on every side; the picture spans 24...64 x 24...44.
        let top = pixel(png, x: 44, y: 28), bottom = pixel(png, x: 44, y: 40), outside = pixel(png, x: 5, y: 5)
        XCTAssertGreaterThan(top.r, 200); XCTAssertLessThan(top.b, 50)
        XCTAssertGreaterThan(bottom.b, 200); XCTAssertLessThan(bottom.r, 50)
        XCTAssertEqual(outside.r, 255); XCTAssertEqual(outside.b, 255)
    }

    func testSVGEmbedsDataURI() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addImage(&doc, data: redOverBlue(), at: .zero)
        let svg = Exporter.svg(doc)
        XCTAssertTrue(svg.contains("<image x=\"0\" y=\"0\" width=\"40\" height=\"20\""))
        XCTAssertTrue(svg.contains("href=\"data:image/png;base64,\(e.image!.data.base64EncodedString())\""))
        XCTAssertFalse(svg.contains("<path"), "no border without a stroke")

        try DiagramOps.update(&doc, id: e.id, stroke: RGBA(hex: "#ff0000"))
        XCTAssertTrue(Exporter.svg(doc).contains("<path"))
    }

    func testRoundTripsThroughFileWithoutSavingDigest() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addImage(&doc, data: redOverBlue(), at: .zero)
        let data = try DottieFile(pages: [doc]).encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("digest"))
        let back = try DottieFile.decode(data).pages[0].elements[0]
        XCTAssertEqual(back.image?.data, e.image?.data)
        XCTAssertEqual(back.image?.digest, e.image?.digest)
        XCTAssertNotNil(back.image?.cgImage)
    }

    func testFileStoresEachPictureOnceAndElementsByReference() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addImage(&doc, data: redOverBlue(), at: .zero)
        let copies = doc.duplicate([e.id]).union(doc.duplicate([e.id]))
        XCTAssertEqual(copies.count, 2)
        var other = DottieDocument(name: "Page 2")
        other.elements = doc.elements.map { var c = $0; c.id = UUID(); return c }
        let data = try DottieFile(pages: [doc, other]).encoded()
        let json = String(decoding: data, as: UTF8.self)
        let table = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["images"] as? [String: Any])
        XCTAssertEqual(Array(table.keys), [e.image!.digest], "six elements, one copy of the bytes")
        XCTAssertEqual(json.components(separatedBy: "\"ref\" : \"\(e.image!.digest)\"").count - 1, 6)

        let back = try DottieFile.decode(data)
        let images = back.pages.flatMap(\.elements).compactMap(\.image)
        XCTAssertEqual(images.count, 6)
        XCTAssertTrue(images.allSatisfy { $0.data == e.image!.data && $0.digest == e.image!.digest })
        XCTAssertEqual(try back.encoded(), data, "saving again is stable")
    }

    func testDanglingReferenceStillOpens() throws {
        var doc = DottieDocument()
        try DiagramOps.addImage(&doc, data: redOverBlue(), at: .zero)
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: nil, at: CGPoint(x: 100, y: 0), text: "Box", fill: nil, stroke: nil, roughness: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: DottieFile(pages: [doc]).encoded()) as? [String: Any])
        json["images"] = nil
        let back = try DottieFile.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.pages[0].elements.count, 2)
        XCTAssertNil(back.pages[0].elements.first { $0.kind == .image }?.image?.cgImage)
        XCTAssertNotNil(Exporter.png(back.pages[0]), "the broken picture draws as a placeholder")
    }

    func testCopyPasteCarriesTheImage() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addImage(&doc, data: redOverBlue(), at: .zero)
        let clip = try XCTUnwrap(doc.clipboardData(for: [e.id]))
        let added = doc.paste(clip)
        let copy = try XCTUnwrap(doc.elements.first { added.contains($0.id) })
        XCTAssertEqual(copy.image, e.image)
    }
}
