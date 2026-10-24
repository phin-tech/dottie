import XCTest
@testable import DottieKit

/// A shape's or connector's label has its own color, which follows the stroke until set, as in Excalidraw.
final class TextColorTests: XCTestCase {
    let red = RGBA(r: 0.8, g: 0.1, b: 0.1), blue = RGBA(r: 0.1, g: 0.3, b: 0.85)

    func testLabelFollowsStrokeUntilSetAndTextBoxesIgnoreIt() {
        var e = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 50), layerID: UUID(), text: "A")
        e.style.stroke = red
        XCTAssertEqual(e.labelColor, red)
        e.style.textColor = blue
        XCTAssertEqual(e.labelColor, blue)
        for kind in [ElementKind.text, .note] {
            var t = e
            t.kind = kind
            XCTAssertEqual(t.labelColor, red)
        }
    }

    func testNewTextBoxesTakeTheTextColorForNewShapes() {
        var st = Style()
        st.stroke = red
        XCTAssertEqual(st.forTextBox.stroke, red)
        st.textColor = blue
        XCTAssertEqual(st.forTextBox.stroke, blue)
        XCTAssertNil(st.forTextBox.textColor)
    }

    func testAutomaticInkLabelResolvesWithItsFill() {
        var e = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 50), layerID: UUID(), text: "A")
        e.style.stroke = red
        e.style.textColor = .black
        XCTAssertEqual(e.resolvingInk(to: .inkOnDark).style.textColor, .inkOnDark)
        XCTAssertEqual(e.resolvingInk(to: .inkOnDark).style.stroke, red)
        e.style.fill = RGBA(r: 1, g: 0.91, b: 0.52)
        XCTAssertEqual(e.resolvingInk(to: .inkOnDark).style.textColor, .black) // a light ink is unreadable on a light fill
    }

    func testTextColorRoundTripsAndIsAbsentByDefault() throws {
        var doc = DottieDocument()
        var e = Element(kind: .ellipse, frame: CGRect(x: 0, y: 0, width: 80, height: 40), layerID: doc.layers[0].id, text: "A")
        doc.elements = [e]
        XCTAssertFalse(String(decoding: try doc.encoded(), as: UTF8.self).contains("textColor"))
        e.style.textColor = blue
        doc.elements = [e]
        XCTAssertEqual(try DottieDocument.decode(doc.encoded()).elements[0].style.textColor, blue)
    }

    func testStrokeRecolorsTheLabelUnlessTheLookSetsItsOwn() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addShape(&doc, kind: .rectangle, frame: nil, at: .zero, text: "A", fill: nil, stroke: nil,
                                        roughness: nil, look: .init(textColor: blue))
        XCTAssertEqual(doc.elements[0].style.textColor, blue)
        try DiagramOps.update(&doc, id: e.id, stroke: red)
        XCTAssertNil(doc.elements[0].style.textColor)
        try DiagramOps.update(&doc, id: e.id, stroke: red, look: .init(textColor: blue))
        XCTAssertEqual(doc.elements[0].style.textColor, blue)
        try DiagramOps.update(&doc, id: e.id, look: .init(textColor: .some(nil)))
        XCTAssertNil(doc.elements[0].style.textColor)
        let t = try DiagramOps.addShape(&doc, kind: .text, frame: nil, at: .zero, text: "T", fill: nil, stroke: nil,
                                        roughness: nil, look: .init(textColor: blue))
        XCTAssertNil(doc.elements.first { $0.id == t.id }?.style.textColor)
    }

    func testScriptsSetAndReportTextColor() {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const a = dottie.rect({x: 0, y: 0, text: "A", textColor: "#1a4dd9"});
            const cleared = dottie.update(a.id, {textColor: ""});
            return [a.textColor, cleared.textColor === undefined];
            """, on: &doc, selection: [], libraries: [.starter], timeLimit: 5)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, ##"["#1a4dd9",true]"##)
        XCTAssertNil(doc.elements[0].style.textColor)
    }

    func testExcalidrawLabelKeepsItsOwnColor() throws {
        let scene = """
        {"type":"excalidraw","version":2,"elements":[
          {"id":"a","type":"rectangle","x":0,"y":0,"width":100,"height":50,"strokeColor":"#e03131","backgroundColor":"transparent"},
          {"id":"t","type":"text","x":10,"y":10,"width":50,"height":20,"text":"Hi","containerId":"a","strokeColor":"#1e1e1e"},
          {"id":"b","type":"rectangle","x":200,"y":0,"width":100,"height":50,"strokeColor":"#e03131","backgroundColor":"transparent"},
          {"id":"u","type":"text","x":210,"y":10,"width":50,"height":20,"text":"Same","containerId":"b","strokeColor":"#e03131"}
        ]}
        """
        let els = try ExcalidrawImporter.importItems(from: Data(scene.utf8), layerID: UUID())[0].elements
        XCTAssertEqual(els[0].style.textColor, .black)
        XCTAssertNil(els[1].style.textColor) // the same color as the stroke: it just follows it
    }
}
