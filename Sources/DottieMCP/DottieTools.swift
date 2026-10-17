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

private let transitionValues = Transition.allCases.map(\.rawValue)
private let entranceValues = ["popIn", "growIn", "wipeIn", "dropIn", "slideIn", "drawIn", "fadeIn"]
private let easeValues = Ease.allCases.map(\.rawValue)
private let pathProp = prop("string", "Absolute path to a .dottie file, or \"current\" for the frontmost open Dottie window (needs the app running)")
private let pageProp = prop("string", "Page (tab) to work on, by name or 1-based number; default the first page. "
    + "Tools given an element id find its page themselves.")
private let kindValues = ["rectangle", "ellipse", "diamond", "text", "note"]
private let routingValues = ["straight", "curved", "elbow"]
private let fillStyleValues = ["solid", "hachure", "crossHatch", "grid"]
private let dashValues = ["solid", "dashed", "dotted"]
private let headValues = ["none", "arrow", "triangle", "dot", "bar"]

/// Look options shared by add_shape, add_connector and update_element.
private let lookProps: [String: Value] = [
    "fill_style": prop("string", "How the fill is painted: solid, pen-shaded hachure / crossHatch, or grid (a dungeon floor: "
        + "the fill ruled into square cells on a page-wide lattice, with Dyson hatching in the rock around it)", enum: fillStyleValues),
    "grid_size": prop("number", "Cell size of a grid fill in points, 8 to 400 (default 50)"),
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
        guard let kind = ElementKind(rawValue: s), kind != .connector, kind != .path, kind != .image else {
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
    /// A list of element ids (or a single one given as a string).
    func uuids(_ k: String) throws -> [UUID]? {
        guard let v = raw[k] else { return nil }
        let strings = v.arrayValue?.compactMap(\.stringValue) ?? v.stringValue.map { [$0] } ?? []
        return try strings.map { s in
            guard let u = UUID(uuidString: s) else { throw ToolFailure(message: "'\(k)' has an invalid element id: \(s)") }
            return u
        }
    }
    /// Seconds into an animation: required, finite, within the longest timeline.
    func time(_ k: String) throws -> Double {
        guard let t = double(k), t.isFinite, t >= 0, t <= Timeline.maxDuration else {
            throw ToolFailure(message: "'\(k)' must be a time in seconds, 0 to \(Int(Timeline.maxDuration))")
        }
        return t
    }

    private func enumValue<T: RawRepresentable>(_ k: String, _ values: [String]) throws -> T? where T.RawValue == String {
        guard let s = string(k) else { return nil }
        guard let v = T(rawValue: s) else { throw ToolFailure(message: "'\(k)' must be one of \(values.joined(separator: ", ")), got '\(s)'") }
        return v
    }

    func look() throws -> DiagramOps.Look {
        DiagramOps.Look(fillStyle: try enumValue("fill_style", fillStyleValues), dash: try enumValue("dash", dashValues),
                        strokeWidth: double("stroke_width"), bowing: double("bowing"),
                        startHead: try enumValue("start_head", headValues), endHead: try enumValue("end_head", headValues),
                        rotation: double("rotation"), gridSize: double("grid_size"))
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
        Tool(name: "import_mermaid",
             description: "Draw a Mermaid flowchart (text starting with `flowchart` or `graph`): nodes, shapes, labelled, dashed, "
                + "thick and two-way links, laid out like build_diagram and appended below existing content. Subgraphs are "
                + "flattened and styling other than fill colors is ignored. Returns a map of Mermaid node id to element id.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "mermaid": prop("string", "Mermaid flowchart source, e.g. \"flowchart LR\\n  A[Start] --> B{OK?}\""),
                "sketchy": prop("boolean", "Hand-drawn look (default true); false for precise geometry"),
             ], required: ["path", "mermaid"])),
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
        Tool(name: "add_image",
             description: "Place a picture (PNG, JPEG, HEIC, GIF, TIFF, …) from a file with its top-left corner at x, y. "
                + "It is embedded in the drawing. Give width or height to scale it (the other follows the aspect ratio), or "
                + "neither for its own size, capped at 640 points. Returns its element id.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "image_path": prop("string", "Absolute path of the image file"),
                "x": prop("number", "Left edge"), "y": prop("number", "Top edge"),
                "width": prop("number", "Width"), "height": prop("number", "Height"),
             ], required: ["path", "image_path", "x", "y"])),
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
             description: "Change text (a connector's text is its label), position, size, colors, look or routing of an element, "
                + "or what clicking it does when the drawing plays on the web. Only provided fields change.",
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
                "click_scene": prop("string", "When the drawing plays on the web (HTML export, <dottie-player>), clicking this element "
                    + "jumps to the scene of this name (see add_scene) and plays on to the next one. Empty string removes the click"),
                "click_url": prop("string", "When played on the web, clicking this element opens this http(s) or mailto link in a "
                    + "new tab. Empty string removes the click"),
                "hover_stroke": prop("string", "Hex stroke color while the pointer is over a clickable element; empty string clears it"),
                "hover_fill": prop("string", "Hex fill color while the pointer is over a clickable element; empty string clears it"),
                "hover_opacity": prop("number", "Opacity 0-1 while the pointer is over a clickable element; -1 clears it"),
                "playback": prop("string", "For a symbol instance: loop, once or still", enum: SymbolPlayback.allCases.map(\.rawValue)),
                "offset": prop("number", "For a symbol instance: seconds into its symbol's animation at the page's start"),
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
        Tool(name: "make_symbol",
             description: "Turn shapes into a symbol (a Flash-style movie clip): a drawing defined once, with its own animation, "
                + "that any number of instances show, each playing it on its own clock. The shapes, the arrows between them and "
                + "their keyframes move into the symbol, put back as one instance where they were; arrows and links from outside "
                + "attach to the instance. The symbol's animation is as long as the page timeline when it is made, so set the "
                + "timeline's duration to the loop you want first. Returns the symbol id and the instance id.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "ids": .object(["type": "array", "items": .object(["type": "string"]), "description": "Element ids to turn into the symbol"]),
                "name": prop("string", "The symbol's name"),
             ], required: ["path", "ids"])),
        Tool(name: "place_symbol",
             description: "Place another instance of a symbol (see make_symbol) with its top-left corner at x, y. Instances move, "
                + "resize, turn, fade and take keys like shapes. An animated symbol gives a still page a timeline, so it plays when "
                + "exported. Returns the instance id.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "symbol": prop("string", "The symbol's id or name"),
                "x": prop("number", "Left edge"), "y": prop("number", "Top edge"),
                "width": prop("number", "Width (default the symbol's; give one of width or height to keep its shape)"),
                "height": prop("number", "Height"),
                "playback": prop("string", "loop (default), once, or still (its poster frame)", enum: SymbolPlayback.allCases.map(\.rawValue)),
                "offset": prop("number", "Seconds into the symbol's animation at the page's start, so copies don't move in step"),
             ], required: ["path", "symbol", "x", "y"])),
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
                "at": prop("number", "For an animated page, the second to draw (default its poster frame, the end)"),
             ], required: ["path"])),
        Tool(name: "export_mermaid",
             description: "Export the diagram as Mermaid flowchart text: shapes become nodes and attached connectors links "
                + "(labels, dashes, thick lines and arrowheads kept). Freehand strokes and paths are skipped. Returns the "
                + "text, or writes it to out_path.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "out_path": prop("string", "Optional absolute path ending in .mmd to write the file to"),
             ], required: ["path"])),
        Tool(name: "export_svg",
             description: "Export the diagram as SVG using the same sketchy paths as the app. Returns the SVG text, "
                + "or writes it to out_path (preferred for large diagrams).",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "sketchy": prop("boolean", "Override the look for this export only"),
                "transparent": prop("boolean", "Omit the white page background"),
                "out_path": prop("string", "Optional absolute path ending in .svg to write the file to"),
                "at": prop("number", "For an animated page, the second to draw (default its poster frame, the end)"),
             ], required: ["path"])),
        Tool(name: "set_timeline",
             description: "Animate a page, or adjust its animation: frame rate, length, hand-drawn line boil and more. "
                + "With only path (and page), reports the page's animation: length, each animated element's keys, "
                + "camera keys and scenes. Animation tools: animate_build, add_transition, add_keyframe, send_packet, "
                + "set_camera, add_scene, clear_animation; check with export_animation's preview or export_png's at.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "fps": prop("number", "Frames per second, 1-60 (default 15 for a new animation)"),
                "duration": prop("number", "Length in seconds (the tools lengthen it as they add things)"),
                "boil": prop("number", "Redraw sketchy lines every n frames so they jitter like hand-drawn animation; 0 is off"),
                "settle": prop("boolean", "Boil a shape only while it moves"),
                "poster": prop("number", "The second stills (PNG, SVG, thumbnails) show; default the end"),
             ], required: ["path"])),
        Tool(name: "animate_build",
             description: "Make the page build itself: shapes appear in the order the connectors join them, each with an "
                + "entrance, optionally drawing each arrow on or sending a dot along it first. The quickest way to "
                + "animate a diagram. Creates the timeline if there is none.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "transition": prop("string", "Entrance for each shape (default popIn)", enum: transitionValues.filter { entranceValues.contains($0) }),
                "draw_arrows": prop("boolean", "Draw each arrow on before the shape it points to enters"),
                "packets": prop("boolean", "Send a dot along each arrow before the shape it points to enters"),
                "start": prop("number", "Second to start at (default 0)"),
                "stagger": prop("number", "Seconds between ranks (default 0.4)"),
                "travel": prop("number", "Seconds an arrow takes to draw or a dot to travel (default 0.6)"),
             ], required: ["path"])),
        Tool(name: "add_transition",
             description: "Give elements a canned entrance, exit or emphasis starting at t: " + transitionValues.joined(separator: ", ")
                + ". Several ids start one after another (stagger). Connectors take drawIn, fadeIn and fadeOut only.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "ids": .object(["type": "array", "items": .object(["type": "string"]), "description": "Element ids, in the order they start"]),
                "name": prop("string", "The transition", enum: transitionValues),
                "t": prop("number", "Second it starts"),
                "duration": prop("number", "Seconds it takes (default depends on the transition)"),
                "stagger": prop("number", "Seconds between one element's start and the next (default 0.15)"),
                "repeat": prop("number", "Play it this many times in all, or 0 for forever (pulse, wiggle)"),
             ], required: ["path", "ids", "name", "t"])),
        Tool(name: "add_keyframe",
             description: "Pose an element at time t: each property given tweens from its previous key, or the first time "
                + "a property is keyed, from its value at 0 (so a color change at 5s fades in over 5s; key it again "
                + "just before to make it quicker). Position and size are in canvas points; ease is the curve from "
                + "this key to the next.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "id": prop("string", "Element id"),
                "t": prop("number", "Second of the key"),
                "x": prop("number", "Left"), "y": prop("number", "Top"),
                "width": prop("number", "Width"), "height": prop("number", "Height"),
                "rotation": prop("number", "Degrees clockwise"),
                "fill": prop("string", "Fill color, hex"), "stroke": prop("string", "Stroke color, hex"),
                "stroke_width": prop("number", "Stroke width"),
                "opacity": prop("number", "0 transparent to 1 opaque"),
                "visible": prop("boolean", "Show or hide from this key on (a lone true key is where it appears)"),
                "reveal": prop("number", "0-1: how much of the outline is drawn (draw-on)"),
                "ease": prop("string", "Curve to the next key", enum: easeValues),
             ], required: ["path", "id", "t"])),
        Tool(name: "send_packet",
             description: "Send a dot along a connector, like a request or message on its way; with a label it is a pill "
                + "carrying that text (\"POST /orders\"). every repeats it forever, so traffic keeps flowing.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "connector_id": prop("string", "The connector to travel along"),
                "t": prop("number", "Second it sets off"),
                "duration": prop("number", "Seconds the trip takes (default 0.6)"),
                "color": prop("string", "Hex color (default orange-red)"),
                "label": prop("string", "Text to carry, short"),
                "every": prop("number", "Send it again every this many seconds, forever"),
             ], required: ["path", "connector_id", "t"])),
        Tool(name: "set_camera",
             description: "Point the exported view (GIF, MP4, HTML) at part of the page from time t, easing from the previous "
                + "camera key: frame elements by id (with padding) or give a rectangle. Pans and zooms around a big "
                + "diagram. clear removes the camera, so exports show everything again.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "t": prop("number", "Second of the camera key"),
                "ids": .object(["type": "array", "items": .object(["type": "string"]), "description": "Elements to frame"]),
                "padding": prop("number", "Space around framed elements, default 40"),
                "x": prop("number", "Left of the view, instead of ids"), "y": prop("number", "Top of the view"),
                "width": prop("number", "Width of the view"), "height": prop("number", "Height of the view"),
                "ease": prop("string", "Curve to the next camera key (default easeInOut)", enum: easeValues),
                "clear": prop("boolean", "Remove the camera instead"),
             ], required: ["path"])),
        Tool(name: "add_scene",
             description: "Name a moment of the animation as a scene. The HTML export becomes a click-through presentation: it "
                + "plays to each scene and stops, and next/back step between them. Pair with set_camera.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "t": prop("number", "Second of the scene"),
                "name": prop("string", "What the scene shows; default Scene n"),
             ], required: ["path", "t"])),
        Tool(name: "clear_animation",
             description: "Remove the animation from the given elements (their keys, paths and repeats), or with no ids remove "
                + "the page's whole timeline. The drawing itself is unchanged.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "ids": .object(["type": "array", "items": .object(["type": "string"]), "description": "Elements to clear; omit for all"]),
             ], required: ["path"])),
        Tool(name: "export_animation",
             description: "Export the page's animation (made with the animation tools, or run_script's dottie.timeline/key/"
                + "transition/packet/camera/scene) as a looping GIF, an animated PNG (full color, can be transparent), "
                + "an MP4 movie, Lottie JSON (.json, vector, for lottie-web and the iOS/Android players), "
                + "or a self-contained HTML player with "
                + "play/pause and a scrubber (a click-through presentation when it has scenes). The format comes from "
                + "out_path's extension. Returns a PNG of the frame at `preview` seconds (default the poster frame) so "
                + "you can check it.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "out_path": prop("string", "Absolute path ending in .gif, .apng, .mp4, .json (Lottie) or .html"),
                "lottie_mode": prop("string", "For .json: smooth (default; tweened, lines held steady) or exact "
                                    + "(every frame as the GIF draws it, boil included)", enum: Exporter.LottieMode.allCases.map(\.rawValue)),
                "scale": prop("number", "Pixel scale for gif, apng and mp4, 0.25 to 4 (default 1.5)"),
                "transparent": prop("boolean", "No page background (apng and json only)"),
                "sketchy": prop("boolean", "Override the look for this export only"),
                "preview": prop("number", "Second of the animation to return as a PNG preview"),
             ], required: ["path", "out_path"])),
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

        case "import_mermaid":
            let url = try fileURL(a)
            let source = try a.require("mermaid")
            var file = try load(url, createIfMissing: true)
            let p = try pageIndex(file, a)
            let result: (ids: [String: UUID], notes: [String])
            do {
                result = try MermaidImporter.build(&file.pages[p], mermaid: source, roughness: a.roughness ?? 1)
            } catch let e as MermaidError { throw ToolFailure(message: e.description) }
            catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            let notes = result.notes.isEmpty ? "" : result.notes.joined(separator: "\n") + "\n"
            return text("Added \(result.ids.count) nodes from Mermaid to \(url.path)\(on(file, p)).\n" + notes
                        + (try json(result.ids.mapValues(\.uuidString))))

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

        case "add_image":
            let url = try fileURL(a)
            let source = URL(fileURLWithPath: (try a.require("image_path") as NSString).expandingTildeInPath)
            guard let x = a.double("x"), let y = a.double("y") else { throw ToolFailure(message: "'x' and 'y' are required") }
            let bytes: Data
            do { bytes = try Data(contentsOf: source) } catch { throw ToolFailure(message: "Cannot read \(source.path): \(error.localizedDescription)") }
            var file = try load(url, createIfMissing: true)
            let p = try pageIndex(file, a)
            let e: Element
            do {
                e = try DiagramOps.addImage(&file.pages[p], data: bytes, at: CGPoint(x: x, y: y), width: a.double("width"), height: a.double("height"))
            } catch { throw ToolFailure(message: "\(source.lastPathComponent): \(error)") }
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
                var click: ClickAction?? = nil
                if a.string("click_scene") != nil || a.string("click_url") != nil {
                    click = .some(try DiagramOps.click(scene: a.string("click_scene"), url: a.string("click_url")))
                }
                var hover: HoverLook?? = nil
                if a.string("hover_stroke") != nil || a.string("hover_fill") != nil || a.double("hover_opacity") != nil {
                    let base = file.pages[p].elements.first { $0.id == id }?.hover
                    hover = .some(try DiagramOps.hover(base, stroke: a.string("hover_stroke"), fill: a.string("hover_fill"),
                                                       opacity: a.double("hover_opacity")))
                }
                if let i = file.pages[p].elements.firstIndex(where: { $0.id == id }), file.pages[p].elements[i].kind == .symbol {
                    if let s = a.string("playback") {
                        guard let v = SymbolPlayback(rawValue: s) else { throw ToolFailure(message: "'playback' must be loop, once or still") }
                        file.pages[p].elements[i].playback = v == .loop ? nil : v
                    }
                    if let o = a.double("offset") { file.pages[p].elements[i].offset = o == 0 || !o.isFinite ? nil : o }
                }
                try DiagramOps.update(&file.pages[p], id: id, text: a.string("text").map { Optional($0) },
                                      x: a.double("x"), y: a.double("y"), width: a.double("width"), height: a.double("height"),
                                      fill: try a.color("fill"), stroke: try a.color("stroke"), roughness: a.roughness,
                                      routing: try a.routing("routing"), look: try a.look(), link: link,
                                      anchor: a.string("anchor").map { Optional($0) }, click: click, hover: hover,
                                      otherPages: file.pages)
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
                if let png = Exporter.png(doc.still, scale: scale) {
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

        case "make_symbol":
            let url = try fileURL(a)
            var file = try load(url)
            guard let ids = try a.uuids("ids"), let first = ids.first else { throw ToolFailure(message: "'ids' is required") }
            let p = try pageIndex(file, a, element: first)
            let name = a.string("name") ?? "Symbol \((file.pages[p].symbols?.count ?? 0) + 1)"
            guard let made = file.pages[p].makeSymbol(of: Set(ids), name: name) else {
                throw ToolFailure(message: "None of those ids is a shape on this page.")
            }
            try save(file, to: url)
            return text("symbol: \(made.symbol.id.uuidString)\ninstance: \(made.instance.id.uuidString)")

        case "place_symbol":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            guard let x = a.double("x"), let y = a.double("y") else { throw ToolFailure(message: "'x' and 'y' are required") }
            let spec = try a.require("symbol")
            let page = file.pages[p]
            guard let symbol = UUID(uuidString: spec).flatMap({ page.symbolIndex[$0] })
                    ?? page.symbols?.first(where: { $0.name.caseInsensitiveCompare(spec) == .orderedSame }) else {
                throw ToolFailure(message: "No symbol '\(spec)' on this page. Make one with make_symbol.")
            }
            var size: CGSize?
            switch (a.double("width"), a.double("height")) {
            case let (w?, h?): size = CGSize(width: w, height: h)
            case let (w?, nil): size = CGSize(width: w, height: w * symbol.height / symbol.width)
            case let (nil, h?): size = CGSize(width: h * symbol.width / symbol.height, height: h)
            default: break
            }
            var playback: SymbolPlayback?
            if let s = a.string("playback") {
                guard let v = SymbolPlayback(rawValue: s) else { throw ToolFailure(message: "'playback' must be loop, once or still") }
                playback = v
            }
            guard let e = file.pages[p].placeSymbol(symbol.id, at: CGPoint(x: x, y: y), size: size, playback: playback,
                                                    offset: a.double("offset")) else { throw ToolFailure(message: "Couldn't place it") }
            try save(file, to: url)
            return text("id: \(e.id.uuidString)")

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
            let page = file.pages[try pageIndex(file, a)]
            var doc = a.double("at").map(page.resolved) ?? page.still
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

        case "export_mermaid":
            let file = try load(try fileURL(a))
            let doc = file.pages[try pageIndex(file, a)].still
            guard !doc.elements.isEmpty else { throw ToolFailure(message: "The diagram is empty; nothing to export") }
            let mermaid = Exporter.mermaid(doc)
            guard a.string("out_path") != nil else { return text(mermaid) }
            let out = try fileURL(a, key: "out_path", ext: "mmd")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try mermaid.write(to: out, atomically: true, encoding: .utf8)
            return text("Exported Mermaid to \(out.path)")

        case "export_svg":
            let file = try load(try fileURL(a))
            let page = file.pages[try pageIndex(file, a)]
            var doc = a.double("at").map(page.resolved) ?? page.still
            if let r = a.roughness { doc = doc.withRoughness(r) }
            guard !doc.elements.isEmpty else { throw ToolFailure(message: "The diagram is empty; nothing to export") }
            let svg = Exporter.svg(doc, background: a.bool("transparent") == true ? nil : RGBA(r: 1, g: 1, b: 1))
            guard a.string("out_path") != nil else { return text(svg) }
            let out = try fileURL(a, key: "out_path", ext: "svg")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try svg.write(to: out, atomically: true, encoding: .utf8)
            return text("Exported \(doc.elements.count) elements to \(out.path)")

        case "set_timeline", "animate_build", "add_transition", "add_keyframe", "send_packet", "set_camera", "add_scene",
             "clear_animation":
            return try animation(name, a)

        case "export_animation":
            let file = try load(try fileURL(a))
            var doc = file.pages[try pageIndex(file, a)]
            if let r = a.roughness { doc = doc.withRoughness(r) }
            guard let timeline = doc.timeline else {
                throw ToolFailure(message: "This page has no animation; add one with run_script (dottie.timeline, dottie.key, ...)")
            }
            let raw = try a.require("out_path")
            let ext = URL(fileURLWithPath: raw).pathExtension.lowercased()
            guard ["gif", "apng", "mp4", "json", "html"].contains(ext) else {
                throw ToolFailure(message: "'out_path' must end in .gif, .apng, .mp4, .json or .html")
            }
            let lottieMode = try a.string("lottie_mode").map { s -> Exporter.LottieMode in
                guard let m = Exporter.LottieMode(rawValue: s) else { throw ToolFailure(message: "'lottie_mode' must be smooth or exact") }
                return m
            } ?? .smooth
            let out = try fileURL(a, key: "out_path", ext: ext)
            let scale = min(max(a.double("scale") ?? 1.5, 0.25), 4)
            guard !Exporter.animationTooLong(doc) else {
                throw ToolFailure(message: "The animation has more than \(Exporter.maxAnimationFrames) frames; shorten it or lower its fps")
            }
            let data: Data? = switch ext {
            case "gif": Exporter.gif(doc, scale: scale)
            case "apng": Exporter.apng(doc, scale: scale, background: a.bool("transparent") == true ? nil : CGColor(gray: 1, alpha: 1))
            case "mp4": Exporter.mp4(doc, scale: scale)
            case "json": Exporter.lottie(doc, mode: lottieMode, transparent: a.bool("transparent") == true, name: doc.name)
            default: Exporter.player(doc, title: doc.name).map { Data($0.utf8) }
            }
            guard let data else { throw ToolFailure(message: "Rendering failed") }
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: out, options: .atomic)
            let frame = a.double("preview").map(doc.resolved) ?? doc.still
            var content: [Tool.Content] = [.plain("Exported \(timeline.frameCount) frames (\(timeline.duration)s at \(timeline.fps) fps) "
                                                  + "to \(out.path)")]
            if !frame.elements.isEmpty, let png = Exporter.png(frame, scale: 1) { content.insert(.png(png), at: 0) }
            return .init(content: content)

        default:
            throw ToolFailure(message: "Unknown tool '\(name)'")
        }
    }
}

