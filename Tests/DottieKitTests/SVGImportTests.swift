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

final class ExcalidrawImportTests: XCTestCase {
    let scene = """
    {"type":"excalidraw","version":2,"elements":[
      {"id":"a","type":"rectangle","x":100,"y":200,"width":160,"height":80,"angle":0,"strokeColor":"#1e1e1e",
       "backgroundColor":"#ffec99","fillStyle":"hachure","strokeWidth":2,"strokeStyle":"dashed","roughness":2,"opacity":100,
       "seed":1234,"groupIds":["g1"],"isDeleted":false},
      {"id":"t","type":"text","x":120,"y":220,"width":100,"height":25,"text":"Hello","fontSize":20,"containerId":"a",
       "strokeColor":"#1e1e1e","backgroundColor":"transparent","isDeleted":false},
      {"id":"b","type":"ellipse","x":400,"y":200,"width":80,"height":80,"angle":0.5,"strokeColor":"#e03131",
       "backgroundColor":"transparent","isDeleted":false},
      {"id":"ar","type":"arrow","x":260,"y":240,"width":140,"height":0,"points":[[0,0],[140,0]],
       "startBinding":{"elementId":"a","focus":0,"gap":4},"endBinding":{"elementId":"b","focus":0,"gap":4},
       "startArrowhead":null,"endArrowhead":"triangle","strokeColor":"#1e1e1e","backgroundColor":"transparent","isDeleted":false},
      {"id":"gone","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":true},
      {"id":"img","type":"image","x":0,"y":0,"width":10,"height":10,"isDeleted":false},
      {"id":"fd","type":"freedraw","x":10,"y":10,"width":30,"height":20,"points":[[0,0],[10,8],[30,20]],
       "strokeColor":"#2f9e44","backgroundColor":"transparent","isDeleted":false}
    ]}
    """

    func testSceneMapsShapesLabelsBindingsAndLook() throws {
        let items = try ExcalidrawImporter.importItems(from: Data(scene.utf8), layerID: UUID())
        XCTAssertEqual(items.count, 1)
        let els = items[0].elements
        XCTAssertEqual(els.map(\.kind), [.rectangle, .ellipse, .connector, .path]) // label folded, deleted/image dropped
        let rect = els[0], ell = els[1], arrow = els[2]
        XCTAssertEqual(rect.text, "Hello")
        XCTAssertTrue(rect.style.stroke.isAutomaticInk)
        XCTAssertEqual(rect.style.fillStyle, .hachure)
        XCTAssertEqual(rect.style.dash, .dashed)
        XCTAssertEqual(rect.style.roughness, 2)
        XCTAssertNotNil(rect.groupID)
        XCTAssertEqual(ell.rotation, 0.5)
        XCTAssertEqual(ell.style.stroke, RGBA(r: 224.0 / 255, g: 49.0 / 255, b: 49.0 / 255))
        XCTAssertEqual(arrow.connector?.start.elementID, rect.id)
        XCTAssertEqual(arrow.connector?.end.elementID, ell.id)
        XCTAssertEqual(arrow.connector?.endHead, .triangle)
        XCTAssertEqual(arrow.connector?.startHead, Arrowhead.none)
        XCTAssertEqual(rect.x, 90, accuracy: 0.01) // normalized: freedraw's x=10 is the left edge
        XCTAssertEqual(items[0].size.width, 470, accuracy: 20) // the rotated ellipse sticks out a little
    }

    func testLibraryYieldsOneItemPerEntryAndV1Works() throws {
        let v2 = """
        {"type":"excalidrawlib","version":2,"libraryItems":[
          {"id":"1","name":"Box","elements":[{"id":"r","type":"rectangle","x":50,"y":50,"width":40,"height":20}]},
          {"id":"2","elements":[{"id":"e","type":"ellipse","x":5,"y":5,"width":10,"height":10}]}]}
        """
        let a = try ExcalidrawImporter.importItems(from: Data(v2.utf8), layerID: UUID())
        XCTAssertEqual(a.map(\.name), ["Box", "Item 2"])
        XCTAssertEqual(a[0].elements[0].x, 0)
        let v1 = #"{"type":"excalidrawlib","version":1,"library":[[{"id":"r","type":"diamond","x":9,"y":9,"width":10,"height":10}]]}"#
        XCTAssertEqual(try ExcalidrawImporter.importItems(from: Data(v1.utf8), layerID: UUID()).count, 1)
    }

