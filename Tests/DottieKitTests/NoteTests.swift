import XCTest
import CoreGraphics
import CoreText
@testable import DottieKit

final class NoteTests: XCTestCase {
    func testGFMBlocksBecomeParagraphsWithMarkers() {
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
        let s = Note.attributed(md, fontSize: 16, color: RGBA.black.cgColor).string
        XCTAssertEqual(s, "Title\none\u{2028}two\n☐\ttodo\n☑\tdone\n◦\tchild\n3.\tthird\nquoted\n \ncode **not bold**",
                       "a single newline is a line break, as in GitHub comments")
        XCTAssertEqual(Note.attributed("#hashtag", fontSize: 16, color: RGBA.black.cgColor).string, "#hashtag")
    }

    func testTablesGetATabStopPerColumnAndAHeaderRule() {
        let s = Note.attributed("| a | b |\n|:-|-:|\n| 1 | **2** |", fontSize: 16, color: RGBA.black.cgColor, width: 300)
        XCTAssertEqual(s.string, "a\tb\n1\t2")
        XCTAssertNotNil(s.attribute(Note.tableRuleAttribute, at: 0, effectiveRange: nil))
        XCTAssertNil(s.attribute(Note.tableRuleAttribute, at: 4, effectiveRange: nil))
    }

    func testAWideTableShrinksToFitTheNote() {
        let md = "| a long header | another long header | third |\n|---|---|---|\n| 1 | 2 | 3 |"
        let s = Note.attributed(md, fontSize: 16, color: RGBA.black.cgColor, width: 150)
        let font = s.attribute(NSAttributedString.Key(kCTFontAttributeName as String), at: 0, effectiveRange: nil) as! CTFont
        XCTAssertLessThan(CTFontGetSize(font), 16)
    }

    func testBareURLsAreUnderlined() {
        let s = Note.attributed("see https://example.com now", fontSize: 16, color: RGBA.black.cgColor)
        let key = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
        XCTAssertNotNil(s.attribute(key, at: (s.string as NSString).range(of: "example").location, effectiveRange: nil))
        XCTAssertNil(s.attribute(key, at: 0, effectiveRange: nil))
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

    func testSVGPutsEachTableCellAtItsOwnX() throws {
        var doc = DottieDocument()
        doc.elements = [Element(kind: .note, frame: CGRect(x: 0, y: 0, width: 300, height: 200),
                                style: Note.style(from: Style()), layerID: doc.layers[0].id,
                                text: "| a | b | c |\n|---|---|---|\n| one | two | three |")]
        let svg = Exporter.svg(doc)
        func x(of cell: String) throws -> Double {
            let r = try XCTUnwrap(svg.range(of: #"x="([0-9.]+)"[^>]*>"# + cell + "</tspan>", options: .regularExpression))
            let m = String(svg[r])
            return try XCTUnwrap(Double(m.dropFirst(3).prefix { $0 != "\"" }))
        }
        let xs = try ["one", "two", "three"].map(x)
        XCTAssertEqual(xs, xs.sorted())
        XCTAssertEqual(Set(xs).count, 3, "cells in the same style are still placed separately")
        XCTAssertEqual(try x(of: "a"), xs[0], accuracy: 0.5)
        XCTAssertFalse(svg.contains("\u{2028}"))
    }

    func testTogglingACheckboxFlipsOnlyThatLine() {
        let md = "# Todo\n- [ ] one\n- [x] two\n> 1. [ ] quoted\n- [ ] link [x](y)"
        XCTAssertEqual(Note.togglingCheckbox(line: 2, in: md), "# Todo\n- [x] one\n- [x] two\n> 1. [ ] quoted\n- [ ] link [x](y)")
        XCTAssertEqual(Note.togglingCheckbox(line: 3, in: md), "# Todo\n- [ ] one\n- [ ] two\n> 1. [ ] quoted\n- [ ] link [x](y)")
        XCTAssertEqual(Note.togglingCheckbox(line: 4, in: md), "# Todo\n- [ ] one\n- [x] two\n> 1. [x] quoted\n- [ ] link [x](y)")
        XCTAssertEqual(Note.togglingCheckbox(line: 1, in: md), md, "not a task")
        XCTAssertEqual(Note.togglingCheckbox(line: 9, in: md), md)
    }

    func testCheckboxHitIsTheBoxNotTheItemText() throws {
        let e = Element(kind: .note, frame: CGRect(x: 100, y: 50, width: 240, height: 200), style: Note.style(from: Style()),
                        layerID: UUID(), text: "Intro\n\n- [ ] first\n- [x] second")
        let rect = Note.textRect(e.frame)
        let (_, frame) = Note.layout(e.text!, in: rect, fontSize: e.style.fontSize, color: e.style.stroke.cgColor)
        let lines = Note.lines(of: frame, in: rect)
        XCTAssertEqual(lines.count, 3)
        let box = CGPoint(x: rect.minX + 5, y: lines[1].origin.y - 5)
        XCTAssertEqual(Note.checkboxLine(at: box, in: e), 3)
        XCTAssertEqual(Note.checkboxLine(at: CGPoint(x: rect.minX + 5, y: lines[2].origin.y - 5), in: e), 4)
        XCTAssertNil(Note.checkboxLine(at: CGPoint(x: rect.minX + 120, y: lines[1].origin.y - 5), in: e), "the item's text")
        XCTAssertNil(Note.checkboxLine(at: CGPoint(x: rect.minX + 5, y: lines[0].origin.y - 5), in: e), "a plain paragraph")
    }

    func testNoteColorsKeepDarkInk() {
        for (_, fill) in Note.colors {
            var s = Note.style(from: Style()); s.fill = fill
            let e = Element(kind: .note, frame: .zero, style: s, layerID: UUID())
            XCTAssertEqual(e.resolvingInk(to: .inkOnDark).style.stroke, .black)
        }
    }
}
