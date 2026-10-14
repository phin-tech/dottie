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

final class InsertArtTests: XCTestCase {
    func testInsertCentersAndRemapsGroups() throws {
        var doc = DottieDocument()
        let svg = ##"<svg viewBox="0 0 40 20"><rect width="10" height="10" fill="red"/><rect x="20" width="20" height="20" fill="blue"/></svg>"##
        let art = try SVGImporter.importElements(from: Data(svg.utf8), layerID: UUID())
        let a = doc.insert(art.elements, size: art.size, center: CGPoint(x: 100, y: 100), layerID: doc.layers[0].id)
        let b = doc.insert(art.elements, size: art.size, center: CGPoint(x: 300, y: 100), layerID: doc.layers[0].id)
        XCTAssertEqual(a.count, 2)
        XCTAssertTrue(a.isDisjoint(with: b))
        let first = doc.elements.filter { a.contains($0.id) }
        XCTAssertEqual(first.map(\.frame.minX).min()!, 80, accuracy: 0.1)      // 100 - 40/2
        XCTAssertEqual(Set(first.compactMap(\.groupID)).count, 1)
        XCTAssertNotEqual(doc.elements.first { a.contains($0.id) }?.groupID,
                          doc.elements.first { b.contains($0.id) }?.groupID)
        XCTAssertTrue(doc.elements.allSatisfy { $0.layerID == doc.layers[0].id })
    }
}

final class StencilLibraryTests: XCTestCase {
    func testStarterItemsAreDrawableAndStable() throws {
        let lib = StencilLibrary.starter
        XCTAssertGreaterThanOrEqual(lib.items.count, 12)
        XCTAssertEqual(Set(lib.items.map(\.id)).count, lib.items.count)
        XCTAssertEqual(lib.items.map(\.id), StencilLibrary.starter.items.map(\.id))
        for item in lib.items {
            XCTAssertFalse(item.elements.isEmpty, item.name)
            XCTAssertNotNil(Exporter.png(item.document(), scale: 1), item.name)
            for e in item.elements {
                XCTAssertGreaterThanOrEqual(e.x, -0.5, item.name); XCTAssertGreaterThanOrEqual(e.y, -0.5, item.name)
                XCTAssertLessThanOrEqual(e.frame.maxX, item.width + 1.5, item.name)
                XCTAssertLessThanOrEqual(e.frame.maxY, item.height + 1.5, item.name)
            }
        }
    }

    func testLibraryRoundTripsThroughJSON() throws {
        let lib = StencilLibrary.starter
        XCTAssertEqual(try StencilLibrary.decode(lib.encoded()).items.count, lib.items.count)
        XCTAssertEqual(try StencilLibrary.decode(lib.encoded()).name, "Basics")
    }

    func testFromSVGsNamesItemsAndReportsFailures() {
        let ok = Data(##"<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/></svg>"##.utf8)
        let (lib, failed) = StencilLibrary.fromSVGs(name: "Icons", files: [("circle", ok), ("broken", Data("x".utf8))])
        XCTAssertEqual(lib.items.map(\.name), ["circle"])
        XCTAssertEqual(failed, ["broken"])
        XCTAssertEqual(lib.items[0].width, 24)
        XCTAssertGreaterThan(lib.items[0].readableScale, 3.9) // 24 -> 96
    }

    func testItemFromSelectionNormalizesToOriginAndPlacesCentered() throws {
        var doc = DottieDocument()
        let l = doc.layers[0].id
        let a = Element(kind: .rectangle, frame: CGRect(x: 300, y: 400, width: 100, height: 50), layerID: l)
        let b = Element(kind: .ellipse, frame: CGRect(x: 500, y: 420, width: 40, height: 40), layerID: l)
        var link = Element(kind: .connector, frame: .zero, layerID: l,
                           connector: ConnectorData(start: .bound(a.id), end: .bound(b.id)))
        link.seed = 3
        doc.elements = [a, b, link]
        let item = try XCTUnwrap(StencilLibrary.item(from: doc, ids: Set([a.id, b.id, link.id]), name: "Pair"))
        XCTAssertEqual(item.width, 240, accuracy: 0.5)
        XCTAssertEqual(item.elements.first { $0.id == a.id }?.x, 0)
        XCTAssertFalse(item.imported)

        var target = DottieDocument()
        let ids = target.place(item, center: CGPoint(x: 1000, y: 1000), layerID: target.layers[0].id, keepOriginalColors: false)
        XCTAssertEqual(ids.count, 3)
        let placed = target.elements.filter { ids.contains($0.id) && $0.kind != .connector }
        XCTAssertEqual(placed.map(\.frame.minX).min()!, 1000 - item.width * item.readableScale / 2, accuracy: 0.5)
        // The new connector is bound to the new copies, not the originals.
        let c = try XCTUnwrap(target.elements.first { $0.kind == .connector })
        XCTAssertTrue(ids.contains(c.connector!.start.elementID!))
        XCTAssertFalse(doc.elements.contains { $0.id == c.connector!.start.elementID })
    }

    func testRestyleOnlyTouchesImportedItems() {
        var st = Style(); st.roughness = 0; st.stroke = RGBA(r: 1, g: 0, b: 0)
        let e = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), style: st, layerID: UUID())
        let imported = StencilItem(name: "i", width: 10, height: 10, elements: [e], imported: true)
        let native = StencilItem(name: "n", width: 10, height: 10, elements: [e], imported: false)
        XCTAssertTrue(imported.placed(keepOriginalColors: false)[0].style.stroke.isAutomaticInk)
        XCTAssertEqual(imported.placed(keepOriginalColors: true)[0].style.stroke, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(native.placed(keepOriginalColors: false)[0].style.stroke, RGBA(r: 1, g: 0, b: 0))
    }
}

final class StencilFilesTests: XCTestCase {
    func testLoadDirectoryReadsOnlyValidLibraries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dottielib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try StencilLibrary(name: "B", items: []).encoded().write(to: dir.appendingPathComponent("b.dottielib"))
        try StencilLibrary(name: "A", items: []).encoded().write(to: dir.appendingPathComponent("a.dottielib"))
        try Data("nope".utf8).write(to: dir.appendingPathComponent("bad.dottielib"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        XCTAssertEqual(StencilLibrary.load(directory: dir).map(\.library.name), ["A", "B"])
        XCTAssertTrue(StencilLibrary.load(directory: dir.appendingPathComponent("missing")).isEmpty)
    }
}
