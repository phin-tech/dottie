import XCTest
import CoreGraphics
@testable import DottieKit

final class MermaidImportTests: XCTestCase {
    func parse(_ text: String) throws -> MermaidImporter.Diagram { try MermaidImporter.parse(text) }

    func node(_ d: MermaidImporter.Diagram, _ key: String) -> DiagramOps.NodeSpec? { d.nodes.first { $0.key == key } }

    func pairs(_ d: MermaidImporter.Diagram) -> [String] { d.edges.map { "\($0.from)>\($0.to)" } }

    func testHeaderAndDirection() throws {
        XCTAssertEqual(try parse("flowchart LR\nA-->B").direction, .leftToRight)
        XCTAssertEqual(try parse("graph TD\nA-->B").direction, .topToBottom)
        XCTAssertEqual(try parse("graph TB\nA-->B").direction, .topToBottom)
        XCTAssertEqual(try parse("graph\nA-->B").direction, .topToBottom)
        let bt = try parse("flowchart BT\nA-->B")
        XCTAssertEqual(bt.direction, .topToBottom)
        XCTAssertFalse(bt.notes.isEmpty)
        XCTAssertEqual(try parse("graph RL; A-->B").direction, .leftToRight)
    }

    func testShapes() throws {
        let d = try parse("""
        flowchart TD
            A[Rect] --> B(Rounded)
            C([Stadium]) --> D((Circle))
            E{Decide} --> F>Flag]
            G[[Sub]] --> H[(DB)]
            I{{Hex}} --> J[/Para/]
            K[\\Alt\\] --> L[/Trap\\]
            M(((Double))) --> N
        """)
        let kinds = Dictionary(uniqueKeysWithValues: d.nodes.map { ($0.key, $0.kind) })
        XCTAssertEqual(kinds["A"], .rectangle)
        XCTAssertEqual(kinds["B"], .rectangle)
        XCTAssertEqual(kinds["C"], .ellipse)
        XCTAssertEqual(kinds["D"], .ellipse)
        XCTAssertEqual(kinds["E"], .diamond)
        XCTAssertEqual(kinds["F"], .rectangle)
        XCTAssertEqual(kinds["H"], .rectangle)
        XCTAssertEqual(kinds["M"], .ellipse)
        let texts = Dictionary(uniqueKeysWithValues: d.nodes.map { ($0.key, $0.text) })
        XCTAssertEqual(texts["A"], "Rect")
        XCTAssertEqual(texts["C"], "Stadium")
        XCTAssertEqual(texts["D"], "Circle")
        XCTAssertEqual(texts["F"], "Flag")
        XCTAssertEqual(texts["G"], "Sub")
        XCTAssertEqual(texts["H"], "DB")
        XCTAssertEqual(texts["I"], "Hex")
        XCTAssertEqual(texts["J"], "Para")
        XCTAssertEqual(texts["K"], "Alt")
        XCTAssertEqual(texts["L"], "Trap")
        XCTAssertEqual(texts["M"], "Double")
        XCTAssertEqual(texts["N"], "N")
        XCTAssertEqual(d.nodes.map(\.key), ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N"])
    }

    func testQuotedLabelsAndLineBreaks() throws {
        let d = try parse("""
        graph TD
          A["Hello [world] --> (x)"] --> B["two<br>lines<br/>three"]
          C["say #quot;hi#quot; &amp; bye"]
          D[<b>bold</b> text]
        """)
        XCTAssertEqual(node(d, "A")?.text, "Hello [world] --> (x)")
        XCTAssertEqual(node(d, "B")?.text, "two\nlines\nthree")
        XCTAssertEqual(node(d, "C")?.text, "say \"hi\" & bye")
        XCTAssertEqual(node(d, "D")?.text, "bold text")
        XCTAssertEqual(pairs(d), ["A>B"])
    }

    func testLaterDefinitionUpdatesNode() throws {
        let d = try parse("flowchart TD\nA --> B\nB{Decide}")
        XCTAssertEqual(d.nodes.count, 2)
        XCTAssertEqual(node(d, "B")?.kind, .diamond)
        XCTAssertEqual(node(d, "B")?.text, "Decide")
    }

    func testLinkKinds() throws {
        let d = try parse("""
        flowchart LR
          A --> B
          A --- C
          A -.-> D
          A ==> E
          A <--> F
          A --o G
          A --x H
          A ---> I
          A -.- J
          A === K
          A ~~~ L
          A <-.-> M
        """)
        let e = Dictionary(uniqueKeysWithValues: d.edges.map { ($0.to, $0) })
        XCTAssertEqual(e["B"]?.arrow, true)
        XCTAssertNil(e["B"]?.look.dash)
        XCTAssertEqual(e["C"]?.arrow, false)
        XCTAssertEqual(e["D"]?.arrow, true)
        XCTAssertEqual(e["D"]?.look.dash, .dashed)
        XCTAssertEqual(e["E"]?.arrow, true)
        XCTAssertEqual(e["E"]?.look.strokeWidth, 4)
        XCTAssertEqual(e["F"]?.arrow, true)
        XCTAssertEqual(e["F"]?.look.startHead, .arrow)
        XCTAssertEqual(e["G"]?.look.endHead, .dot)
        XCTAssertEqual(e["H"]?.look.endHead, .bar)
        XCTAssertEqual(e["I"]?.arrow, true)
        XCTAssertEqual(e["J"]?.arrow, false)
        XCTAssertEqual(e["J"]?.look.dash, .dashed)
        XCTAssertEqual(e["K"]?.arrow, false)
        XCTAssertEqual(e["K"]?.look.strokeWidth, 4)
        XCTAssertNil(e["L"], "invisible links are not drawn")
        XCTAssertNotNil(node(d, "L"), "but their nodes are")
        XCTAssertEqual(e["M"]?.look.startHead, .arrow)
        XCTAssertEqual(e["M"]?.look.dash, .dashed)
    }

    func testLinkLabels() throws {
        let d = try parse("""
        flowchart TD
          A -->|yes| B
          A -- no --> C
          A -. maybe .-> D
          A == sure ==> E
          A ---|plain| F
          A -->|"quoted | text"| G
          A -- line --- H
        """)
        let labels = Dictionary(uniqueKeysWithValues: d.edges.map { ($0.to, $0.label ?? "") })
        XCTAssertEqual(labels["B"], "yes")
        XCTAssertEqual(labels["C"], "no")
        XCTAssertEqual(labels["D"], "maybe")
        XCTAssertEqual(labels["E"], "sure")
        XCTAssertEqual(labels["F"], "plain")
        XCTAssertEqual(labels["H"], "line")
        XCTAssertEqual(labels["G"], "quoted | text")
        let e = Dictionary(uniqueKeysWithValues: d.edges.map { ($0.to, $0) })
        XCTAssertEqual(e["D"]?.look.dash, .dashed)
        XCTAssertEqual(e["E"]?.look.strokeWidth, 4)
        XCTAssertEqual(e["H"]?.arrow, false)
        XCTAssertEqual(e["C"]?.arrow, true)
    }

    func testChainsFanOutAndSemicolons() throws {
        XCTAssertEqual(pairs(try parse("graph LR; A --> B --> C; C-->D")), ["A>B", "B>C", "C>D"])
        XCTAssertEqual(pairs(try parse("flowchart TD\nA & B --> C & D")), ["A>C", "A>D", "B>C", "B>D"])
        XCTAssertEqual(pairs(try parse("flowchart TD\nA --> B & C --> D")), ["A>B", "A>C", "B>D", "C>D"])
        XCTAssertEqual(pairs(try parse("flowchart TD\nA[x]-->B[y]-->|z|C")), ["A>B", "B>C"])
    }

    func testCommentsAndIgnoredLines() throws {
        let d = try parse("""
        ---
        title: Example
        ---
        %%{init: {"theme": "dark"}}%%
        ```mermaid
        flowchart TD
          %% a comment
          A --> B %% trailing
          classDef hot fill:#f96,stroke:#333
          class B hot
          C:::hot --> A
          style A fill:#ccddee,stroke-width:4px
          style C stroke:red
          linkStyle 0 stroke:#ff3
          click A "https://example.com"
          accTitle: hidden
        ```
        """)
        XCTAssertEqual(d.nodes.map(\.key), ["A", "B", "C"])
        XCTAssertEqual(node(d, "A")?.fill, RGBA(hex: "#ccddee"))
        XCTAssertEqual(node(d, "B")?.fill, RGBA(hex: "#f96"))
        XCTAssertEqual(node(d, "C")?.fill, RGBA(hex: "#f96"))
        XCTAssertEqual(pairs(d), ["A>B", "C>A"])
    }

    func testSubgraphsAreFlattened() throws {
        let d = try parse("""
        flowchart TB
          c1-->a2
          subgraph one [First]
            direction LR
            a1-->a2
          end
          subgraph two
            b1-->b2
          end
          one --> two
        """)
        XCTAssertEqual(Set(d.nodes.map(\.key)), ["c1", "a2", "a1", "b1", "b2", "one", "two"])
        XCTAssertEqual(node(d, "one")?.text, "First")
        XCTAssertEqual(node(d, "two")?.text, "two")
        XCTAssertTrue(d.notes.contains { $0.contains("Flattened 2 subgraphs") })
        XCTAssertEqual(d.direction, .topToBottom)
    }

    func testHyphenatedIdsAndExpandedShapes() throws {
        let d = try parse("flowchart TD\nmy-node-->other.node\nX@{ shape: circle, label: \"Start\" }\nY@{ shape: diam }")
        XCTAssertEqual(pairs(d), ["my-node>other.node"])
        XCTAssertEqual(node(d, "X")?.kind, .ellipse)
        XCTAssertEqual(node(d, "X")?.text, "Start")
        XCTAssertEqual(node(d, "Y")?.kind, .diamond)
    }

    func testErrors() {
        XCTAssertThrowsError(try parse("sequenceDiagram\nAlice->>Bob: hi")) { e in
            XCTAssertEqual(e as? MermaidError, .unsupportedDiagram("sequenceDiagram"))
            XCTAssertTrue("\(e)".contains("only imports flowcharts"))
        }
        XCTAssertThrowsError(try parse("classDiagram\nA <|-- B")) { XCTAssertEqual($0 as? MermaidError, .unsupportedDiagram("classDiagram")) }
        XCTAssertThrowsError(try parse("hello world")) { XCTAssertEqual($0 as? MermaidError, .notMermaid) }
        XCTAssertThrowsError(try parse("")) { XCTAssertEqual($0 as? MermaidError, .notMermaid) }
        XCTAssertThrowsError(try parse("flowchart TD")) { XCTAssertEqual($0 as? MermaidError, .empty) }
        XCTAssertThrowsError(try parse("flowchart TD\nA --> B\nC[oops --> D")) { e in
            guard case .syntax(let line, _) = e as? MermaidError else { return XCTFail("\(e)") }
            XCTAssertEqual(line, 3)
        }
        XCTAssertThrowsError(try parse("flowchart TD\nA -->")) { e in
            guard case .syntax(2, _) = e as? MermaidError else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try parse("flowchart XY\nA-->B"))
        XCTAssertThrowsError(try parse("flowchart TD\nsubgraph s\nA-->B"))
        XCTAssertThrowsError(try parse("flowchart TD\nend"))
        XCTAssertEqual((MermaidError.notMermaid as Error).localizedDescription, MermaidError.notMermaid.description)
    }

    func testIsFlowchart() {
        XCTAssertTrue(MermaidImporter.isFlowchart("flowchart LR\nA-->B"))
        XCTAssertTrue(MermaidImporter.isFlowchart("  graph TD;A-->B"))
        XCTAssertTrue(MermaidImporter.isFlowchart("%% hi\n```mermaid\ngraph\nA-->B\n```"))
        XCTAssertTrue(MermaidImporter.isFlowchart("---\ntitle: x\n---\nflowchart TD\nA"))
        XCTAssertFalse(MermaidImporter.isFlowchart("graphs are neat"))
        XCTAssertFalse(MermaidImporter.isFlowchart("sequenceDiagram\nA->>B: x"))
        XCTAssertFalse(MermaidImporter.isFlowchart("Some flowchart TD text"))
    }

    func testBuildLaysOutAndStylesConnectors() throws {
        var doc = DottieDocument()
        let r = try MermaidImporter.build(&doc, mermaid: """
        flowchart LR
          A[Start] -->|go| B{Check}
          B -.-> C((Done))
          B <==> A
        """, roughness: 0)
        XCTAssertEqual(r.ids.count, 3)
        let shapes = doc.elements.filter { $0.kind != .connector }
        let connectors = doc.elements.filter { $0.kind == .connector }
        XCTAssertEqual(shapes.count, 3)
        XCTAssertEqual(connectors.count, 3)
        XCTAssertTrue(doc.elements.allSatisfy { $0.style.roughness == 0 })
        let a = doc.elements.first { $0.id == r.ids["A"] }!, b = doc.elements.first { $0.id == r.ids["B"] }!
        XCTAssertLessThan(a.frame.maxX, b.frame.minX, "LR puts B to the right of A")
        XCTAssertEqual(b.kind, .diamond)
        XCTAssertEqual(connectors[0].text, "go")
        XCTAssertEqual(connectors[0].connector?.start.elementID, r.ids["A"])
        XCTAssertEqual(connectors[1].style.dash, .dashed)
        XCTAssertEqual(connectors[2].style.strokeWidth, 4)
        XCTAssertEqual(connectors[2].connector?.startHead, .arrow)
        XCTAssertEqual(connectors[2].connector?.endHead, .arrow)
    }

    func testLoopsLeaveFromTheSide() throws {
        var doc = DottieDocument()
        let r = try MermaidImporter.build(&doc, mermaid: "flowchart TD\nA-->B\nB-->|retry|A")
        let back = doc.elements.first { $0.connector?.start.elementID == r.ids["B"] }!
        XCTAssertEqual(back.connector?.start.port, .right)
        XCTAssertEqual(back.connector?.end.port, .right)
        let forward = doc.elements.first { $0.connector?.start.elementID == r.ids["A"] }!
        XCTAssertEqual(forward.connector?.start.port, .bottom)
    }

    func testElementsStartAtOrigin() throws {
        let r = try MermaidImporter.elements(from: "graph TD\nA-->B\nA-->C")
        XCTAssertEqual(r.elements.count, 5)
        let shapes = r.elements.filter { $0.kind != .connector }
        XCTAssertEqual(shapes.map(\.frame.minX).min() ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(shapes.map(\.frame.minY).min() ?? -1, 0, accuracy: 0.5)
        XCTAssertGreaterThan(r.size.width, 0)
        var doc = DottieDocument()
        let added = doc.insert(r.elements, size: r.size, center: CGPoint(x: 500, y: 500), layerID: doc.layers[0].id)
        XCTAssertEqual(added.count, 5)
        let ids = Set(doc.elements.map(\.id))
        for c in doc.elements where c.kind == .connector {
            XCTAssertTrue(ids.contains(c.connector!.start.elementID!), "connector bindings follow the new ids")
        }
    }
}
