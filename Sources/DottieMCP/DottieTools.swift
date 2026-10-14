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
private let pageProp = prop("string", "Page (tab) to work on, by name or 1-based number; default the first page. "
    + "Tools given an element id find its page themselves.")
private let kindValues = ["rectangle", "ellipse", "diamond", "text", "note"]
private let routingValues = ["straight", "curved", "elbow"]
private let fillStyleValues = ["solid", "hachure", "crossHatch"]
private let dashValues = ["solid", "dashed", "dotted"]
private let headValues = ["none", "arrow", "triangle", "dot", "bar"]

/// Look options shared by add_shape, add_connector and update_element.
private let lookProps: [String: Value] = [
    "fill_style": prop("string", "How the fill is painted: solid, or pen-shaded hachure / crossHatch", enum: fillStyleValues),
    "dash": prop("string", "Line style", enum: dashValues),
    "stroke_width": prop("number", "Line width, 0.5 to 24 (default 2)"),
    "bowing": prop("number", "How much sketchy lines bow sideways, 0 to 3 (default 1)"),
    "rotation": prop("number", "Degrees clockwise about the shape's center (shapes only)"),
    "start_head": prop("string", "Connector start arrowhead", enum: headValues),
    "end_head": prop("string", "Connector end arrowhead", enum: headValues),
]

private struct ToolFailure: Error { var message: String }

