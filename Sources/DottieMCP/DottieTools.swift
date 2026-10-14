import Foundation
import CoreGraphics
import DottieKit
import MCP

// MARK: Schema helpers

private func prop(_ type: String, _ desc: String, enum values: [String]? = nil) -> Value {
    var o: [String: Value] = ["type": .string(type), "description": .string(desc)]
    if let values { o["enum"] = .array(values.map { .string($0) }) }
    return .object(o)
}

private func schema(_ props: [String: Value], required: [String] = []) -> Value {
    .object(["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })])
}

private let pathProp = prop("string", "Absolute path to a .dottie file, or \"current\" for the frontmost open Dottie window (needs the app running)")
private let kindValues = ["rectangle", "ellipse", "diamond", "text"]
private let routingValues = ["straight", "curved", "elbow"]

private struct ToolFailure: Error { var message: String }

private struct Args {
    var raw: [String: Value]

    func string(_ k: String) -> String? { raw[k]?.stringValue }
    func double(_ k: String) -> Double? { raw[k]?.doubleValue ?? raw[k]?.intValue.map(Double.init) }
    func bool(_ k: String) -> Bool? { raw[k]?.boolValue }
    func array(_ k: String) -> [Args]? { raw[k]?.arrayValue?.map { Args(raw: $0.objectValue ?? [:]) } }

    func require(_ k: String) throws -> String {
        guard let s = string(k), !s.isEmpty else { throw ToolFailure(message: "Missing required argument '\(k)'") }
        return s
    }
    func color(_ k: String) throws -> RGBA? {
        guard let s = string(k) else { return nil }
        guard let c = RGBA(hex: s) else { throw ToolFailure(message: "'\(k)' must be a hex color like #ffcc00, got '\(s)'") }
        return c
    }
    func kind(_ k: String, default d: ElementKind = .rectangle) throws -> ElementKind {
        guard let s = string(k) else { return d }
        guard let kind = ElementKind(rawValue: s), kind != .connector else {
            throw ToolFailure(message: "'\(k)' must be one of \(kindValues.joined(separator: ", ")), got '\(s)'")
        }
        return kind
    }
    func routing(_ k: String) throws -> Routing? {
        guard let s = string(k) else { return nil }
        guard let r = Routing(rawValue: s) else { throw ToolFailure(message: "'\(k)' must be one of \(routingValues.joined(separator: ", "))") }
        return r
    }
    func uuid(_ k: String) throws -> UUID {
        let s = try require(k)
        guard let u = UUID(uuidString: s) else { throw ToolFailure(message: "'\(k)' is not a valid element id: \(s)") }
        return u
    }
    var roughness: Double? { bool("sketchy").map { $0 ? 1 : 0 } }
}

// MARK: Tools

/// Stateless: every call loads the file, edits, and saves atomically. The actor serializes calls
/// so concurrent requests can't interleave read-modify-write on the same file.
actor DottieTools {
    private var currentTool = "edit"

    static let definitions: [Tool] = [
        Tool(name: "create_diagram",
             description: "Create a new empty .dottie file (fails if it already exists unless overwrite is true).",
             inputSchema: schema(["path": pathProp, "overwrite": prop("boolean", "Replace an existing file")], required: ["path"])),
        Tool(name: "build_diagram",
             description: "Add a set of nodes and edges, automatically laid out in ranks, with connectors that stay attached. "
                + "Appends below existing content, so call it again to add more. Returns a map of node key to element id.",
             inputSchema: schema([
                "path": pathProp,
                "nodes": .object(["type": "array", "description": "Nodes to add", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "key": prop("string", "Unique local key used by edges"),
                        "text": prop("string", "Label shown inside the shape"),
                        "kind": prop("string", "Shape type, default rectangle", enum: kindValues),
                        "fill": prop("string", "Hex fill color, e.g. #ffeeaa"),
                        "width": prop("number", "Optional width; auto-sized from text otherwise"),
                        "height": prop("number", "Optional height"),
                    ]),
                    "required": ["key", "text"],
                ])]),
                "edges": .object(["type": "array", "description": "Connectors between node keys", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "from": prop("string", "Source node key"),
                        "to": prop("string", "Target node key"),
                        "routing": prop("string", "Default elbow", enum: routingValues),
                        "arrow": prop("boolean", "Arrowhead at the target, default true"),
                    ]),
                    "required": ["from", "to"],
                ])]),
                "direction": prop("string", "TB = top to bottom (default), LR = left to right", enum: ["TB", "LR"]),
                "sketchy": prop("boolean", "Hand-drawn look (default true); false for precise geometry"),
             ], required: ["path", "nodes"])),
        Tool(name: "add_shape",
             description: "Add one shape at an exact position. Returns its element id.",
             inputSchema: schema([
                "path": pathProp,
                "kind": prop("string", "Shape type", enum: kindValues),
                "x": prop("number", "Left edge"), "y": prop("number", "Top edge"),
                "width": prop("number", "Width; auto-sized from text if omitted"),
                "height": prop("number", "Height"),
                "text": prop("string", "Label"),
                "fill": prop("string", "Hex fill color"), "stroke": prop("string", "Hex stroke color"),
                "sketchy": prop("boolean", "Hand-drawn look (default true)"),
             ], required: ["path", "kind", "x", "y"])),
        Tool(name: "add_connector",
             description: "Connect two shapes. The connector stays attached when shapes move.",
             inputSchema: schema([
                "path": pathProp,
                "from_id": prop("string", "Source element id"), "to_id": prop("string", "Target element id"),
                "routing": prop("string", "Default straight", enum: routingValues),
                "arrow": prop("boolean", "Arrowhead at the target, default true"),
                "sketchy": prop("boolean", "Hand-drawn look (default true)"),
             ], required: ["path", "from_id", "to_id"])),
        Tool(name: "update_element",
             description: "Change text, position, size, colors, look or routing of an element. Only provided fields change.",
             inputSchema: schema([
                "path": pathProp, "id": prop("string", "Element id"),
                "text": prop("string", "New label"),
                "x": prop("number", "Left edge"), "y": prop("number", "Top edge"),
                "width": prop("number", "Width"), "height": prop("number", "Height"),
                "fill": prop("string", "Hex fill color"), "stroke": prop("string", "Hex stroke color"),
                "sketchy": prop("boolean", "Hand-drawn look"),
                "routing": prop("string", "Connector routing", enum: routingValues),
             ], required: ["path", "id"])),
        Tool(name: "delete_element",
             description: "Delete an element. Connectors attached to a deleted shape stay in place as free arrows.",
             inputSchema: schema(["path": pathProp, "id": prop("string", "Element id")], required: ["path", "id"])),
        Tool(name: "list_elements",
             description: "List every element with id, kind, bounds, text and connector endpoints.",
             inputSchema: schema(["path": pathProp], required: ["path"])),
        Tool(name: "auto_layout",
             description: "Re-arrange all shapes into ranks, using existing connectors as edges.",
             inputSchema: schema(["path": pathProp,
                                  "direction": prop("string", "TB (default) or LR", enum: ["TB", "LR"])], required: ["path"])),
        Tool(name: "export_png",
             description: "Render the diagram to a PNG and return it as an image so you can check the result. "
                + "Optionally also save it to out_path. Set sketchy=false to render the same drawing clean.",
             inputSchema: schema([
                "path": pathProp,
                "scale": prop("number", "Pixel scale, default 2"),
                "sketchy": prop("boolean", "Override the look for this render only"),
                "out_path": prop("string", "Optional absolute path ending in .png to also write the image to"),
             ], required: ["path"])),
        Tool(name: "export_svg",
             description: "Export the diagram as SVG using the same sketchy paths as the app. Returns the SVG text, "
                + "or writes it to out_path (preferred for large diagrams).",
             inputSchema: schema([
                "path": pathProp,
                "sketchy": prop("boolean", "Override the look for this export only"),
                "transparent": prop("boolean", "Omit the white page background"),
                "out_path": prop("string", "Optional absolute path ending in .svg to write the file to"),
             ], required: ["path"])),
    ]

    func call(name: String, arguments: [String: Value]) -> CallTool.Result {
        do {
            return try run(name, Args(raw: arguments))
        } catch let e as ToolFailure {
            return .init(content: [.text(e.message)], isError: true)
        } catch {
            return .init(content: [.text("\(error)")], isError: true)
        }
    }

    // MARK: Files

    /// Sentinel for "the frontmost window in the app": live only, never a file.
    private static let currentURL = URL(string: "dottie-live:current")!

    private func fileURL(_ args: Args, key: String = "path", ext: String = "dottie") throws -> URL {
        let raw = try args.require(key)
        if key == "path", raw == "current" { return Self.currentURL }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ToolFailure(message: "'\(key)' must be an absolute path") }
        guard expanded.lowercased().hasSuffix("." + ext) else { throw ToolFailure(message: "'\(key)' must end in .\(ext)") }
        return URL(fileURLWithPath: expanded)
    }

    private func load(_ url: URL, createIfMissing: Bool = false) throws -> DottieDocument {
        // Live mode: if the Dottie app has this file open, edit that copy instead of the file on disk.
        if url == Self.currentURL {
            guard let live = LiveClient.get(path: "current") else {
                throw ToolFailure(message: "No Dottie window to draw in. Open or create a document in the Dottie app (it must be running), or pass an absolute .dottie path.")
            }
            return live
        }
        if let live = LiveClient.get(path: url.path) { return live }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if createIfMissing { return DottieDocument() }
            throw ToolFailure(message: "No such file: \(url.path). Call create_diagram or build_diagram first.")
        }
        do { return try DottieDocument.decode(try Data(contentsOf: url)) }
        catch { throw ToolFailure(message: "Could not read \(url.path) as a Dottie file: \(error)") }
    }

    private func save(_ doc: DottieDocument, to url: URL) throws {
        if url == Self.currentURL {
            guard LiveClient.put(doc, path: "current", actionName: "Agent: \(currentTool)") else {
                throw ToolFailure(message: "The Dottie window is no longer available.")
            }
            return
        }
        if LiveClient.put(doc, path: url.path, actionName: "Agent: \(currentTool)") { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try doc.encoded().write(to: url, options: .atomic)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try enc.encode(value), as: UTF8.self)
    }

    private func text(_ s: String) -> CallTool.Result { .init(content: [.text(s)]) }

    // MARK: Dispatch

    private func run(_ name: String, _ a: Args) throws -> CallTool.Result {
        currentTool = name
        switch name {
        case "create_diagram":
            let url = try fileURL(a)
            if url == Self.currentURL { throw ToolFailure(message: "create_diagram needs a file path; \"current\" already refers to an open window.") }
            if FileManager.default.fileExists(atPath: url.path), a.bool("overwrite") != true {
                throw ToolFailure(message: "\(url.path) already exists. Pass overwrite=true to replace it, or edit it directly.")
            }
            try save(DottieDocument(), to: url)
            return text("Created \(url.path)")

        case "build_diagram":
            let url = try fileURL(a)
            var doc = try load(url, createIfMissing: true)
            guard let nodeArgs = a.array("nodes"), !nodeArgs.isEmpty else { throw ToolFailure(message: "'nodes' must be a non-empty array") }
            let nodes = try nodeArgs.map { n in
                DiagramOps.NodeSpec(key: try n.require("key"), text: n.string("text") ?? "", kind: try n.kind("kind"),
                                    fill: try n.color("fill"), width: n.double("width"), height: n.double("height"))
            }
            let edges = try (a.array("edges") ?? []).map { e in
                DiagramOps.EdgeSpec(from: try e.require("from"), to: try e.require("to"),
                                    routing: try e.routing("routing"), arrow: e.bool("arrow") ?? true)
            }
            let direction = LayoutDirection(rawValue: a.string("direction") ?? "TB") ?? .topToBottom
            let ids: [String: UUID]
            do {
                ids = try DiagramOps.build(&doc, nodes: nodes, edges: edges, direction: direction, roughness: a.roughness ?? 1)
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(doc, to: url)
            let map = ids.mapValues(\.uuidString)
            return text("Added \(nodes.count) nodes and \(edges.count) edges to \(url.path).\n" + (try json(map)))

        case "add_shape":
            let url = try fileURL(a)
            var doc = try load(url, createIfMissing: true)
            guard let x = a.double("x"), let y = a.double("y") else { throw ToolFailure(message: "'x' and 'y' are required") }
            var frame: CGRect?
            if let w = a.double("width"), let h = a.double("height") { frame = CGRect(x: x, y: y, width: w, height: h) }
            let e = try DiagramOps.addShape(&doc, kind: try a.kind("kind"), frame: frame, at: CGPoint(x: x, y: y),
                                            text: a.string("text"), fill: try a.color("fill"), stroke: try a.color("stroke"),
                                            roughness: a.roughness)
            try save(doc, to: url)
            return text("id: \(e.id.uuidString)\nframe: x=\(e.x) y=\(e.y) w=\(e.width) h=\(e.height)")

        case "add_connector":
            let url = try fileURL(a)
            var doc = try load(url)
            let c: Element
            do {
                c = try DiagramOps.addConnector(&doc, from: try a.uuid("from_id"), to: try a.uuid("to_id"),
                                                routing: try a.routing("routing") ?? .straight, arrow: a.bool("arrow") ?? true,
                                                roughness: a.roughness)
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(doc, to: url)
            return text("id: \(c.id.uuidString)")

        case "update_element":
            let url = try fileURL(a)
            var doc = try load(url)
            do {
                try DiagramOps.update(&doc, id: try a.uuid("id"), text: a.string("text").map { Optional($0) },
                                      x: a.double("x"), y: a.double("y"), width: a.double("width"), height: a.double("height"),
                                      fill: try a.color("fill"), stroke: try a.color("stroke"), roughness: a.roughness,
                                      routing: try a.routing("routing"))
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(doc, to: url)
            return text("Updated")

        case "delete_element":
            let url = try fileURL(a)
            var doc = try load(url)
            do { try DiagramOps.delete(&doc, id: try a.uuid("id")) } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(doc, to: url)
            return text("Deleted")

        case "list_elements":
            let doc = try load(try fileURL(a))
            return text(try json(DiagramOps.summarize(doc)))

        case "auto_layout":
            let url = try fileURL(a)
            var doc = try load(url)
            DiagramOps.autoLayout(&doc, direction: LayoutDirection(rawValue: a.string("direction") ?? "TB") ?? .topToBottom)
            try save(doc, to: url)
            return text("Re-laid out \(doc.elements.filter { $0.kind != .connector }.count) shapes")

        case "export_png":
            var doc = try load(try fileURL(a))
            if let r = a.roughness { doc = doc.withRoughness(r) }
            guard !doc.elements.isEmpty else { throw ToolFailure(message: "The diagram is empty; nothing to render") }
            let scale = min(max(a.double("scale") ?? 2, 0.25), 4)
            guard let png = Exporter.png(doc, scale: scale) else { throw ToolFailure(message: "Rendering failed") }
            var note = "Rendered \(doc.elements.count) elements"
            if a.string("out_path") != nil {
                let out = try fileURL(a, key: "out_path", ext: "png")
                try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: out, options: .atomic)
                note += ", saved to \(out.path)"
            }
            return .init(content: [.image(data: png.base64EncodedString(), mimeType: "image/png", metadata: nil), .text(note)])

        case "export_svg":
            var doc = try load(try fileURL(a))
            if let r = a.roughness { doc = doc.withRoughness(r) }
            guard !doc.elements.isEmpty else { throw ToolFailure(message: "The diagram is empty; nothing to export") }
            let svg = Exporter.svg(doc, background: a.bool("transparent") == true ? nil : RGBA(r: 1, g: 1, b: 1))
            guard a.string("out_path") != nil else { return text(svg) }
            let out = try fileURL(a, key: "out_path", ext: "svg")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try svg.write(to: out, atomically: true, encoding: .utf8)
            return text("Exported \(doc.elements.count) elements to \(out.path)")

        default:
            throw ToolFailure(message: "Unknown tool '\(name)'")
        }
    }
}
