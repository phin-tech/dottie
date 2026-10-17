import XCTest
import CoreGraphics
import ImageIO
@testable import DottieKit

final class RedactTests: XCTestCase {
    /// Black and white columns one pixel wide: anything pixelated turns grey, anything left alone stays.
    private func stripes(width: Int = 200, height: Int = 100) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 0, to: width, by: 2) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: height)) }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// The red channel of the picture's pixel (x, y from the top left).
    private func red(_ img: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return buf[0]
    }

    private func picture(_ doc: inout DottieDocument, at origin: CGPoint = .zero) throws -> Element {
        try DiagramOps.addImage(&doc, data: stripes(), at: origin)
    }

    func testThePartUnderTheBoxIsPixelatedAndTheRestIsNot() throws {
        var doc = DottieDocument()
        let e = try picture(&doc, at: CGPoint(x: 100, y: 100)) // 200 × 100 points, one point a pixel
        let before = e.image!.digest
        let changed = Redaction.pixelate(&doc, in: CGRect(x: 100, y: 100, width: 100, height: 50), layers: [doc.layers[0].id])
        XCTAssertEqual(changed, [e.id])
        let after = try XCTUnwrap(doc.elements[0].image)
        XCTAssertNotEqual(after.digest, before)
        XCTAssertEqual(after.format, "png")
        let img = try XCTUnwrap(after.cgImage)
        XCTAssertEqual(img.width, 200)
        for (x, y) in [(10, 10), (11, 10), (50, 25), (90, 45)] { // inside: grey blocks, no stripes left
            XCTAssertTrue((90...165).contains(red(img, x, y)), "(\(x), \(y)) is \(red(img, x, y))")
        }
        XCTAssertEqual(red(img, 150, 80), 0)   // outside: untouched
        XCTAssertEqual(red(img, 151, 80), 255)
        XCTAssertEqual(red(img, 10, 70), 0)
    }

    func testPicturesOutsideTheBoxOrOnOtherLayersAreLeftAlone() throws {
        var doc = DottieDocument()
        let e = try picture(&doc)
        XCTAssertTrue(Redaction.pixelate(&doc, in: CGRect(x: 500, y: 500, width: 50, height: 50), layers: [doc.layers[0].id]).isEmpty)
        XCTAssertTrue(Redaction.pixelate(&doc, in: CGRect(x: 0, y: 0, width: 50, height: 50), layers: []).isEmpty)
        XCTAssertEqual(doc.elements[0].image, e.image)
    }

    func testARotatedPictureIsPixelatedWhereTheBoxCoversIt() throws {
        var doc = DottieDocument()
        _ = try picture(&doc)
        doc.elements[0].rotation = .pi // upside down: the page's top left shows the picture's bottom right
        Redaction.pixelate(&doc, in: CGRect(x: 0, y: 0, width: 40, height: 40), layers: [doc.layers[0].id])
        let img = try XCTUnwrap(doc.elements[0].image?.cgImage)
        XCTAssertTrue((90...165).contains(red(img, 180, 80)))
        XCTAssertEqual(red(img, 10, 10), 0)
    }

    func testBlocksAreCoarseEnoughToHideText() {
        // A line of Retina text (2 pixels a point): at least 10 points, so two blocks tall.
        XCTAssertEqual(Redaction.blockSize(for: CGRect(x: 0, y: 0, width: 600, height: 40), pixelsPerPoint: 2), 20)
        XCTAssertEqual(Redaction.blockSize(for: CGRect(x: 0, y: 0, width: 400, height: 200), pixelsPerPoint: 1), 100)
    }

    func testAP3ScreenshotKeepsItsColorsOutsideTheBox() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: p3, components: [0.2, 0.6, 0.9, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let out = try XCTUnwrap(Redaction.pixelated(ctx.makeImage()!, region: CGRect(x: 0, y: 0, width: 10, height: 10), block: 10))
        XCTAssertEqual(out.colorSpace?.name, CGColorSpace.displayP3)
    }
}
