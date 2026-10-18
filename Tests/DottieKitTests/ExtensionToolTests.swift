import XCTest
@testable import DottieKit

/// Drawing tools from extensions: `extension.tool`, `draw`, and turning what it returns into plain elements.
@MainActor
final class ExtensionToolTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ext-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func runtime(_ main: String) throws -> ExtensionRuntime {
        let dir = root.appendingPathComponent("Tools.dottieext", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"id":"com.example.tools","name":"Tools","version":"1.0.0","dottieApi":1}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try main.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        return try ExtensionRuntime(bundle: dir)
    }

    /// A box from the press to the latest point, and a line along the drag once it is let go.
    private static let boxer = """
        extension.tool({
          id: "boxer", name: "Boxer", icon: "square.dashed",
          draw: function (g) {
            var a = g.points[0], b = g.points[g.points.length - 1];
            var out = [{ kind: "rectangle", x: Math.min(a.x, b.x), y: Math.min(a.y, b.y),
                         width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y), text: g.shift ? "shift" : undefined }];
            if (g.done) out.push({ kind: "path", stroke: "#ff0000", strokeWidth: 4,
                                   subpaths: [{ closed: false, coords: [a.x, a.y, a.x, a.y, b.x, b.y, b.x, b.y] }] });
            return { elements: out };
          }
        });
        """

    func testToolsAreDeclaredWithTheirNameAndIcon() throws {
        let rt = try runtime(Self.boxer)
        XCTAssertEqual(rt.tools, [ToolDefinition(id: "boxer", name: "Boxer", icon: "square.dashed")])
        XCTAssertTrue(rt.shapes.isEmpty)
        XCTAssertNil(try runtime(#"extension.tool({ id: "t", name: "T", draw: function () { return { elements: [] }; } })"#).tools[0].icon)
    }

    func testDrawSeesTheGestureSoFar() throws {
        let rt = try runtime(Self.boxer)
        let pts = [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 40), CGPoint(x: 110, y: 70)]
        let moving = try rt.draw(tool: "boxer", ToolGesture(points: pts, done: false, shift: true))
        XCTAssertEqual(moving.map(\.kind), ["rectangle"])
        XCTAssertEqual(moving[0].text, "shift")
        let done = try rt.draw(tool: "boxer", ToolGesture(points: pts, done: true))
        XCTAssertEqual(done.map(\.kind), ["rectangle", "path"])
        XCTAssertThrowsError(try rt.draw(tool: "nope", ToolGesture(points: pts, done: true))) {
            XCTAssertEqual($0 as? ExtensionError, .noSuchTool("nope"))
        }
    }

    func testDrawnElementsArePlainElementsInTheNewShapeStyle() throws {
        let rt = try runtime(Self.boxer)
        var style = Style(); style.stroke = RGBA(r: 0, g: 0, b: 1); style.roughness = 2
        let layer = UUID()
        let drawn = try rt.draw(tool: "boxer", ToolGesture(points: [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 70)], done: true))
        let elements = try DrawnElement.elements(drawn, style: style, layerID: layer, seed: 7)
        XCTAssertEqual(elements.map(\.kind), [.rectangle, .path])
        XCTAssertEqual(elements[0].frame, CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(elements[0].style, style, "nothing set, so the new shape style")
        XCTAssertEqual(elements.map(\.seed), [7, 8])
        XCTAssertEqual(elements[1].style.stroke, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(elements[1].style.strokeWidth, 4)
        XCTAssertEqual(elements[1].style.roughness, 2)
        // The path sits in its own bounds, normalized, like any other path.
        XCTAssertEqual(elements[1].frame.minX, 10, accuracy: 1e-9)
        XCTAssertEqual(elements[1].frame.maxY, 70, accuracy: 1e-9)
        XCTAssertTrue(elements.allSatisfy { $0.layerID == layer && $0.extension == nil })
    }

    func testColorsAndLooks() throws {
        var style = Style(); style.fillStyle = .hachure
        let d = try JSONDecoder().decode(DrawnElement.self, from: Data(#"""
            {"kind":"ellipse","x":0,"y":0,"width":10,"height":10,"fill":"#00ff0080","stroke":"none","fillStyle":"solid","roughness":0}
            """#.utf8))
        let e = try d.element(style: style, layerID: UUID(), seed: 1)
        XCTAssertEqual(e.style.fill, RGBA(r: 0, g: 1, b: 0, a: 128.0 / 255))
        XCTAssertEqual(e.style.stroke, .clear)
        XCTAssertEqual(e.style.fillStyle, .solid)
        XCTAssertEqual(e.style.roughness, 0)
    }

    func testBadOutputIsRefusedAndTheRuntimeRecovers() throws {
        let rt = try runtime("""
            extension.tool({ id: "bad", name: "Bad", draw: function (g) {
              if (g.points.length === 1) throw new Error("boom");
              if (g.points.length === 2) return { elements: [{ kind: "star", x: 0, y: 0, width: 1, height: 1 }] };
              if (g.points.length === 3) return { elements: [{ kind: "path", subpaths: [{ closed: true, coords: [0, 0, 1] }] }] };
              if (g.points.length === 4) return { elements: [{ kind: "rectangle", x: 0, y: 0, width: 1, height: 1, fill: "blue" }] };
              if (g.points.length === 5) return [1, 2];
              return { elements: [{ kind: "rectangle", x: 0, y: 0, width: 5, height: 5 }] };
            } });
            """)
        func attempt(_ n: Int) throws -> [Element] {
            let pts = (0..<n).map { CGPoint(x: $0, y: $0) }
            return try DrawnElement.elements(try rt.draw(tool: "bad", ToolGesture(points: pts, done: true)), style: Style(), layerID: UUID(), seed: 1)
        }
        for (n, says) in [(1, "boom"), (2, "kind must be"), (3, "2 + 6n"), (4, "hex color"), (5, "elements")] {
            XCTAssertThrowsError(try attempt(n), "\(n)") { XCTAssertTrue("\($0)".contains(says), "\($0)") }
        }
        XCTAssertEqual(try attempt(6).count, 1, "a failure doesn't break the next call")
    }

    func testOutputTooFarOrTooBigIsRefusedRatherThanDrawn() throws {
        func drawn(_ json: String) throws -> DrawnElement { try JSONDecoder().decode(DrawnElement.self, from: Data(json.utf8)) }
        let refused = [
            // Finite but huge: flattening this would overflow, and a fill this big would never finish.
            #"{"kind":"path","subpaths":[{"closed":false,"coords":[-1.7e308,0,0,0,0,0,1.7e308,0]}]}"#,
            #"{"kind":"path","subpaths":[{"closed":false,"coords":[0,0,10000,0,20000,0,30000,0]}]}"#,
            #"{"kind":"rectangle","x":0,"y":1e17,"width":100,"height":1e17,"fillStyle":"hachure"}"#,
            #"{"kind":"rectangle","x":0,"y":0,"width":100,"height":40000000}"#,
            #"{"kind":"ellipse","x":200000,"y":0,"width":10,"height":10}"#,
            #"{"kind":"rectangle","x":0,"y":0,"width":10,"height":10,"strokeWidth":25}"#,
            "{\"kind\":\"rectangle\",\"x\":0,\"y\":0,\"width\":10,\"height\":10,\"text\":\"\(String(repeating: "a", count: 10_001))\"}",
        ]
        for json in refused {
            XCTAssertThrowsError(try drawn(json).element(style: Style(), layerID: UUID(), seed: 1), String(json.prefix(80)))
        }
        XCTAssertNoThrow(try drawn(#"{"kind":"rectangle","x":-90000,"y":90000,"width":20000,"height":20000,"strokeWidth":24}"#)
            .element(style: Style(), layerID: UUID(), seed: 1), "the limits themselves are fine")
    }

    func testAToolIdMayNotContainASlash() throws {
        XCTAssertThrowsError(try runtime(#"extension.tool({ id: "a/b", name: "AB", draw: function () { return { elements: [] }; } })"#)) {
            XCTAssertTrue("\($0)".contains("tool id 'a/b'"), "\($0)")
        }
    }

    func testTooManyElementsAreRefused() throws {
        let rt = try runtime("""
            extension.tool({ id: "many", name: "Many", draw: function () {
              var out = []; for (var i = 0; i < 501; i++) out.push({ kind: "rectangle", x: i, y: 0, width: 1, height: 1 });
              return { elements: out };
            } });
            """)
        let drawn = try rt.draw(tool: "many", ToolGesture(points: [.zero], done: true))
        XCTAssertThrowsError(try DrawnElement.elements(drawn, style: Style(), layerID: UUID(), seed: 1))
    }

    /// The template's Ribbon tool: a click leaves a dot, a drag a single filled path, which reads back and draws
    /// without the extension.
    func testTheTemplateRibbonDrawsAPlainFilledPath() throws {
        let template = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../extension-template")
        let rt = try ExtensionRuntime(bundle: template.standardizedFileURL)
        XCTAssertEqual(rt.tools.map(\.id), ["ribbon"])
        let style = Style()
        let dot = try DrawnElement.elements(try rt.draw(tool: "ribbon", ToolGesture(points: [CGPoint(x: 50, y: 50)], done: false)),
                                            style: style, layerID: UUID(), seed: 1)
        XCTAssertEqual(dot.map(\.kind), [.ellipse])
        let wave = (0...60).map { CGPoint(x: 20 + Double($0) * 5, y: 100 + 40 * sin(Double($0) / 6)) }
        var page = DottieDocument()
        let ribbon = try DrawnElement.elements(try rt.draw(tool: "ribbon", ToolGesture(points: wave, done: true)),
                                               style: style, layerID: page.layers[0].id, seed: 1)
        XCTAssertEqual(ribbon.map(\.kind), [.path])
        let e = ribbon[0]
        XCTAssertEqual(e.style.fill, RGBA(hex: "#2f4fd8"))
        XCTAssertEqual(e.style.fillStyle, .solid)
        XCTAssertEqual(e.subpaths?.count, 1)
        XCTAssertEqual(e.frame.minX, 20, accuracy: 3, "it follows the drag")
        XCTAssertEqual(e.frame.maxX, 320, accuracy: 3)
        XCTAssertLessThan(e.frame.height, 80 + 14 + 1, "no wider than the nib around the wave")
        page.elements = ribbon
        let back = try DottieDocument.decode(try page.encoded())
        XCTAssertEqual(back.elements.map(\.subpaths), ribbon.map(\.subpaths), "saved as it was drawn")
        XCTAssertEqual(back.elements.map(\.style), ribbon.map(\.style))
        XCTAssertTrue(Exporter.svg(back).contains("<path"))
    }
}