// MARK: Animation tools

extension DottieTools {
    /// The animation tools: each edits one page's timeline and saves, like the other edit tools.
    fileprivate func animation(_ name: String, _ a: Args) throws -> CallTool.Result {
        let url = try fileURL(a)
        var file = try load(url)
        let p = try pageIndex(file, a, element: (try? a.uuids("ids"))??.first ?? (try? a.uuid("id")) ?? (try? a.uuid("connector_id")))
        var doc = file.pages[p]
        func elementOnPage(_ id: UUID) throws -> Element {
            guard let e = doc.elements.first(where: { $0.id == id }) else {
                throw ToolFailure(message: "No element \(id.uuidString) on page \"\(doc.name)\"")
            }
            return e
        }
        func ensure() { if doc.timeline == nil { doc.startAnimation(duration: 0) } }
        let reply: String
        do {
            switch name {
            case "set_timeline":
                let changes = ["fps", "duration", "boil", "settle", "poster"].contains { a.raw[$0] != nil }
                if changes {
                    ensure()
                    if let v = a.double("fps") { doc.timeline!.fps = v }
                    if let v = a.double("duration") { doc.timeline!.duration = v }
                    if let v = a.double("boil") { doc.timeline!.boil = Int(max(0, min(v, 10_000))) }
                    if let v = a.bool("settle") { doc.timeline!.settle = v ? true : nil }
                    if let v = a.double("poster") { doc.timeline!.poster = v }
                }
                guard let tl = doc.timeline else { return text("Page \"\(doc.name)\" has no animation yet.") }
                if !changes { return text(Self.describe(tl, in: doc)) }
                reply = "Timeline: \(Self.secs(tl.duration)) at \(tl.fps) fps, boil \(tl.boil.map(String.init) ?? "off")"
            case "animate_build":
                ensure()
                let tr = try a.string("transition").map { s -> Transition in
                    guard let t = Transition(rawValue: s) else { throw ToolFailure(message: "Unknown transition '\(s)'") }
                    return t
                } ?? .popIn
                try doc.addBuild(tr, at: a.double("start") ?? 0, stagger: a.double("stagger") ?? 0.4,
                                 packets: a.bool("packets") ?? false, drawArrows: a.bool("draw_arrows") ?? false,
                                 travel: a.double("travel") ?? 0.6)
                reply = "The page now builds itself over \(Self.secs(doc.timeline!.duration))"
            case "add_transition":
                guard let ids = try a.uuids("ids"), !ids.isEmpty else { throw ToolFailure(message: "'ids' must list element ids") }
                for id in ids { _ = try elementOnPage(id) }
                guard let tr = Transition(rawValue: try a.require("name")) else {
                    throw ToolFailure(message: "'name' must be one of \(transitionValues.joined(separator: ", "))")
                }
                let t = try a.time("t")
                ensure()
                let stagger = (a.double("stagger") ?? 0.15).isFinite ? min(max(a.double("stagger") ?? 0.15, 0), 60) : 0.15
                let repeats = a.double("repeat").flatMap { r -> Int?? in
                    guard r.isFinite, r == 0 || r >= 2 else { return nil }
                    return .some(r == 0 ? nil : Int(min(r, 10_000)))   // nil inside: forever
                }
                // Element by element, so each repeat covers exactly the transition it was given.
                var n = 0
                for id in ids where (try? elementOnPage(id))?.kind != .connector || tr.appliesToConnectors {
                    let span = try doc.addTransition(tr, to: id, at: t + Double(n) * stagger, duration: a.double("duration"))
                    if let count = repeats { doc.timeline!.addRepeat(for: id, from: span.start, to: span.end, count: count) }
                    n += 1
                }
                reply = n == ids.count ? "Added \(tr.rawValue) to \(n) element\(n == 1 ? "" : "s")"
                    : "Added \(tr.rawValue) to \(n) of \(ids.count) elements (connectors only take drawIn, fadeIn, fadeOut)"
            case "add_keyframe":
                let id = try a.uuid("id")
                _ = try elementOnPage(id)
                let t = try a.time("t")
                let ease = try a.string("ease").map { s -> Ease in
                    guard let e = Ease(rawValue: s) else { throw ToolFailure(message: "'ease' must be one of \(easeValues.joined(separator: ", "))") }
                    return e
                }
                let k = Keyframe(t: t, x: a.double("x"), y: a.double("y"), width: a.double("width"), height: a.double("height"),
                                 rotation: a.double("rotation").map { $0 * .pi / 180 }, strokeWidth: a.double("stroke_width"),
                                 stroke: try a.color("stroke"), fill: try a.color("fill"), visible: a.bool("visible"),
                                 reveal: a.double("reveal").map { min(max($0, 0), 1) },
                                 opacity: a.double("opacity").map { min(max($0, 0), 1) }, ease: ease)
                guard k != Keyframe(t: t, ease: ease) || ease != nil else { throw ToolFailure(message: "Give at least one property to key") }
                doc.addKey(k, for: id)
                reply = "Keyed at \(Self.secs(t))"
            case "send_packet":
                let c = try a.uuid("connector_id")
                let t = try a.time("t")
                ensure()
                let dot = try doc.addPacket(along: c, at: t, duration: a.double("duration") ?? 0.6,
                                            color: try a.color("color") ?? RGBA(r: 0.95, g: 0.36, b: 0.33), label: a.string("label"))
                if let every = a.double("every"), every.isFinite, every > 0.1 {
                    doc.timeline!.addRepeat(for: dot.id, from: t, to: t + every)
                }
                reply = "id: \(dot.id.uuidString)"
            case "set_camera":
                ensure()
                if a.bool("clear") == true {
                    doc.timeline!.camera = nil
                    reply = "Camera removed; exports show the whole animation"
                    break
                }
                let t = try a.time("t")
                var view: CGRect
                if let ids = try a.uuids("ids"), !ids.isEmpty {
                    let index = doc.elementIndex
                    view = try ids.map { id -> CGRect in
                        let e = try elementOnPage(id)
                        return e.kind == .connector ? Connector.bounds(of: e, in: doc, index: index) : e.rotatedBounds
                    }.reduce(CGRect.null) { $0.union($1) }
                    let pad = a.double("padding") ?? 40
                    view = view.insetBy(dx: -pad, dy: -pad)
                } else if let x = a.double("x"), let y = a.double("y"), let w = a.double("width"), let h = a.double("height"), w > 1, h > 1 {
                    view = CGRect(x: x, y: y, width: w, height: h)
                } else {
                    throw ToolFailure(message: "Give ids to frame, or x, y, width and height, or clear")
                }
                let ease = try a.string("ease").map { s -> Ease in
                    guard let e = Ease(rawValue: s) else { throw ToolFailure(message: "'ease' must be one of \(easeValues.joined(separator: ", "))") }
                    return e
                }
                doc.timeline!.setCamera(CameraKey(t: t, rect: view, ease: ease))
                reply = "Camera at \(Self.secs(t)): x \(Int(view.minX)), y \(Int(view.minY)), \(Int(view.width))x\(Int(view.height))"
            case "add_scene":
                let t = try a.time("t")
                ensure()
                let label = a.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? "Scene \((doc.timeline!.markers?.count ?? 0) + 1)"
                doc.timeline!.addMarker(at: t, name: label)
                reply = "Scene \"\(label)\" at \(Self.secs(t))"
            default:  // clear_animation
                if let ids = try a.uuids("ids"), !ids.isEmpty {
                    doc.clearAnimation(of: Set(ids))
                    reply = "Cleared the animation of \(ids.count) element\(ids.count == 1 ? "" : "s")"
                } else {
                    doc.timeline = nil
                    reply = "Removed the page's animation"
                }
            }
        } catch let e as OpsError { throw ToolFailure(message: e.description) }
        file.pages[p] = doc
        try save(file, to: url)
        return text(reply + on(file, p))
    }

