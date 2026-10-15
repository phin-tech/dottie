import XCTest
import CoreGraphics
@testable import DottieKit

final class MermaidExportTests: XCTestCase {
    /// A comparable picture of a parsed diagram: node text and kind, and edges by node text.
    struct Graph: Equatable {
        var nodes: [String]
        var edges: [String]
        init(_ d: MermaidImporter.Diagram) {
            let text = Dictionary(uniqueKeysWithValues: d.nodes.map { ($0.key, $0.text) })
            nodes = d.nodes.map { "\($0.text)|\($0.kind.rawValue)|\($0.fill.map { "\(Int($0.r * 255))" } ?? "-")" }.sorted()
            edges = d.edges.map { e in
                "\(text[e.from]!)->\(text[e.to]!) arrow=\(e.arrow) label=\(e.label ?? "") dash=\(e.look.dash?.rawValue ?? "-") "
                    + "w=\(e.look.strokeWidth ?? 0) start=\(e.look.startHead?.rawValue ?? "-") end=\(e.look.endHead?.rawValue ?? "-")"
            }.sorted()
        }
    }

    func testRoundTrip() throws {
        let source = """
        flowchart LR
          A([Start]) -->|go| B{Is it "ok"?}
          B -- no --> C["Fix #lt;it#gt;<br>then retry"]
          C -.-> B
          B ==> D((Done))
          D <--> E[Log #1 | 50% & more]
          E --o F[Dot]
          E --x G[Bar]
          E --- H[Plain]
          H -->|"retry; 50%% off"| A
          style H fill:#ccddee
        """
        let first = try MermaidImporter.parse(source)
        var doc = DottieDocument()
        try DiagramOps.build(&doc, nodes: first.nodes, edges: first.edges, direction: first.direction)
        let text = Exporter.mermaid(doc)
        let second = try MermaidImporter.parse(text)
        XCTAssertEqual(Graph(second), Graph(first), text)
        XCTAssertEqual(second.direction, .leftToRight, text)
        XCTAssertTrue(text.contains("B{\"Is it #quot;ok#quot;?\"}") || text.contains("{\"Is it #quot;ok#quot;?\"}"), text)
        XCTAssertTrue(text.contains("Fix #lt;it#gt;<br>then retry"), text)
    }

    func testShapesIdsAndDirection() throws {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        var a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 50), layerID: layer, text: "A")
        a.anchor = "start"
        let b = Element(kind: .ellipse, frame: CGRect(x: 0, y: 200, width: 80, height: 80), layerID: layer, text: "B")
        let c = Element(kind: .diamond, frame: CGRect(x: 0, y: 400, width: 100, height: 80), layerID: layer, text: nil)
        var d = Element(kind: .note, frame: CGRect(x: 200, y: 0, width: 100, height: 100), layerID: layer, text: "# Note")
        d.anchor = "not valid!"
        let pen = Element(kind: .freehand, frame: CGRect(x: 0, y: 0, width: 10, height: 10), layerID: layer)
        doc.elements = [a, b, c, d, pen]
        doc.elements.append(Element(kind: .connector, frame: .zero, layerID: layer,
                                    connector: ConnectorData(start: .bound(a.id), end: .bound(b.id))))
        doc.elements.append(Element(kind: .connector, frame: .zero, layerID: layer,
                                    connector: ConnectorData(start: .bound(b.id), end: .bound(c.id), endArrow: false)))
        doc.elements.append(Element(kind: .connector, frame: .zero, layerID: layer,
                                    connector: ConnectorData(start: .bound(c.id), end: .free(CGPoint(x: 5, y: 5)))))
        doc.elements.append(Element(kind: .connector, frame: .zero, layerID: layer,
                                    connector: ConnectorData(start: .bound(c.id), end: .bound(pen.id))))
        let text = Exporter.mermaid(doc)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines[0], "flowchart TD")
        XCTAssertEqual(lines[1], "%% Skipped 1 shape (freehand, paths, ...) and 2 connectors not attached at both ends")
        XCTAssertTrue(lines.contains("start[\"A\"]"), text)
        XCTAssertTrue(lines.contains("n1((\"B\"))"), text)
        XCTAssertTrue(lines.contains("n2{\" \"}") || lines.contains("n2{\"\"}"), text)
        XCTAssertTrue(lines.contains("n3[\"# Note\"]") || lines.contains("n3[\"#35; Note\"]"), text)
        XCTAssertTrue(lines.contains("start --> n1"), text)
        XCTAssertTrue(lines.contains("n1 --- n2"), text)
        XCTAssertNoThrow(try MermaidImporter.parse(text))
    }

    func testLeftToRightGuessAndReversedHead() throws {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        let a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 50), layerID: layer, text: "A")
        let b = Element(kind: .rectangle, frame: CGRect(x: 300, y: 0, width: 100, height: 50), layerID: layer, text: "B")
        var data = ConnectorData(start: .bound(a.id), end: .bound(b.id), endArrow: false)
        data.startHead = .arrow
        doc.elements = [a, b, Element(kind: .connector, frame: .zero, layerID: layer, connector: data)]
        let text = Exporter.mermaid(doc)
        XCTAssertTrue(text.hasPrefix("flowchart LR\n"), text)
        XCTAssertTrue(text.contains("n2 --> n1"), "a head only at the start becomes a link the other way\n" + text)
    }

    func testEmptyLabelRoundTripsAsEmpty() throws {
        var doc = DottieDocument()
        doc.elements = [Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 50), layerID: doc.layers[0].id)]
        let d = try MermaidImporter.parse(Exporter.mermaid(doc))
        XCTAssertEqual(d.nodes.map(\.text), [""])
    }
}
