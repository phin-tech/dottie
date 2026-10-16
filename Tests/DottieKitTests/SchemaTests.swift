import XCTest
@testable import DottieKit

/// schema/dottie.schema.json describes the file format for other readers (dottie.js in web/ validates against it).
/// These tests keep it in step with the Swift model: a property added to a model type, or a value the encoder
/// writes, that the schema doesn't allow fails here, which is the prompt to update dottie.js too.
final class SchemaTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func schema() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("schema/dottie.schema.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every fixture as Dottie writes it back, and the Design/ drawings exactly as committed.
    func testFixturesValidate() throws {
        let validator = try SchemaValidator(schema())
        var files: [URL] = []
        for dir in ["fixtures/design", "fixtures/edge", "Design", "Design/demos"] {
            let url = Self.root.appendingPathComponent(dir)
            files += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension == "dottie" }
        }
        XCTAssertGreaterThan(files.count, 10)
        for url in files {
            let data = try Data(contentsOf: url)
            let encoded = try DottieFile.decode(data).encoded()
            let problems = validator.validate(try JSONSerialization.jsonObject(with: encoded))
            XCTAssertEqual(problems, [], "\(url.lastPathComponent), as Dottie writes it")
            if url.path.contains("/Design/") || url.path.contains("fixtures/design") {
                XCTAssertEqual(validator.validate(try JSONSerialization.jsonObject(with: data)), [], url.lastPathComponent)
            }
        }
    }

    /// A drawing with every optional field set validates once encoded.
    func testEverythingEncodedValidates() throws {
        let layer = Layer(name: "L")
        var style = Style()
        style.gridSize = 20; style.opacity = 0.5; style.fillStyle = .grid; style.dash = .dotted
        var box = Element(kind: .path, frame: CGRect(x: 0, y: 0, width: 10, height: 10), style: style, layerID: layer.id,
                          text: "t", groupID: UUID(), points: [StrokePoint(x: 0, y: 1)])
        box.path = [0, 0, 1, 1, 1, 1, 1, 1]
        box.subpaths = [PathSubpath(closed: true, coords: [0, 0, 1, 0, 1, 1, 1, 1])]
        box.evenOdd = true; box.rotation = 0.5; box.link = UUID(); box.anchor = "a"; box.reveal = 0.5
        box.image = EmbeddedImage(data: Data([1, 2, 3]), format: "png")
        var line = Element(kind: .connector, frame: .zero, layerID: layer.id,
                           connector: ConnectorData(start: .bound(box.id, port: .top), end: .free(CGPoint(x: 5, y: 5)), routing: .elbow))
        line.connector?.startHead = .dot
        var page = DottieDocument(name: "P", layers: [layer], elements: [box, line])
        page.theme = "midnight"; page.guidesX = [1]; page.guidesY = [2]; page.guidesLocked = true
        var tl = Timeline(fps: 24, duration: 3, boil: 2, settle: true)
        tl.poster = 1
        tl.setKey(Keyframe(t: 0, x: 1, y: 2, width: 3, height: 4, rotation: 0.1, strokeWidth: 2, stroke: .black, fill: .clear,
                           visible: true, reveal: 0, opacity: 0.5, ease: .hold), for: box.id)
        tl.setBoil(true, for: box.id)
        tl.addFollow(Follow(path: line.id, start: 0, end: 1, ease: .easeIn, reverse: true, orient: true, laps: 2), for: box.id)
        tl.addRepeat(for: box.id, from: 0, to: 1, count: 2)
        tl.setCamera(CameraKey(t: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10), ease: .linear))
        tl.addMarker(at: 1, name: "m")
        page.timeline = tl
        let json = try JSONSerialization.jsonObject(with: DottieFile(pages: [page]).encoded())
        XCTAssertEqual(try SchemaValidator(schema()).validate(json), [])
    }

    /// Every stored property of the model types is a property in the schema, even ones no fixture sets yet.
    func testSchemaListsEveryModelProperty() throws {
        let defs = try XCTUnwrap(schema()["$defs"] as? [String: Any])
        func properties(_ def: String) -> Set<String> {
            Set(((defs[def] as? [String: Any])?["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
        }
        let layer = Layer(name: "L")
        var tl = Timeline(duration: 1)
        tl.tracks = [Track(element: UUID(), keys: [])]
        let models: [(String, Any)] = [
            ("file", DottieFile()), ("page", DottieDocument()), ("layer", layer), ("rgba", RGBA.black), ("style", Style()),
            ("element", Element(kind: .rectangle, frame: .zero, layerID: layer.id)),
            ("strokePoint", StrokePoint(x: 0, y: 0)), ("subpath", PathSubpath(closed: true, coords: [])),
            ("endpoint", Endpoint.free(.zero)), ("connector", ConnectorData(start: .free(.zero), end: .free(.zero))),
            ("timeline", tl), ("track", tl.tracks[0]), ("keyframe", Keyframe(t: 0)),
            ("follow", Follow(path: UUID(), start: 0, end: 1)), ("repeat", Repeat(start: 0, end: 1)),
            ("cameraKey", CameraKey(t: 0, rect: .zero)), ("marker", Marker(t: 0, name: "")),
        ]
        for (def, value) in models {
            let stored = Set(Mirror(reflecting: value).children.compactMap(\.label).map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 })
            let missing = stored.subtracting(properties(def))
            XCTAssertEqual(missing, [], "\(def): stored properties missing from schema/dottie.schema.json")
        }
        // The file's picture table is written by its encoder rather than stored on the type.
        XCTAssertTrue(properties("file").contains("images"))
    }
}

/// Just enough JSON Schema (2020-12) for dottie.schema.json: type, enum, properties, required,
/// additionalProperties, items, minItems, minimum, maximum, pattern, oneOf and local $ref.
struct SchemaValidator {
    let root: [String: Any]
    init(_ root: [String: Any]) { self.root = root }

    func validate(_ value: Any) -> [String] {
        var out: [String] = []
        check(value, root, "$", &out)
        return out
    }

    private func resolve(_ ref: String) -> [String: Any] {
        var node: Any = root
        for part in ref.dropFirst(2).split(separator: "/") { node = (node as? [String: Any])?[String(part)] ?? [:] }
        return node as? [String: Any] ?? [:]
    }

    private func check(_ v: Any, _ s: [String: Any], _ path: String, _ out: inout [String]) {
        if let ref = s["$ref"] as? String { check(v, resolve(ref), path, &out) }
        if let options = s["oneOf"] as? [[String: Any]] {
            let passing = options.filter { o in var errs: [String] = []; check(v, o, path, &errs); return errs.isEmpty }
            if passing.count != 1 { out.append("\(path): matches \(passing.count) of oneOf") }
        }
        if let allowed = s["enum"] as? [String] {
            if !(v is String) || !allowed.contains(v as! String) { out.append("\(path): \(v) not one of \(allowed)") }
        }
        if let type = s["type"] as? String {
            let ok: Bool
            switch type {
            case "object": ok = v is [String: Any]
            case "array": ok = v is [Any]
            case "string": ok = v is String
            case "boolean": ok = (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            case "integer":
                ok = (v as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == $0.doubleValue.rounded() } ?? false
            case "number": ok = (v as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
            default: ok = true
            }
            if !ok { out.append("\(path): expected \(type)"); return }
        }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            if let min = s["minimum"] as? Double, n.doubleValue < min { out.append("\(path): below \(min)") }
            if let max = s["maximum"] as? Double, n.doubleValue > max { out.append("\(path): above \(max)") }
        }
        if let str = v as? String, let pattern = s["pattern"] as? String, str.range(of: pattern, options: .regularExpression) == nil {
            out.append("\(path): \"\(str)\" doesn't match \(pattern)")
        }
        if let obj = v as? [String: Any] {
            let props = s["properties"] as? [String: Any] ?? [:]
            for key in s["required"] as? [String] ?? [] where obj[key] == nil { out.append("\(path): missing \(key)") }
            for (key, value) in obj {
                if let p = props[key] as? [String: Any] { check(value, p, "\(path).\(key)", &out) }
                else if let extra = s["additionalProperties"] as? [String: Any] { check(value, extra, "\(path).\(key)", &out) }
                else if (s["additionalProperties"] as? Bool) == false { out.append("\(path): unknown property \(key)") }
            }
        }
        if let arr = v as? [Any] {
            if let min = s["minItems"] as? Int, arr.count < min { out.append("\(path): fewer than \(min) items") }
            if let items = s["items"] as? [String: Any] { for (i, x) in arr.enumerated() { check(x, items, "\(path)[\(i)]", &out) } }
        }
    }
}
