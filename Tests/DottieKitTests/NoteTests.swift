import XCTest
import CoreGraphics
import CoreText
@testable import DottieKit

final class NoteTests: XCTestCase {
    func testBlocks() {
        let md = """
        # Title
        one
        two

        - [ ] todo
        - [x] done
          - child
        3. third
        > quoted
        ---
        ```
        code **not bold**
        ```
        """
        XCTAssertEqual(Note.blocks(md), [
            .heading(level: 1, text: "Title"),
            .paragraph("one two"),
            .item(depth: 0, marker: "☐", text: "todo"),
            .item(depth: 0, marker: "☑", text: "done"),
            .item(depth: 1, marker: "◦", text: "child"),
            .item(depth: 0, marker: "3.", text: "third"),
            .quote("quoted"),
            .rule,
            .code("code **not bold**"),
        ])
        XCTAssertEqual(Note.blocks("#hashtag"), [.paragraph("#hashtag")]) // not a heading without the space
    }

    func testInlineStylesBecomeFontTraits() {
        let s = Note.attributed("plain **bold** *it* `code` ~~gone~~", fontSize: 16, color: RGBA.black.cgColor)
        func traits(of word: String) -> CTFontSymbolicTraits {
            let r = (s.string as NSString).range(of: word)
            let font = s.attribute(NSAttributedString.Key(kCTFontAttributeName as String), at: r.location, effectiveRange: nil) as! CTFont
            return CTFontGetSymbolicTraits(font)
        }
        XCTAssertEqual(s.string, "plain bold it code gone")
        XCTAssertFalse(traits(of: "plain").contains(.traitBold))
        XCTAssertTrue(traits(of: "bold").contains(.traitBold))
        XCTAssertTrue(traits(of: "it").contains(.traitItalic))
        XCTAssertTrue(traits(of: "code").contains(.traitMonoSpace))
        let gone = (s.string as NSString).range(of: "gone")
        XCTAssertNotNil(s.attribute(Note.strikeAttribute, at: gone.location, effectiveRange: nil))
    }

    func testBlocksAreSeparateParagraphsWithMarkers() {
        let s = Note.attributed("## Head\n- a\n- b", fontSize: 16, color: RGBA.black.cgColor)
        XCTAssertEqual(s.string, "Head\n•\ta\n•\tb")
    }

    func testTextIsCutOffAtTheNotesEdge() {
        let long = (1...60).map { "Line \($0)" }.joined(separator: "\n\n")
        let rect = Note.textRect(CGRect(x: 0, y: 0, width: 200, height: 160))
        let (_, frame) = Note.layout(long, in: rect, fontSize: 16, color: RGBA.black.cgColor)
        let lines = Note.lines(of: frame, in: rect)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertLessThan(lines.count, 60)
        XCTAssertTrue(lines.allSatisfy { rect.minY < $0.origin.y && $0.origin.y <= rect.maxY })
    }

    func testAddShapeGivesANoteItsLookAndItRoundTrips() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addShape(&doc, kind: .note, frame: nil, at: .zero, text: "# Hi", fill: nil, stroke: nil, roughness: nil)
        XCTAssertEqual(e.style.fill, Note.defaultFill)
        XCTAssertGreaterThanOrEqual(e.width, 200)
        let back = try DottieFile.decode(DottieFile(pages: [doc]).encoded())
        XCTAssertEqual(back.pages[0].elements[0].kind, .note)
        XCTAssertEqual(back.pages[0].elements[0].text, "# Hi")
    }

    func testNoteStaysDarkInkOnDarkCanvas() {
        var doc = DottieDocument()
        doc.elements = [Element(kind: .note, frame: CGRect(x: 0, y: 0, width: 200, height: 160),
                                style: Note.style(from: Style()), layerID: doc.layers[0].id, text: "x")]
        XCTAssertEqual(doc.resolvingInk(to: .inkOnDark).elements[0].style.stroke, .black)
    }

    func testSVGExportsStyledRuns() {
        var doc = DottieDocument()
        doc.elements = [Element(kind: .note, frame: CGRect(x: 0, y: 0, width: 240, height: 200),
                                style: Note.style(from: Style()), layerID: doc.layers[0].id,
                                text: "# Title\nSome **bold** & `code`\n\n- [ ] ~~task~~")]
        let svg = Exporter.svg(doc)
        XCTAssertTrue(svg.contains("font-weight=\"bold\">Title</tspan>"))
        XCTAssertTrue(svg.contains("font-weight=\"bold\">bold</tspan>"))
        XCTAssertTrue(svg.contains("&amp;"))
        XCTAssertTrue(svg.contains("monospace\">code</tspan>"))
        XCTAssertTrue(svg.contains(">☐</tspan>"))
        XCTAssertTrue(svg.contains("<line "), "strikethrough is drawn as a line")
        XCTAssertTrue(svg.contains("fill=\"#ffe885\""))
    }
}
