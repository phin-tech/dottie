import XCTest
import CoreGraphics
@testable import DottieKit

final class SVGImportTests: XCTestCase {
    let layer = UUID()

    func imported(_ svg: String, _ options: SVGImporter.Options = .init()) throws -> SVGImporter.Result {
        try SVGImporter.importElements(from: Data(svg.utf8), layerID: layer, options: options)
    }

    func testBasicShapesAndViewBoxOrigin() throws {
        let r = try imported("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="10 20 100 50">
          <rect x="10" y="20" width="40" height="30" fill="#ff0000"/>
          <circle cx="80" cy="45" r="10" fill="none" stroke="blue" stroke-width="3"/>
        </svg>
        """)
        XCTAssertEqual(r.size, CGSize(width: 100, height: 50))
        XCTAssertEqual(r.elements.count, 2)
        XCTAssertNotNil(r.elements[0].groupID)
        XCTAssertEqual(r.elements[0].groupID, r.elements[1].groupID)
        XCTAssertEqual(r.elements[0].frame.origin.x, 0, accuracy: 0.01)   // viewBox origin moved to 0,0
        XCTAssertEqual(r.elements[0].style.fill, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(r.elements[1].style.stroke, RGBA(r: 0, g: 0, b: 1))
        XCTAssertEqual(r.elements[1].style.strokeWidth, 3, accuracy: 0.01)
        XCTAssertEqual(r.elements[1].style.fill.a, 0)
        XCTAssertEqual(r.elements[0].style.roughness, 0)
    }

    func testPathCommandsIncludingArcsAndImplicitRepeats() throws {
        // A 20x20 rounded square drawn with relative commands, arcs and an implicit lineto run.
        let r = try imported("""
        <svg viewBox="0 0 20 20"><path d="M5 0h10a5 5 0 0 1 5 5v10a5 5 0 0 1-5 5H5a5 5 0 0 1-5-5V5a5 5 0 0 1 5-5z"/></svg>
        """)
        let e = r.elements[0]
        XCTAssertEqual(e.frame.width, 20, accuracy: 0.1)
        XCTAssertEqual(e.frame.height, 20, accuracy: 0.1)
        XCTAssertTrue(e.shapePath.contains(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(e.shapePath.contains(CGPoint(x: 0.3, y: 0.3)), "arcs round the corner")
        let poly = try imported(##"<svg viewBox="0 0 10 10"><path d="M0 0 10 0 10 10" fill="none" stroke="#000"/></svg>"##)
        XCTAssertEqual(poly.elements[0].subpaths?.first?.coords.count, 2 + 6 * 2)
    }

    func testTransformsAndUse() throws {
        let r = try imported("""
        <svg viewBox="0 0 100 100">
          <defs><rect id="box" width="10" height="10"/></defs>
          <g transform="translate(50 0) scale(2)"><use href="#box" x="5" y="5" fill="green"/></g>
        </svg>
        """)
        XCTAssertEqual(r.elements.count, 1)
        // (5,5) scaled by 2 then moved right by 50; size 10 * 2.
        XCTAssertEqual(r.elements[0].frame.minX, 60, accuracy: 0.1)
        XCTAssertEqual(r.elements[0].frame.minY, 10, accuracy: 0.1)
        XCTAssertEqual(r.elements[0].frame.width, 20, accuracy: 0.1)
    }

    func testCSSClassesStyleAttributeAndInheritance() throws {
        let r = try imported("""
        <svg viewBox="0 0 10 10"><style>.a{fill:#00ff00} rect{stroke:#000000;stroke-width:2}</style>
          <g fill="red"><rect class="a" width="4" height="4"/><rect width="4" height="4" style="fill:#0000ff"/>
          <rect width="4" height="4"/></g></svg>
        """)
        XCTAssertEqual(r.elements[0].style.fill, RGBA(r: 0, g: 1, b: 0))
        XCTAssertEqual(r.elements[1].style.fill, RGBA(r: 0, g: 0, b: 1))
        XCTAssertEqual(r.elements[2].style.fill, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(r.elements[0].style.strokeWidth, 2, accuracy: 0.01)
    }

    func testEvenOddGradientsAndOpacity() throws {
        let r = try imported("""
        <svg viewBox="0 0 10 10"><defs><linearGradient id="g"><stop offset="0" stop-color="#ff8000"/></linearGradient></defs>
          <path fill="url(#g)" fill-rule="evenodd" opacity="0.5" d="M0 0H10V10H0Z M2 2H8V8H2Z"/></svg>
        """)
        XCTAssertEqual(r.elements[0].evenOdd, true)
        XCTAssertEqual(r.elements[0].style.fill.g, 128.0 / 255, accuracy: 0.01)
        XCTAssertEqual(r.elements[0].style.fill.a, 0.5, accuracy: 0.01)
        XCTAssertEqual(r.elements[0].subpaths?.count, 2)
    }

    func testRestyleKeepsFillsAndUsesInk() throws {
        var o = SVGImporter.Options()
        o.keepOriginalColors = false
        o.roughness = 1.5
        let r = try imported(##"<svg viewBox="0 0 10 10"><rect width="10" height="10" fill="#ffcc00" stroke="#ff0000"/></svg>"##, o)
        XCTAssertEqual(r.elements[0].style.fill, RGBA(r: 1, g: 0.8, b: 0))
        XCTAssertTrue(r.elements[0].style.stroke.isAutomaticInk)
        XCTAssertEqual(r.elements[0].style.roughness, 1.5)
    }

    func testHiddenAndRejects() {
        XCTAssertThrowsError(try imported("<html/>"))
        XCTAssertThrowsError(try imported(##"<svg viewBox="0 0 1 1"><rect width="1" height="1" display="none"/></svg>"##))
        XCTAssertThrowsError(try imported("not xml at all"))
    }

    func testImportedDocumentRoundTripsThroughJSONAndRenders() throws {
        let r = try imported(##"<svg viewBox="0 0 24 24"><path d="M12 2l3 7h7l-5.5 4.5 2 7.5-6.5-4.5-6.5 4.5 2-7.5L2 9h7z" fill="#fc0" stroke="#000"/></svg>"##)
        var doc = DottieDocument()
        doc.elements = r.elements.map { var e = $0; e.layerID = doc.layers[0].id; return e }
        let back = try DottieDocument.decode(doc.encoded())
        XCTAssertEqual(back.elements.count, 1)
        XCTAssertNotNil(Exporter.png(back, scale: 2))
        XCTAssertTrue(Exporter.svg(back).contains("<path"))
    }
}