extension Tool.Content {
    static func plain(_ s: String) -> Self { .text(text: s, annotations: nil, _meta: nil) }
    static func png(_ data: Data) -> Self { .image(data: data.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil) }
}

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
        guard let kind = ElementKind(rawValue: s), kind != .connector, kind != .path else {
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

    private func enumValue<T: RawRepresentable>(_ k: String, _ values: [String]) throws -> T? where T.RawValue == String {
        guard let s = string(k) else { return nil }
        guard let v = T(rawValue: s) else { throw ToolFailure(message: "'\(k)' must be one of \(values.joined(separator: ", ")), got '\(s)'") }
        return v
    }

    func look() throws -> DiagramOps.Look {
        DiagramOps.Look(fillStyle: try enumValue("fill_style", fillStyleValues), dash: try enumValue("dash", dashValues),
                        strokeWidth: double("stroke_width"), bowing: double("bowing"),
                        startHead: try enumValue("start_head", headValues), endHead: try enumValue("end_head", headValues),
                        rotation: double("rotation"))
    }
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
                "path": pathProp, "page": pageProp,
                "nodes": .object(["type": "array", "description": "Nodes to add", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "key": prop("string", "Unique local key used by edges"),
                        "text": prop("string", "Label shown inside the shape"),
                        "kind": prop("string", "Shape type, default rectangle. A note is a sticky note whose text is Markdown", enum: kindValues),
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
                        "label": prop("string", "Text shown on the connector, e.g. \"yes\""),
                    ]),
                    "required": ["from", "to"],
                ])]),
                "direction": prop("string", "TB = top to bottom (default), LR = left to right", enum: ["TB", "LR"]),
                "sketchy": prop("boolean", "Hand-drawn look (default true); false for precise geometry"),
             ], required: ["path", "nodes"])),
        Tool(name: "add_shape",
             description: "Add one shape at an exact position. Returns its element id.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "kind": prop("string", "Shape type. A note is a sticky note whose text is GitHub Flavored Markdown (headings, lists, - [ ] tasks, tables, **bold**, `code`; a single newline is a line break), yellow unless fill is set", enum: kindValues),
                "x": prop("number", "Left edge"), "y": prop("number", "Top edge"),
                "width": prop("number", "Width; auto-sized from text if omitted"),
                "height": prop("number", "Height"),
                "text": prop("string", "Label (Markdown for a note)"),
                "fill": prop("string", "Hex fill color"), "stroke": prop("string", "Hex stroke color"),
                "sketchy": prop("boolean", "Hand-drawn look (default true)"),
             ].merging(lookProps) { a, _ in a }, required: ["path", "kind", "x", "y"])),
        Tool(name: "add_connector",
             description: "Connect two shapes. The connector stays attached when shapes move.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "from_id": prop("string", "Source element id"), "to_id": prop("string", "Target element id"),
                "routing": prop("string", "Default straight", enum: routingValues),
                "arrow": prop("boolean", "Arrowhead at the target, default true"),
                "label": prop("string", "Text shown on the connector"),
                "sketchy": prop("boolean", "Hand-drawn look (default true)"),
             ].merging(lookProps) { a, _ in a }, required: ["path", "from_id", "to_id"])),
        Tool(name: "update_element",
             description: "Change text (a connector's text is its label), position, size, colors, look or routing of an element. Only provided fields change.",
             inputSchema: schema([
                "path": pathProp, "id": prop("string", "Element id (its page is found from it)"),
                "text": prop("string", "New label (Markdown for a note)"),
                "x": prop("number", "Left edge"), "y": prop("number", "Top edge"),
                "width": prop("number", "Width"), "height": prop("number", "Height"),
                "fill": prop("string", "Hex fill color"), "stroke": prop("string", "Hex stroke color"),
                "sketchy": prop("boolean", "Hand-drawn look"),
                "routing": prop("string", "Connector routing", enum: routingValues),
                "anchor": prop("string", "Hidden label for finding and linking to the element; never drawn. Empty string removes it"),
                "link": prop("string", "Id of a shape this element jumps to when its link badge is clicked in the app, on any page "
                    + "(the app switches tabs to follow it); an empty string removes the link"),
             ].merging(lookProps) { a, _ in a }, required: ["path", "id"])),
        Tool(name: "run_script",
             description: "Code mode: run a JavaScript program that edits the diagram through a `dottie` object, in one call "
                + "and one undo step. Use it for loops, conditionals and bulk or computed edits (grids, fan-outs, restyling "
                + "everything matching a rule) that would take many tool calls. Nothing is applied if the script throws. "
                + "Returns console.log output and the script's final value as JSON. Set render=true to also get a PNG.\n\n"
                + DottieScript.apiReference,
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "code": prop("string", "JavaScript source. Use `return` or end with an expression to produce a result."),
                "modules": .object(["type": "object", "description": "Extra modules for require(): name -> JavaScript source (CommonJS)",
                                    "additionalProperties": .object(["type": "string"])]),
                "render": prop("boolean", "Also return a PNG of the result (default false)"),
                "scale": prop("number", "Pixel scale for render, default 2"),
                "timeout": prop("number", "Seconds before the script is stopped, default 10, at most 60"),
             ], required: ["path", "code"])),
        Tool(name: "script_api",
             description: "Reference for the JavaScript API available to run_script (also served as the resource dottie://script-api).",
             inputSchema: schema([:])),
        Tool(name: "list_stencils",
             description: "List the stencil items (reusable shapes: flowchart symbols, icons, imported SVG sets) available "
                + "to add_stencil, from the built-in Basics library and the user's libraries in Application Support/Dottie/Libraries.",
             inputSchema: schema([
                "library": prop("string", "Only this library (by name)"),
                "query": prop("string", "Only items whose name or tags contain this text"),
             ])),
        Tool(name: "add_stencil",
             description: "Place a stencil item (see list_stencils) with its top-left corner at x, y. Returns the new element ids; "
                + "they are grouped, so they move together.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "name": prop("string", "Item name, as listed by list_stencils"),
                "library": prop("string", "Library name, if several have an item with this name"),
                "x": prop("number", "Left edge"), "y": prop("number", "Top edge"),
                "scale": prop("number", "Size multiplier on top of the item's natural size (default 1; icons are enlarged to be readable)"),
                "keep_original_colors": prop("boolean", "Keep the item's own colors and exact geometry (default false: drawn in the diagram's look)"),
                "sketchy": prop("boolean", "Hand-drawn look when restyling (default true)"),
             ], required: ["path", "name", "x", "y"])),
        Tool(name: "open_document",
             description: "Open a .dottie file in the Dottie app (launching it if needed) so edits show live and are undoable. "
                + "Set create=true to make the file first if it does not exist. Reports whether live editing is available.",
             inputSchema: schema([
                "path": .object(["type": "string", "description": "Absolute path to a .dottie file"]),
                "create": prop("boolean", "Create an empty diagram if the file does not exist"),
             ], required: ["path"])),
        Tool(name: "delete_element",
             description: "Delete an element. Connectors attached to a deleted shape stay in place as free arrows.",
             inputSchema: schema(["path": pathProp, "id": prop("string", "Element id (its page is found from it)")], required: ["path", "id"])),
        Tool(name: "list_elements",
             description: "List every element on a page with id, kind, bounds, text and connector endpoints.",
             inputSchema: schema(["path": pathProp, "page": pageProp], required: ["path"])),
        Tool(name: "list_pages",
             description: "List the drawing's pages (tabs) in order, with id, name and element count. Links can point at shapes on any page.",
             inputSchema: schema(["path": pathProp], required: ["path"])),
        Tool(name: "add_page",
             description: "Add an empty page (tab) to the drawing. Returns its name, which other tools take as 'page'.",
             inputSchema: schema([
                "path": pathProp,
                "name": prop("string", "Page name; default \"Page N\". A number is added if the name is taken"),
                "after": prop("string", "Insert after this page (name or number); default at the end"),
             ], required: ["path"])),
        Tool(name: "rename_page",
             description: "Rename a page (tab).",
             inputSchema: schema(["path": pathProp, "page": prop("string", "Page to rename, by name or 1-based number"),
                                  "name": prop("string", "New name")], required: ["path", "page", "name"])),
        Tool(name: "auto_layout",
             description: "Re-arrange all shapes into ranks, using existing connectors as edges.",
             inputSchema: schema(["path": pathProp, "page": pageProp,
                                  "direction": prop("string", "TB (default) or LR", enum: ["TB", "LR"])], required: ["path"])),
        Tool(name: "export_png",
             description: "Render the diagram to a PNG and return it as an image so you can check the result. "
                + "Optionally also save it to out_path. Set sketchy=false to render the same drawing clean. "
                + "Also returns a JSON map of element id to kind, text and pixel box in the image, so you can refer to what you see.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "scale": prop("number", "Pixel scale, default 2"),
                "sketchy": prop("boolean", "Override the look for this render only"),
                "out_path": prop("string", "Optional absolute path ending in .png to also write the image to"),
             ], required: ["path"])),
        Tool(name: "export_svg",
             description: "Export the diagram as SVG using the same sketchy paths as the app. Returns the SVG text, "
                + "or writes it to out_path (preferred for large diagrams).",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "sketchy": prop("boolean", "Override the look for this export only"),
                "transparent": prop("boolean", "Omit the white page background"),
                "out_path": prop("string", "Optional absolute path ending in .svg to write the file to"),
             ], required: ["path"])),
    ]

    func call(name: String, arguments: [String: Value]) -> CallTool.Result {
        do {
            return try run(name, Args(raw: arguments))
        } catch let e as ToolFailure {
            return .init(content: [.plain(e.message)], isError: true)
        } catch {
            return .init(content: [.plain("\(error)")], isError: true)
        }
    }

    /// The built-in library plus the user's, optionally only the one called `name`.
    private func stencilLibraries(named name: String? = nil) -> [StencilLibrary] {
        let all = [StencilLibrary.starter] + StencilLibrary.load(directory: StencilLibrary.defaultDirectory).map(\.library)
        guard let name else { return all }
        return all.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
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

    private func load(_ url: URL, createIfMissing: Bool = false) throws -> DottieFile {
        // Live mode: if the Dottie app has this file open, edit that copy instead of the file on disk.
        if url == Self.currentURL {
            guard let live = LiveClient.get(path: "current") else {
                throw ToolFailure(message: "No Dottie window to draw in. Open or create a document in the Dottie app (it must be running), or pass an absolute .dottie path.")
            }
            return live
        }
        if let live = LiveClient.get(path: url.path) { return live }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if createIfMissing { return DottieFile() }
            throw ToolFailure(message: "No such file: \(url.path). Call create_diagram or build_diagram first.")
        }
        do { return try DottieFile.decode(try Data(contentsOf: url)) }
        catch { throw ToolFailure(message: "Could not read \(url.path) as a Dottie file: \(error)") }
    }

    /// The page a tool works on: `page` when given, else the page holding `element`, else the first.
    private func pageIndex(_ file: DottieFile, _ a: Args, element: UUID? = nil) throws -> Int {
        if let spec = a.string("page"), !spec.isEmpty {
            guard let i = file.pageIndex(matching: spec) else {
                throw ToolFailure(message: "No page '\(spec)'. Pages: " + file.pages.map { "\"\($0.name)\"" }.joined(separator: ", "))
            }
            return i
        }
        if let element {
            guard let i = file.pageIndex(containing: element) else { throw ToolFailure(message: "No element \(element.uuidString) on any page") }
            return i
        }
        return 0
    }

    /// Names the page in a reply when the drawing has more than one, so an agent knows where it worked.
    private func on(_ file: DottieFile, _ i: Int) -> String {
        file.pages.count > 1 ? " on page \"\(file.pages[i].name)\"" : ""
    }

    private func save(_ doc: DottieFile, to url: URL) throws {
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

    private func text(_ s: String) -> CallTool.Result { .init(content: [.plain(s)]) }

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
            try save(DottieFile(), to: url)
            return text("Created \(url.path)")

        case "build_diagram":
            let url = try fileURL(a)
            var file = try load(url, createIfMissing: true)
            let p = try pageIndex(file, a)
            guard let nodeArgs = a.array("nodes"), !nodeArgs.isEmpty else { throw ToolFailure(message: "'nodes' must be a non-empty array") }
            let nodes = try nodeArgs.map { n in
                DiagramOps.NodeSpec(key: try n.require("key"), text: n.string("text") ?? "", kind: try n.kind("kind"),
                                    fill: try n.color("fill"), width: n.double("width"), height: n.double("height"))
            }
            let edges = try (a.array("edges") ?? []).map { e in
                DiagramOps.EdgeSpec(from: try e.require("from"), to: try e.require("to"),
                                    routing: try e.routing("routing"), arrow: e.bool("arrow") ?? true, label: e.string("label"))
            }
            let direction = LayoutDirection(rawValue: a.string("direction") ?? "TB") ?? .topToBottom
            let ids: [String: UUID]
            do {
                ids = try DiagramOps.build(&file.pages[p], nodes: nodes, edges: edges, direction: direction, roughness: a.roughness ?? 1)
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            let map = ids.mapValues(\.uuidString)
            return text("Added \(nodes.count) nodes and \(edges.count) edges to \(url.path)\(on(file, p)).\n" + (try json(map)))

        case "add_shape":
            let url = try fileURL(a)
            var file = try load(url, createIfMissing: true)
            let p = try pageIndex(file, a)
            guard let x = a.double("x"), let y = a.double("y") else { throw ToolFailure(message: "'x' and 'y' are required") }
            var frame: CGRect?
            if let w = a.double("width"), let h = a.double("height") { frame = CGRect(x: x, y: y, width: w, height: h) }
            let e = try DiagramOps.addShape(&file.pages[p], kind: try a.kind("kind"), frame: frame, at: CGPoint(x: x, y: y),
                                            text: a.string("text"), fill: try a.color("fill"), stroke: try a.color("stroke"),
                                            roughness: a.roughness, look: try a.look())
            try save(file, to: url)
            return text("id: \(e.id.uuidString)\nframe: x=\(e.x) y=\(e.y) w=\(e.width) h=\(e.height)" + on(file, p))

        case "add_connector":
            let url = try fileURL(a)
            var file = try load(url)
            let from = try a.uuid("from_id"), to = try a.uuid("to_id")
            let p = try pageIndex(file, a, element: from)
            if a.string("page") == nil, let q = file.pageIndex(containing: to), q != p {
                throw ToolFailure(message: "The shapes are on different pages (\"\(file.pages[p].name)\" and \"\(file.pages[q].name)\"). "
                    + "A connector joins shapes on one page; to point across pages, set a link with update_element.")
            }
            let c: Element
            do {
                c = try DiagramOps.addConnector(&file.pages[p], from: from, to: to,
                                                routing: try a.routing("routing") ?? .straight, arrow: a.bool("arrow") ?? true,
                                                roughness: a.roughness, label: a.string("label"), look: try a.look())
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text("id: \(c.id.uuidString)")

        case "update_element":
            let url = try fileURL(a)
            var file = try load(url)
            let id = try a.uuid("id")
            let p = try pageIndex(file, a, element: id)
            var link: UUID?? = nil
            if let s = a.string("link") { link = .some(s.isEmpty ? nil : try a.uuid("link")) }
            do {
                try DiagramOps.update(&file.pages[p], id: id, text: a.string("text").map { Optional($0) },
                                      x: a.double("x"), y: a.double("y"), width: a.double("width"), height: a.double("height"),
                                      fill: try a.color("fill"), stroke: try a.color("stroke"), roughness: a.roughness,
                                      routing: try a.routing("routing"), look: try a.look(), link: link,
                                      anchor: a.string("anchor").map { Optional($0) }, otherPages: file.pages)
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text("Updated")

        case "script_api":
            let installed = DottieScript.installedModules()
            return text(DottieScript.apiReference + "\n\nInstalled modules for require(): "
                + (installed.isEmpty ? "none (add .js files to \(DottieScript.modulesDirectory.path))" : installed.joined(separator: ", ")))

        case "run_script":
            let url = try fileURL(a)
            var file = try load(url, createIfMissing: true)
            let p = try pageIndex(file, a)
            var doc = file.pages[p]
            let before = doc
            let code = try a.require("code")
            let limit = min(max(a.double("timeout") ?? DottieScript.defaultTimeLimit, 1), 60)
            let modules = (a.raw["modules"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            let result = DottieScript.run(code, on: &doc, in: file, modules: modules, timeLimit: limit)
            var report = result.logs.joined(separator: "\n")
            func append(_ line: String) { report += (report.isEmpty ? "" : "\n") + line }
            if let error = result.error {
                append("Script error: \(error)")
                append("Nothing was changed.")
                return .init(content: [.plain(report)], isError: true)
            }
            if doc != before {
                file.pages[p] = doc
                try save(file, to: url)
                append("Applied\(on(file, p)): \(doc.elements.count) elements now (was \(before.elements.count)).")
            }
            else { append("No changes.") }
            if let value = result.value { append("Result: \(value)") }
            var content: [Tool.Content] = [.plain(report)]
            if a.bool("render") == true, !doc.elements.isEmpty {
                let scale = min(max(a.double("scale") ?? 2, 0.25), 4)
                if let png = Exporter.png(doc, scale: scale) {
                    content.insert(.png(png), at: 0)
                }
            }
            return .init(content: content)

        case "list_stencils":
            struct Row: Encodable { var library: String; var name: String; var tags: [String]; var width: Double; var height: Double }
            let query = a.string("query")?.lowercased()
            let rows = stencilLibraries(named: a.string("library"))
                .flatMap { lib in lib.items.map { Row(library: lib.name, name: $0.name, tags: $0.tags, width: $0.width, height: $0.height) } }
                .filter { r in
                    guard let q = query else { return true }
                    return r.name.lowercased().contains(q) || r.tags.contains { $0.lowercased().contains(q) }
                }
            return text(try json(rows))

        case "add_stencil":
            let url = try fileURL(a)
            var file = try load(url, createIfMissing: true)
            let p = try pageIndex(file, a)
            guard let x = a.double("x"), let y = a.double("y") else { throw ToolFailure(message: "'x' and 'y' are required") }
            let wanted = try a.require("name")
            guard let item = stencilLibraries(named: a.string("library")).flatMap(\.items).first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw ToolFailure(message: "No stencil named '\(wanted)'. Call list_stencils to see what is available.")
            }
            let (ids, size) = DiagramOps.addStencil(&file.pages[p], item: item, x: x, y: y, scale: a.double("scale") ?? 1,
                                                    keepOriginalColors: a.bool("keep_original_colors") ?? false,
                                                    roughness: a.roughness)
            try save(file, to: url)
            return text("Placed '\(item.name)' (\(ids.count) elements) at x=\(x) y=\(y)\(on(file, p)), \(Int(size.width))x\(Int(size.height)).\n"
                + (try json(ids.map(\.uuidString).sorted())))

        case "open_document":
            let url = try fileURL(a)
            if url == Self.currentURL { throw ToolFailure(message: "\"current\" is already open; pass the file's absolute path.") }
            if !FileManager.default.fileExists(atPath: url.path) {
                guard a.bool("create") == true else {
                    throw ToolFailure(message: "No such file: \(url.path). Pass create=true to make it, or call create_diagram.")
                }
                try save(DottieFile(), to: url)
            }
            if LiveClient.get(path: url.path) != nil { return text("\(url.path) is already open in Dottie; edits are live.") }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", "Dottie", url.path]
            open.standardError = FileHandle.nullDevice
            try? open.run()
            open.waitUntilExit()
            if open.terminationStatus != 0 {
                // No app named Dottie registered: let Launch Services pick the handler for .dottie.
                let fallback = Process()
                fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                fallback.arguments = [url.path]
                try? fallback.run()
                fallback.waitUntilExit()
                guard fallback.terminationStatus == 0 else {
                    throw ToolFailure(message: "Could not open \(url.path) in Dottie. Is the app installed?")
                }
            }
            // The window registers with the live server shortly after it appears.
            for _ in 0..<40 {
                if LiveClient.get(path: url.path) != nil { return text("Opened \(url.path) in Dottie; edits are live.") }
                Thread.sleep(forTimeInterval: 0.125)
            }
            return text("Asked Dottie to open \(url.path), but it has not reported in yet. Edits will go to the file until it does.")

        case "delete_element":
            let url = try fileURL(a)
            var file = try load(url)
            let id = try a.uuid("id")
            let p = try pageIndex(file, a, element: id)
            do { try DiagramOps.delete(&file.pages[p], id: id) } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text("Deleted")

        case "list_elements":
            let file = try load(try fileURL(a))
            let p = try pageIndex(file, a)
            let list = try json(DiagramOps.summarize(file.pages[p]))
            guard file.pages.count > 1 else { return text(list) }
            return text("Page \"\(file.pages[p].name)\" (\(p + 1) of \(file.pages.count); see list_pages for the others).\n" + list)

        case "list_pages":
            struct Row: Encodable { var number: Int; var id: String; var name: String; var elements: Int }
            let file = try load(try fileURL(a))
            return text(try json(file.pages.enumerated().map {
                Row(number: $0.offset + 1, id: $0.element.id.uuidString, name: $0.element.name, elements: $0.element.elements.count)
            }))

        case "add_page":
            let url = try fileURL(a)
            var file = try load(url, createIfMissing: true)
            var after = file.pages.last?.id
            if let spec = a.string("after"), !spec.isEmpty {
                guard let i = file.pageIndex(matching: spec) else { throw ToolFailure(message: "No page '\(spec)'") }
                after = file.pages[i].id
            }
            let id = file.addPage(name: a.string("name"), after: after)
            try save(file, to: url)
            let i = file.index(of: id)!
            return text("Added page \"\(file.pages[i].name)\" (\(i + 1) of \(file.pages.count))")

        case "rename_page":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            file.renamePage(file.pages[p].id, to: try a.require("name"))
            try save(file, to: url)
            return text("Renamed to \"\(file.pages[p].name)\"")

        case "auto_layout":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            DiagramOps.autoLayout(&file.pages[p], direction: LayoutDirection(rawValue: a.string("direction") ?? "TB") ?? .topToBottom)
            try save(file, to: url)
            return text("Re-laid out \(file.pages[p].elements.filter { $0.kind != .connector }.count) shapes" + on(file, p))

        case "export_png":
            let file = try load(try fileURL(a))
            var doc = file.pages[try pageIndex(file, a)]
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
            let map = DiagramOps.annotations(doc, scale: scale)
            return .init(content: [.png(png),
                                   .plain(note + "\nElements in the image (pixels from its top-left):\n" + (try json(map)))])

        case "export_svg":
            let file = try load(try fileURL(a))
            var doc = file.pages[try pageIndex(file, a)]
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
