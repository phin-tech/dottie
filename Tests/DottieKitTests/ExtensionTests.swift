import XCTest
@testable import DottieKit

@MainActor
final class ExtensionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ext-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `<name>.dottieext` with the manifest and main.js given.
    @discardableResult
    private func bundle(_ name: String, api: Int = 1, id: String = "com.example.shapes", version: String = "1.0.0",
                        main: String) throws -> URL {
        let dir = root.appendingPathComponent("\(name).dottieext", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = #"{"id":"\#(id)","name":"Shapes","version":"\#(version)","dottieApi":\#(api)}"#
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try main.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        return dir
    }

    private static let box = """
        extension.shape({
          id: "box", name: "Box",
          parameters: {
            inset: { type: "number", label: "Inset", min: 0, max: 0.5, default: 0.1 },
            sides: { type: "integer", min: 3, max: 8, default: 4 },
            round: { type: "boolean", default: false },
            shape: { type: "enum", options: ["square", "tall"], default: "square" }
          },
          generate: function (p, frame) {
            var i = p.inset;
            return { subpaths: [{ closed: true, coords: [i, i, 1 - i, i, 1 - i, 1 - i, i, 1 - i] }],
                     ports: [{ x: 0.5, y: 0 }], labelRect: { x: i, y: i, width: 1 - 2 * i, height: 1 - 2 * i } };
          }
        });
        """

    func testLoadsManifestAndShapesInDeclaredOrder() throws {
        let dir = try bundle("Box", main: Self.box)
        let runtime = try ExtensionRuntime(bundle: dir)
        XCTAssertEqual(runtime.manifest.id, "com.example.shapes")
        XCTAssertEqual(runtime.shapes.map(\.id), ["box"])
        XCTAssertEqual(runtime.shapes[0].parameters.map(\.name), ["inset", "sides", "round", "shape"])
        XCTAssertEqual(runtime.shapes[0].parameters[0].default, .number(0.1))
    }

    func testGenerateReturnsNormalizedPathAndPorts() throws {
        let runtime = try ExtensionRuntime(bundle: try bundle("Box", main: Self.box))
        let out = try runtime.generate(shape: "box", params: ["inset": .number(0.25)], width: 100, height: 50)
        XCTAssertEqual(out.subpaths, [PathSubpath(closed: true, coords: [0.25, 0.25, 0.75, 0.25, 0.75, 0.75, 0.25, 0.75])])
        XCTAssertEqual(out.ports, [NormalizedPoint(x: 0.5, y: 0)])
        XCTAssertEqual(out.labelRect, NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    func testMissingParametersTakeDefaultsAndUnknownOnesAreDropped() throws {
        let runtime = try ExtensionRuntime(bundle: try bundle("Box", main: Self.box))
        let params = try runtime.normalized(["sides": .number(5), "nonsense": .bool(true)], shape: "box")
        XCTAssertEqual(params, [
            "inset": .number(0.1), "sides": .number(5), "round": .bool(false), "shape": .string("square"),
        ])
    }

    func testOutOfRangeAndWrongTypeAreRefusedBeforeGenerate() throws {
        let runtime = try ExtensionRuntime(bundle: try bundle("Box", main: Self.box))
        XCTAssertThrowsError(try runtime.normalized(["inset": .number(0.9)], shape: "box")) { error in
            XCTAssertEqual(error as? ExtensionError, .invalidParameter("inset", "must be at most 0.5"))
        }
        XCTAssertThrowsError(try runtime.normalized(["sides": .number(4.5)], shape: "box")) { error in
            XCTAssertEqual(error as? ExtensionError, .invalidParameter("sides", "must be a whole number"))
        }
        XCTAssertThrowsError(try runtime.normalized(["round": .number(1)], shape: "box"))
        XCTAssertThrowsError(try runtime.normalized(["shape": .string("round")], shape: "box"))
    }

    func testIncompatibleAPIIsNotLoaded() throws {
        let dir = try bundle("New", api: 2, main: Self.box)
        XCTAssertThrowsError(try ExtensionRuntime(bundle: dir)) { error in
            XCTAssertEqual(error as? ExtensionError, .incompatible(required: 2))
        }
    }

    func testThrowingGenerateReportsErrorAndTheRuntimeRecovers() throws {
        let main = Self.box.replacingOccurrences(of: "var i = p.inset;", with: "if (p.inset > 0.2) throw new Error(\"too wide\"); var i = p.inset;")
        let runtime = try ExtensionRuntime(bundle: try bundle("Box", main: main))
        XCTAssertThrowsError(try runtime.generate(shape: "box", params: ["inset": .number(0.3)], width: 1, height: 1)) { error in
            XCTAssertEqual(error as? ExtensionError, .failed("Error: too wide"))
        }
        let ok = try runtime.generate(shape: "box", params: ["inset": .number(0.1)], width: 1, height: 1)
        XCTAssertEqual(ok.subpaths.count, 1)
    }

    func testOutputThatIsNotAPathIsRefused() throws {
        let main = Self.box.replacingOccurrences(of: "coords: [i, i, 1 - i, i, 1 - i, 1 - i, i, 1 - i]", with: "coords: [i]")
        let runtime = try ExtensionRuntime(bundle: try bundle("Box", main: main))
        XCTAssertThrowsError(try runtime.generate(shape: "box", params: [:], width: 1, height: 1)) { error in
            guard case .invalidOutput = error as? ExtensionError else { return XCTFail("\(error)") }
        }
    }

    func testRunawayGenerateIsStopped() throws {
        let main = Self.box.replacingOccurrences(of: "var i = p.inset;", with: "while (true) {} var i = p.inset;")
        let runtime = try ExtensionRuntime(bundle: try bundle("Box", main: main))
        XCTAssertThrowsError(try runtime.generate(shape: "box", params: [:], width: 1, height: 1))
    }

    func testMigrateRunsWhenVersionsDiffer() throws {
        let main = Self.box + """

            extension.migrate(function (from, params, shape) {
              if (from === "0.9") { params.inset = params.oldInset; delete params.oldInset; }
              return params;
            });
            """
        let runtime = try ExtensionRuntime(bundle: try bundle("Box", version: "1.0.0", main: main))
        let saved = ExtensionRef(id: "com.example.shapes", shape: "box", version: "0.9", params: ["oldInset": .number(0.2)])
        XCTAssertEqual(try runtime.migrated(saved)["inset"], .number(0.2))
        let current = ExtensionRef(id: "com.example.shapes", shape: "box", version: "1.0.0", params: ["inset": .number(0.3)])
        XCTAssertEqual(try runtime.migrated(current)["inset"], .number(0.3))
    }

    func testRegistryListsBrokenBundlesWithTheirReason() throws {
        try bundle("Good", main: Self.box)
        try bundle("Newer", api: 9, id: "com.example.newer", main: Self.box)
        try bundle("Twin", id: "com.example.shapes", main: Self.box)
        let registry = ExtensionRegistry()
        registry.scan(in: root)
        XCTAssertEqual(registry.entries.map(\.name), ["Shapes", "Newer", "Twin"])
        XCTAssertNotNil(registry.entries[0].runtime)
        XCTAssertEqual(registry.entries[1].error, "needs dottieApi 9; this Dottie runs 1")
        XCTAssertEqual(registry.entries[2].error, "another bundle already has id com.example.shapes")
        XCTAssertNotNil(registry.runtime(for: "com.example.shapes"))
    }

    func testCommandRunsAgainstTheDocumentAsOneScript() throws {
        let main = """
            extension.command({
              id: "row", name: "Row", category: "Layout",
              parameters: { count: { type: "integer", min: 1, max: 10, default: 3 } },
              run: function (p) {
                for (var i = 0; i < p.count; i++) dottie.rect({ x: i * 120, y: 0, text: "n" + i });
                return dottie.elements().length;
              }
            });
            """
        let runtime = try ExtensionRuntime(bundle: try bundle("Row", main: main))
        XCTAssertEqual(runtime.commands.map(\.id), ["row"])
        XCTAssertEqual(runtime.commands[0].category, "Layout")
        var doc = DottieDocument()
        let source = try runtime.commandSource("row", params: ["count": .number(2)])
        let result = DottieScript.run(source, on: &doc, timeLimit: 5)
        XCTAssertNil(result.error)
        XCTAssertEqual(doc.elements.count, 2)
        XCTAssertEqual(result.value, "2")
        XCTAssertThrowsError(try runtime.commandSource("row", params: ["count": .number(11)]))
        XCTAssertThrowsError(try runtime.commandSource("nope", params: [:])) { error in
            XCTAssertEqual(error as? ExtensionError, .noSuchCommand("nope"))
        }
    }

    func testScriptDrawsAnExtensionShape() throws {
        let runtime = try ExtensionRuntime(bundle: try bundle("Box", main: Self.box))
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const e = dottie.shape({extension: {id: "com.example.shapes", shape: "box"}, params: {inset: 0.2, shape: "tall"}, x: 10, y: 20, width: 100, height: 50});
            return e.kind;
            """, on: &doc, extensions: [runtime], timeLimit: 5)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, "\"path\"")
        XCTAssertEqual(doc.elements.count, 1)
        XCTAssertEqual(doc.elements[0].extension?.params["inset"], .number(0.2))
        XCTAssertEqual(doc.elements[0].extension?.params["shape"], .string("tall"))
        XCTAssertEqual(doc.elements[0].labelRect, NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        XCTAssertEqual(doc.elements[0].frame, CGRect(x: 10, y: 20, width: 100, height: 50))

        let missing = DottieScript.run(#"dottie.shape({extension: {id: "nope", shape: "box"}, x: 0, y: 0})"#, on: &doc, extensions: [runtime], timeLimit: 5)
        XCTAssertNotNil(missing.error)
    }

    func testDisabledExtensionIsListedButNotLoaded() throws {
        try bundle("Box", main: Self.box)
        let registry = ExtensionRegistry()
        registry.scan(in: root, disabled: ["com.example.shapes"])
        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertFalse(registry.entries[0].enabled)
        XCTAssertNil(registry.entries[0].runtime)
    }

    func testShapeElementRoundTripsAndOldFilesStillDecode() throws {
        var element = Element(kind: .path, frame: CGRect(x: 0, y: 0, width: 100, height: 50), layerID: UUID())
        let runtime = try ExtensionRuntime(bundle: try bundle("Box", main: Self.box))
        let ref = ExtensionRef(id: "com.example.shapes", shape: "box", version: "1.0.0", params: ["inset": .number(0.2)])
        element.extension = ref
        element.apply(try runtime.generate(shape: "box", params: ref.params, width: 100, height: 50))
        let data = try JSONEncoder().encode(element)
        let back = try JSONDecoder().decode(Element.self, from: data)
        XCTAssertEqual(back, element)
        XCTAssertEqual(back.extension?.params["inset"], .number(0.2))
        XCTAssertEqual(back.labelRect, NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))

        let plain = Element(kind: .path, frame: .zero, layerID: UUID())
        let plainData = try JSONEncoder().encode(plain)
        let json = try JSONSerialization.jsonObject(with: plainData) as? [String: Any]
        XCTAssertNil(json?["extension"], "an element that is not an extension shape writes no extension key")
    }
}

@MainActor
final class ExtensionHandleTests: XCTestCase {
    /// A box whose `inset` is set by dragging its corner handle: the handle sits at the inset corner, and dragging
    /// it to a point sets the inset to that point's distance along x, as a fraction of the width.
    func testHandlePositionAndDragChangeTheParameter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handle-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("Box.dottieext", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"id":"com.example.handles","name":"Handles","version":"1.0.0","dottieApi":1}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
            extension.shape({
              id: "box", name: "Box",
              parameters: { inset: { type: "number", min: 0, max: 0.5, default: 0.1 } },
              generate: function (p) {
                var i = p.inset;
                return { subpaths: [{ closed: true, coords: [i, i, 1 - i, i, 1 - i, 1 - i, i, 1 - i] }] };
              },
              handles: [{
                id: "corner",
                position: function (p, f) { return { x: p.inset * f.width, y: p.inset * f.height }; },
                drag: function (p, f, pt) { return { inset: Math.min(0.5, Math.max(0, pt.x / f.width)) }; }
              }]
            });
            """.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)

        let runtime = try ExtensionRuntime(bundle: dir)
        XCTAssertEqual(runtime.shapes[0].handles, [HandleDefinition(id: "corner")])
        let at = try runtime.handlePosition(shape: "box", handle: "corner", params: ["inset": .number(0.2)], width: 100, height: 50)
        XCTAssertEqual(at, CGPoint(x: 20, y: 10))
        let moved = try runtime.handleDrag(shape: "box", handle: "corner", params: ["inset": .number(0.2)],
                                           width: 100, height: 50, to: CGPoint(x: 30, y: 5))
        XCTAssertEqual(moved, ["inset": .number(0.3)])
        XCTAssertThrowsError(try runtime.handlePosition(shape: "box", handle: "nope", params: [:], width: 1, height: 1))
    }
}
