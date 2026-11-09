import XCTest
@testable import DottieKit

/// Palette colors by name (ADR 0005): given by name they follow the palette, given by hand they stop.
final class PaletteTests: XCTestCase {
    private func page() throws -> (DottieDocument, UUID) {
        var doc = DottieDocument()
        doc.theme = "paper"
        let e = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 50), at: .zero,
                                        text: "A", fill: nil, stroke: nil, roughness: 0)
        return (doc, e.id)
    }
    private func style(_ doc: DottieDocument, _ id: UUID) -> Style { doc.elements.first { $0.id == id }!.style }

    func testNamesParseAgainstThePagesPalette() {
        var doc = DottieDocument()
        doc.theme = "midnight"
        XCTAssertEqual(RGBA.parse("Accent", in: doc)?.name, "accent")
        XCTAssertEqual(RGBA.parse("accent", in: doc)?.color, RGBA(hex: "#93c5fd"))
        XCTAssertEqual(RGBA.parse("#ff0000", in: doc)?.name, nil)
        XCTAssertNil(RGBA.parse("nope", in: doc))
        XCTAssertTrue(RGBA.expected(in: doc).contains("accent, muted, danger"))
    }

    func testANamedColorFollowsThemeAndPaletteChanges() throws {
        var (doc, id) = try page()
        try DiagramOps.nameColors(&doc, id: id, fill: "accent", stroke: "danger", textColor: nil)
        XCTAssertEqual(style(doc, id).fill, RGBA(hex: "#2563eb"))
        XCTAssertEqual(style(doc, id).named, ColorNames(fill: "accent", stroke: "danger"))
        try DiagramOps.setTheme(&doc, id: "blueprint")
        XCTAssertEqual(style(doc, id).fill, RGBA(hex: "#93c5fd"), "a dark theme's accent")
        try DiagramOps.setPaletteColor(&doc, name: "accent", color: RGBA(hex: "#7c3aed")!)
        XCTAssertEqual(doc.customTheme?.base, "blueprint", "editing a built-in's palette makes it the page's own")
        XCTAssertEqual(style(doc, id).fill, RGBA(hex: "#7c3aed"))
        XCTAssertEqual(style(doc, id).stroke, RGBA(hex: "#fca5a5"))
        // A hex color drops the name.
        try DiagramOps.nameColors(&doc, id: id, fill: "#00ff00", stroke: nil, textColor: nil)
        XCTAssertEqual(style(doc, id).named, ColorNames(stroke: "danger"))
        XCTAssertThrowsError(try DiagramOps.nameColors(&doc, id: id, fill: "nope", stroke: nil, textColor: nil))
    }

    func testAColorChangedByHandStopsFollowingThePalette() throws {
        var (doc, id) = try page()
        try DiagramOps.nameColors(&doc, id: id, fill: "accent", stroke: "accent", textColor: nil)
        let before = doc
        var edited = doc
        edited.elements[0].style.fill = RGBA(hex: "#123456")!
        edited.elements[0].x = 40
        let after = edited.reconcilingColorNames(from: before)
        XCTAssertEqual(style(after, id).named, ColorNames(stroke: "accent"), "the stroke wasn't touched, so it stays named")
        XCTAssertEqual(style(after, id).fill, RGBA(hex: "#123456"))
        // Changing the theme now recolors only the stroke.
        var themed = after
        themed.theme = "midnight"
        let resolved = themed.reconcilingColorNames(from: after)
        XCTAssertEqual(style(resolved, id).fill, RGBA(hex: "#123456"))
        XCTAssertEqual(style(resolved, id).stroke, RGBA(hex: "#93c5fd"))
    }

    func testReadingAFileResolvesNamesAgainstItsPalette() throws {
        var (doc, id) = try page()
        try DiagramOps.nameColors(&doc, id: id, fill: "danger", stroke: nil, textColor: nil)
        var file = DottieFile(pages: [doc])
        file.pages[0].elements[0].style.fill = RGBA(r: 0.5, g: 0.5, b: 0.5)   // as if edited by hand in the JSON
        let back = try DottieFile.decode(try file.encoded())
        XCTAssertEqual(back.pages[0].elements[0].style.fill, RGBA(hex: "#dc2626"))
        XCTAssertEqual(back.pages[0].elements[0].style.named?.fill, "danger")
    }

    func testScriptsTakePaletteNamesAndSetTheTheme() {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const a = dottie.rect({x: 0, y: 0, text: "A", fill: "accent"});
            const t = dottie.theme({theme: "sepia", palette: {accent: "#7c3aed", brand: "#0f766e"}});
            const b = dottie.rect({x: 200, y: 0, text: "B", fill: "brand", stroke: "#000000"});
            return [dottie.get(a.id).fill, t.theme, t.palette.brand, b.fill];
            """, on: &doc, libraries: [.starter])
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.value, ##"["#7c3aed","custom","#0f766e","#0f766e"]"##)
        XCTAssertEqual(doc.customTheme?.base, "sepia")
        XCTAssertEqual(doc.elements[1].style.named, ColorNames(fill: "brand"))
    }
}