    func testRejectsOtherJSON() {
        XCTAssertThrowsError(try ExcalidrawImporter.importItems(from: Data(#"{"type":"nope"}"#.utf8), layerID: UUID()))
        XCTAssertThrowsError(try ExcalidrawImporter.importItems(from: Data("[]".utf8), layerID: UUID()))
        XCTAssertThrowsError(try ExcalidrawImporter.importItems(from: Data(#"{"type":"excalidraw","elements":[]}"#.utf8), layerID: UUID()))
    }
}

final class ExcalidrawLibraryTests: XCTestCase {
    func testLibraryKeepsAuthoredLookAndPlaces() throws {
        let json = ##"{"type":"excalidrawlib","version":2,"libraryItems":[{"id":"1","name":"Box","elements":[{"id":"r","type":"rectangle","x":50,"y":50,"width":40,"height":20,"strokeColor":"#e03131","roughness":0}]}]}"##
        let lib = try StencilLibrary.fromExcalidraw(name: "X", data: Data(json.utf8))
        XCTAssertEqual(lib.items.count, 1)
        XCTAssertFalse(lib.items[0].imported)
        var doc = DottieDocument()
        let ids = doc.place(lib.items[0], center: .zero, layerID: doc.layers[0].id, keepOriginalColors: false)
        XCTAssertEqual(doc.elements.first { ids.contains($0.id) }?.style.roughness, 0)  // not restyled
    }
}

final class DrawioImportTests: XCTestCase {
    let xml = """
    <mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/>
      <mxCell id="a" value="Start &lt;b&gt;here&lt;/b&gt;" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;" vertex="1" parent="1">
        <mxGeometry x="100" y="100" width="120" height="60" as="geometry"/></mxCell>
      <mxCell id="b" value="DB" style="shape=cylinder3;whiteSpace=wrap;html=1;fillColor=none;" vertex="1" parent="1">
        <mxGeometry x="400" y="90" width="60" height="80" as="geometry"/></mxCell>
      <mxCell id="d" value="ok?" style="rhombus;whiteSpace=wrap;html=1;rotation=90;" vertex="1" parent="1">
        <mxGeometry x="250" y="300" width="80" height="80" as="geometry"/></mxCell>
      <mxCell id="e1" value="yes" style="edgeStyle=orthogonalEdgeStyle;endArrow=open;dashed=1;" edge="1" parent="1" source="a" target="b">
        <mxGeometry relative="1" as="geometry"/></mxCell>
      <mxCell id="e2" value="" style="endArrow=none;" edge="1" parent="1" target="d">
        <mxGeometry relative="1" as="geometry"><mxPoint x="50" y="50" as="sourcePoint"/></mxGeometry></mxCell>
      <mxCell id="g" value="" style="group" vertex="1" parent="1"><mxGeometry x="500" y="500" width="100" height="100" as="geometry"/></mxCell>
      <mxCell id="c" value="inner" style="text;" vertex="1" parent="g"><mxGeometry x="10" y="20" width="40" height="20" as="geometry"/></mxCell>
    </root></mxGraphModel>
    """

    func check(_ items: [DrawioImporter.Item]) {
        XCTAssertEqual(items.count, 1)
        let els = items[0].elements
        let byText = Dictionary(uniqueKeysWithValues: els.compactMap { e in e.text.map { ($0, e) } })
        let a = els.first { $0.text?.hasPrefix("Start") == true }
        XCTAssertEqual(a?.text, "Start here")                      // html stripped
        XCTAssertEqual(a?.kind, .rectangle)
        XCTAssertEqual(a?.style.fill, RGBA(r: 218.0 / 255, g: 232.0 / 255, b: 252.0 / 255))
        XCTAssertEqual(els.first { $0.kind == .diamond }?.rotation ?? 0, .pi / 2, accuracy: 0.001)
        XCTAssertEqual(els.filter { $0.kind == .path }.count, 2, "cylinder maps to the built-in database")
        let db = els.first { $0.kind == .path && $0.text == "DB" }
        XCTAssertNotNil(db)
        XCTAssertEqual(db?.width ?? 0, 60, accuracy: 0.5)
        let yes = byText["yes"]
        XCTAssertEqual(yes?.kind, .connector)
        XCTAssertEqual(yes?.connector?.routing, .elbow)
        XCTAssertEqual(yes?.connector?.endHead, .arrow)
        XCTAssertEqual(yes?.style.dash, .dashed)
        XCTAssertEqual(yes?.connector?.start.elementID, a?.id)
        let free = els.first { $0.kind == .connector && $0.text == nil }
        XCTAssertNil(free?.connector?.start.elementID)             // sourcePoint, not bound
        XCTAssertEqual(free?.connector?.endHead, Arrowhead.none)
        let inner = byText["inner"]
        XCTAssertEqual(inner?.kind, .text)
        XCTAssertEqual((inner?.x ?? 0) - (a?.x ?? 0), 410, accuracy: 0.5)   // group origin 500 + 10 vs a at 100
    }

    func testPlainXML() throws {
        check(try DrawioImporter.importItems(from: Data(xml.utf8), layerID: UUID()))
    }

    func testCompressedDiagramInsideMxfile() throws {
        let encoded = xml.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let deflated = try (Data(encoded.utf8) as NSData).compressed(using: .zlib) as Data
        let file = "<mxfile><diagram name=\"Flow\" id=\"x\">\(deflated.base64EncodedString())</diagram></mxfile>"
        let items = try DrawioImporter.importItems(from: Data(file.utf8), layerID: UUID())
        XCTAssertEqual(items[0].name, "Flow")
        check(items)
    }

    func testRejectsOtherXMLAndPlacesAsLibrary() throws {
        XCTAssertThrowsError(try DrawioImporter.importItems(from: Data("<svg/>".utf8), layerID: UUID()))
        let lib = try StencilLibrary.fromDrawio(name: "D", data: Data(xml.utf8))
        var doc = DottieDocument()
        let ids = doc.place(lib.items[0], center: .zero, layerID: doc.layers[0].id, keepOriginalColors: false)
        XCTAssertTrue(doc.elements.filter { ids.contains($0.id) && $0.kind != .text }.allSatisfy { $0.style.roughness > 0 })
    }
}
