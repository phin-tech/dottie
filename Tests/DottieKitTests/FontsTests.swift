import XCTest
import CoreText
@testable import DottieKit

final class FontsTests: XCTestCase {
    private func shape(_ doc: inout DottieDocument, font: String?, text: String = "Hello") throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 120, height: 60), at: .zero,
                                text: text, fill: nil, stroke: nil, roughness: 0, look: DiagramOps.Look(font: font))
    }

    func testBundledFontsLoadWithTheirFaces() {
        for family in Fonts.bundled {
            XCTAssertEqual(CTFontCopyFamilyName(Fonts.font(family, size: 18)) as String, family)
        }
        XCTAssertEqual(Fonts.faces(of: "Caveat"), [.regular, .bold])
        XCTAssertTrue(CTFontGetSymbolicTraits(Fonts.font("Caveat", size: 18, bold: true)).contains(.traitBold))
        // A face a bundled font lacks is its regular face, as CoreText does for an installed font.
        let bold = Fonts.font("Patrick Hand", size: 18, bold: true)
        XCTAssertEqual(CTFontCopyFamilyName(bold) as String, "Patrick Hand")
        XCTAssertFalse(CTFontGetSymbolicTraits(bold).contains(.traitBold))
        XCTAssertEqual(Fonts.bundledFamily("caveat"), "Caveat")
        XCTAssertNil(Fonts.bundledFamily("Menlo"))
    }

    func testAMissingFontIsHelveticaNeue() {
        XCTAssertFalse(Fonts.isInstalled("No Such Font Anywhere"))
        XCTAssertEqual(CTFontCopyFamilyName(Fonts.font("No Such Font Anywhere", size: 18)) as String, "Helvetica Neue")
        XCTAssertEqual(CTFontCopyFamilyName(Fonts.font(nil, size: 18)) as String, "Helvetica Neue")
        XCTAssertEqual(CTFontCopyFamilyName(Fonts.font("Menlo", size: 18)) as String, "Menlo")
    }

    func testTheFontChangesHowTextMeasures() {
        let plain = Renderer.textSize("Handwriting", fontSize: 18, maxWidth: 400)
        let caveat = Renderer.textSize("Handwriting", fontSize: 18, font: "Caveat", maxWidth: 400)
        XCTAssertLessThan(caveat.width, plain.width)
    }

    func testTheStyleKeepsItsFont() throws {
        var doc = DottieDocument()
        _ = try shape(&doc, font: "caveat")
        XCTAssertEqual(doc.elements[0].style.font, "Caveat", "a bundled font is stored by its own name")
        let data = try JSONEncoder().encode(doc.elements[0].style)
        XCTAssertEqual(try JSONDecoder().decode(Style.self, from: data).font, "Caveat")
        XCTAssertNil(try JSONDecoder().decode(Style.self, from: Data(#"{"font": ""}"#.utf8)).font)
        XCTAssertNil(try JSONDecoder().decode(Style.self, from: Data("{}".utf8)).font)
        // "" and the default's name go back to the default; any other name is kept as given.
        try DiagramOps.update(&doc, id: doc.elements[0].id, look: DiagramOps.Look(font: "Helvetica Neue"))
        XCTAssertNil(doc.elements[0].style.font)
        try DiagramOps.update(&doc, id: doc.elements[0].id, look: DiagramOps.Look(font: "Futura", fontSize: 1000))
        XCTAssertEqual(doc.elements[0].style.font, "Futura")
        XCTAssertEqual(doc.elements[0].style.fontSize, 200)
        try DiagramOps.update(&doc, id: doc.elements[0].id, look: DiagramOps.Look(font: ""))
        XCTAssertNil(doc.elements[0].style.font)
    }

    func testABuiltDiagramUsesItsFontEverywhere() throws {
        var doc = DottieDocument()
        try DiagramOps.build(&doc, nodes: [.init(key: "a", text: "A"), .init(key: "b", text: "B", kind: .note)],
                             edges: [.init(from: "a", to: "b", label: "yes")], font: "Patrick Hand")
        XCTAssertEqual(doc.elements.count, 3)
        XCTAssertTrue(doc.elements.allSatisfy { $0.style.font == "Patrick Hand" })
    }

    func testSVGEmbedsOnlyTheBundledFontsItUses() throws {
        var doc = DottieDocument()
        XCTAssertFalse(Exporter.svg(doc).contains("@font-face"))
        _ = try shape(&doc, font: nil)
        XCTAssertFalse(Exporter.svg(doc).contains("@font-face"))
        _ = try shape(&doc, font: "Futura")
        var svg = Exporter.svg(doc)
        XCTAssertFalse(svg.contains("@font-face"), "a font of one's own is named, never embedded")
        XCTAssertTrue(svg.contains(#"font-family="Futura, Helvetica Neue"#))
        _ = try shape(&doc, font: "Caveat")
        svg = Exporter.svg(doc)
        XCTAssertEqual(svg.components(separatedBy: "@font-face").count - 1, 2, "Caveat's regular and bold faces")
        XCTAssertTrue(svg.contains("font-family:'Caveat';font-weight:bold"))
        XCTAssertFalse(svg.contains("Patrick Hand"))
        XCTAssertTrue(Exporter.html(doc).contains("@font-face"))
    }

    func testAFontNameCannotBreakOutOfTheSVG() throws {
        var doc = DottieDocument()
        _ = try shape(&doc, font: #"Evil"/><script>alert(1)</script>"#)
        let svg = Exporter.svg(doc)
        XCTAssertFalse(svg.contains("<script"))
        XCTAssertTrue(svg.contains(#"font-family="'Evil/scriptalert(1)/script', Helvetica Neue"#))
    }

    func testACompiledDrawingCarriesTheFontsItUses() throws {
        var doc = DottieDocument()
        _ = try shape(&doc, font: nil)
        XCTAssertTrue(try Exporter.script(doc).contains("fonts = {}"))
        _ = try shape(&doc, font: "Architects Daughter")
        let js = try Exporter.script(doc)
        XCTAssertTrue(js.contains(#"fonts = {"Architects Daughter":{"regular":""#))
        XCTAssertFalse(js.contains(#""Caveat":"#))
    }

    func testAPacketTakesItsConnectorsFont() throws {
        var doc = DottieDocument()
        let a = try shape(&doc, font: nil), b = try shape(&doc, font: nil)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id, look: DiagramOps.Look(font: "Caveat"))
        let dot = try doc.addPacket(along: c.id, at: 0, label: "POST /orders")
        XCTAssertEqual(dot.style.font, "Caveat")
    }
}