    /// Seconds for a reply: hundredths, no float noise.
    static func secs(_ t: Double) -> String { "\((t * 100).rounded() / 100)s" }

    /// A readable summary of a timeline, for set_timeline with no changes.
    static func describe(_ tl: Timeline, in doc: DottieDocument) -> String {
        var lines = ["\(secs(tl.duration)) at \(tl.fps) fps, boil \(tl.boil.map(String.init) ?? "off")\(tl.settle == true ? ", settles" : "")"
                     + (tl.poster.map { ", poster \(secs($0))" } ?? "")]
        let rows = TimelineRows(doc)
        for group in rows.groups {
            for row in group.rows {
                let keys = row.keys.map { k in "\((k.t * 100).rounded() / 100)s " + k.sets.map(\.rawValue).sorted().joined(separator: "+") }
                lines.append("- \(row.label) (\(row.element.uuidString)): " + (keys.isEmpty ? "path or repeat only" : keys.joined(separator: ", ")))
            }
        }
        if let cam = tl.camera, !cam.isEmpty { lines.append("camera keys at " + cam.map { secs($0.t) }.joined(separator: ", ")) }
        if let m = tl.markers, !m.isEmpty { lines.append("scenes: " + m.map { "\(secs($0.t)) \"\($0.name)\"" }.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
