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
private let fontProp = prop("string", "Font for the text: Caveat, Patrick Hand or Architects Daughter (handwriting, embedded in exports), "
        + "Helvetica Neue (the default), or any font installed on this Mac (named in exports, not embedded)")

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
    "font": fontProp,
    "font_size": prop("number", "Text size in points, 4 to 200 (default 18; notes 16)"),
    "waypoints": .object(["type": "array", "items": .object(["type": "object", "required": .array(["x", "y"]),
                                                              "properties": .object(["x": .object(["type": "number"]), "y": .object(["type": "number"])])]),
                          "description": .string("Connectors: canvas points the line bends through, start to end, e.g. [{\"x\":300,\"y\":40}] "
                              + "to route it round something in the way. An elbow line passes through each with right angles. [] removes them")]),
    "hops": prop("boolean", "Connectors: draw a small hop where this line crosses a connector drawn beneath it"),
    "avoid": prop("boolean", "Elbow connectors: go round the shapes in the way instead of through them (on for new elbow "
                  + "connectors, except build_diagram's, which its layout routes; false keeps the plain Z or L)"),
    "cost": prop("number", "Connectors: what add_flow traffic pays to take this line, default 1. Flows take the cheapest "
                 + "route, so give a main path a lower cost than its backup (or the backup a higher one)"),
    "text_color": prop("string", "Hex color of a shape's or connector's label; \"\" follows the stroke again. Setting stroke on "
                        + "update_element recolors the label too, as in Excalidraw"),
]

/// The look fields a connector takes, for build_diagram's edges.
private let edgeLookProps = lookProps.filter { ["dash", "stroke_width", "bowing", "start_head", "end_head", "font", "font_size", "hops",
                                                 "avoid", "text_color", "cost"].contains($0.key) }

/// build_diagram's edge fields: what a connector is made with, and its look.
private let buildEdgeProps: [String: Value] = {
    let own: [String: Value] = [
        "from": prop("string", "Source node key"),
        "to": prop("string", "Target node key"),
        "routing": prop("string", "Default elbow", enum: routingValues),
        "arrow": prop("boolean", "Arrowhead at the target, default true"),
        "label": prop("string", "Text shown on the connector, e.g. \"yes\""),
        "stroke": prop("string", "Hex line color, e.g. #888888"),
        "when": whenProp,
    ]
    return own.merging(edgeLookProps) { a, _ in a }
}()

private let clickSetDescription = "When played on the web, clicking this element gives these page variables (see "
    + "set_variable) these values, e.g. {\"down\": true}, without stopping or moving the animation. A value can be a "
    + "number, or an expression worked out from the state before the click: {\"count\": \"count + 1\"}, "
    + "{\"stage\": \"(stage + 1) % 3\"}. "
    + "Combines with click_scene or click_url. Any click_ field replaces the whole click"
private let clickSetProp: Value = .object(["type": "object", "additionalProperties": .object(["type": .array([.string("boolean"), .string("number"), .string("string")])]),
                                           "description": .string(clickSetDescription)])
private let clickToggleDescription = "Page variables a click flips, e.g. \"down\": a button that takes a region down "
    + "and back while packets keep flowing"
private let exportStateProp: Value = .object(["type": "object", "additionalProperties": .object(["type": "boolean"]),
    "description": .string("Starting values for the page's variables here, e.g. {\"down\": true}: frames show that state, "
        + "and an HTML player starts in it")])
private let simulateStepItem: Value = .object(["type": "object", "properties": .object([
    "click": .object(["type": "string"]), "wait": .object(["type": "number"]),
    "next": .object(["type": "boolean"]), "back": .object(["type": "boolean"]), "snapshot": .object(["type": .array(["string", "boolean"])]),
    "metrics": .object(["type": "boolean"]), "routes": .object(["type": "boolean"]),
])])
private let simulateStepsProp: Value = .object(["type": "array", "items": simulateStepItem,
    "description": .string("In order. Each is one of {\"click\": element id, its first characters, its text or anchor}, "
        + "{\"wait\": seconds}, {\"next\": true} (the Next button), {\"back\": true} (the browser's Back, after a click that followed a link to another page), {\"snapshot\": true} (return a PNG) or "
        + "{\"snapshot\": \"/abs/path.png\"} (also save it) or {\"metrics\": true} (the throughput, load, backlog and "
        + "transit of what has a capacity, delay or traffic, now) or {\"routes\": true} (each flow's ways now: the "
        + "destination, the connectors with their ids, the share of its volume, the cost, and why a flow reaches "
        + "nothing; to check traffic in each state takes the path you meant, not a return edge)")])
private let stateProp: Value = .object(["type": "object", "additionalProperties": .object(["type": "boolean"]),
    "description": .string("Draw the page with its variables (set_variable) at these values instead of their starting "
        + "ones, e.g. {\"down\": true}, to check each state of an interactive page; the others keep their starting values")])
private let clickToggleProp: Value = .object(["type": .array(["string", "array"]), "items": .object(["type": "string"]),
                                              "description": .string(clickToggleDescription)])

private let whenProp = prop("string", "A condition on the page's variables (see set_variable), like \"down\", \"!down\", "
    + "\"east && !west || maint\" or \"count >= 3 && stage % 2 == 0\" (numbers, + - * / %, comparisons, parentheses, "
    + "min/max/abs/floor/ceil/round/clamp): the element, and connectors attached to it, is drawn only while it holds. On the web a click "
    + "that sets or toggles a variable shows and hides it without stopping the animation; exports show the starting values. "
    + "Empty string removes it")

private func idListProp(_ description: String) -> Value {
    .object(["type": "array", "items": .object(["type": "string"]), "description": .string(description + "; element ids")])
}
private let stateRestyleProp: Value = .object([
    "type": "object",
    "description": .string("Element id to how it looks while it is true: {stroke, fill, text_color (hex), opacity (multiplies), stroke_width, "
        + "dash, text, cost (a connector's cost for add_flow traffic: a degraded link), capacity, delay (half the workers down, a "
        + "slow step)}"),
    "additionalProperties": .object(["type": "object", "properties": .object([
        "stroke": .object(["type": "string"]), "fill": .object(["type": "string"]), "text_color": .object(["type": "string"]),
        "opacity": .object(["type": "number"]), "stroke_width": .object(["type": "number"]),
        "dash": .object(["enum": .array(["solid", "dashed", "dotted"])]), "text": .object(["type": "string"]),
        "cost": .object(["type": "number"]), "capacity": .object(["type": "number"]), "delay": .object(["type": "number"]),
    ])]),
])

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
    /// A map of names to text (a symbol's params, a copy's args); numbers and booleans become text. Empty is nil.
    func strings(_ k: String) throws -> [String: String]? {
        guard let v = raw[k], !v.isNull else { return nil }
        guard let d = v.objectValue else { throw ToolFailure(message: "'\(k)' must be an object of names to text") }
        var out: [String: String] = [:]
        for (name, x) in d where !x.isNull {
            if let t = x.stringValue { out[name] = t }
            else if let n = x.doubleValue ?? x.intValue.map(Double.init) { out[name] = n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n) }
            else if let b = x.boolValue { out[name] = String(b) }
            else { throw ToolFailure(message: "'\(k).\(name)' must be text") }
        }
        return out.isEmpty ? nil : out
    }

    /// Variable names to values (click_set): true or false, a number, or an expression computing one from the state
    /// before the click, like "count + 1" (ADR 0007).
    func flags(_ k: String) throws -> [String: ClickValue]? {
        guard let v = raw[k], !v.isNull else { return nil }
        guard let d = v.objectValue else { throw ToolFailure(message: "'\(k)' must be an object of variable names to values") }
        return try d.mapValues { x in
            if let b = x.boolValue { return .value(.bool(b)) }
            if let n = x.doubleValue ?? x.intValue.map(Double.init), n.isFinite { return .value(.number(n)) }
            if let e = x.stringValue {
                do { return .expression(try PageState.checkedValue(e)) } catch let e as OpsError { throw ToolFailure(message: e.description) }
            }
            throw ToolFailure(message: "'\(k)' values must be true, false, a number or an expression like \"count + 1\"")
        }
    }
    /// `state`: variable values to draw a page with (true, false or numbers), names checked.
    func state() throws -> [String: Var] {
        var out: [String: Var] = [:]
        for (name, x) in try flags("state") ?? [:] {
            guard PageState.isName(name) else {
                throw ToolFailure(message: "'state' names '\(name)', which can't name a variable (letters, digits and _, not starting with a digit)")
            }
            guard case .value(let v) = x else { throw ToolFailure(message: "'state' values are true, false or numbers") }
            out[name] = v
        }
        return out
    }
    /// One name or a list of them (click_toggle).
    func names(_ k: String) throws -> [String]? {
        guard let v = raw[k], !v.isNull else { return nil }
        if let one = v.stringValue { return one.isEmpty ? [] : [one] }
        guard let list = v.arrayValue?.compactMap(\.stringValue), list.count == v.arrayValue?.count else {
            throw ToolFailure(message: "'\(k)' must be a variable name or a list of them")
        }
        return list
    }

    func require(_ k: String) throws -> String {
        guard let s = string(k), !s.isEmpty else { throw ToolFailure(message: "Missing required argument '\(k)'") }
        return s
    }
    func color(_ k: String) throws -> RGBA? {
        guard let s = string(k) else { return nil }
        guard let c = RGBA.parse(s, in: DiagramOps.colorContext)?.color else {
            throw ToolFailure(message: "'\(k)' must be \(RGBA.expected(in: DiagramOps.colorContext)), got '\(s)'")
        }
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
                        rotation: double("rotation"), gridSize: double("grid_size"),
                        font: string("font"), fontSize: double("font_size"), waypoints: try points("waypoints"), hops: bool("hops"),
                        textColor: try string("text_color").map { $0.isEmpty ? nil : try color("text_color") },
                        cost: double("cost"), avoid: bool("avoid"))
    }

    /// A list of {x, y} points.
    func points(_ k: String) throws -> [CGPoint]? {
        guard raw[k] != nil else { return nil }
        guard let list = array(k) else { throw ToolFailure(message: "'\(k)' must be a list of {x, y} points") }
        return try list.map { p in
            guard let x = p.double("x"), let y = p.double("y") else { throw ToolFailure(message: "Each of '\(k)' needs a number x and y") }
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: Tools

/// Stateless: every call loads the file, edits, and saves atomically. The actor serializes calls
/// so concurrent requests can't interleave read-modify-write on the same file.
actor DottieTools {
    /// The file the current tool read, before its edits: what saving reconciles containers against (ADR 0006).
    private var loaded: DottieFile?
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
                    "properties": .object(buildEdgeProps),
                    "required": ["from", "to"],
                ])]),
                "direction": prop("string", "TB = top to bottom (default), LR = left to right", enum: ["TB", "LR"]),
                "sketchy": prop("boolean", "Hand-drawn look (default true); false for precise geometry"),
                "font": fontProp,
                "clusters": .object(["type": "array", "description": .string(
                    "Containers to lay nodes out in: titled boxes that hold them and move with them (add_container). Each "
                    + "cluster is laid out on its own, then as one block; parent nests it in another cluster, and lanes "
                    + "makes it a swimlane whose child clusters are its lanes."),
                    "items": .object(["type": "object", "properties": .object([
                        "key": .object(["type": "string"]), "title": .object(["type": "string"]),
                        "nodes": .object(["type": "array", "items": .object(["type": "string"]), "description": .string("Node keys")]),
                        "parent": .object(["type": "string", "description": .string("Another cluster's key")]),
                        "lanes": .object(["type": "string", "enum": .array([.string("rows"), .string("columns")])]),
                    ]), "required": .array([.string("key")])])]),
             ], required: ["path", "nodes"])),
        Tool(name: "import_mermaid",
             description: "Draw a Mermaid flowchart (text starting with `flowchart` or `graph`): nodes, shapes, labelled, dashed, "
                + "thick and two-way links, laid out like build_diagram and appended below existing content. Subgraphs become "
                + "containers, nested as written; styling other than fill colors is ignored. Returns a map of Mermaid node id to element id.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "mermaid": prop("string", "Mermaid flowchart source, e.g. \"flowchart LR\\n  A[Start] --> B{OK?}\""),
                "sketchy": prop("boolean", "Hand-drawn look (default true); false for precise geometry"),
                "font": fontProp,
             ], required: ["path", "mermaid"])),
        Tool(name: "add_shape",
             description: "Add one shape at an exact position. Returns its element id.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "extension": prop("string", "Instead of kind: the id of an installed extension (see list_extensions) whose shape to add"),
                "shape": prop("string", "With extension: the shape's id"),
                "params": .object(["type": "object", "description": "With extension: values for the shape's parameters; ones left out take their defaults"]),
                "kind": prop("string", "Shape type. A note is a sticky note whose text is GitHub Flavored Markdown (headings, lists, - [ ] tasks, tables, **bold**, `code`; a single newline is a line break), yellow unless fill is set", enum: kindValues),
                "x": prop("number", "Left edge"), "y": prop("number", "Top edge"),
                "width": prop("number", "Width; auto-sized from text if omitted"),
                "height": prop("number", "Height"),
                "text": prop("string", "Label (Markdown for a note)"),
                "fill": prop("string", "Hex fill color"), "stroke": prop("string", "Hex stroke color"),
                "sketchy": prop("boolean", "Hand-drawn look (default true)"),
                "when": whenProp,
                "parent": prop("string", "Id of the container it goes in (add_container); \"\" takes it out. Moving the container moves it"),
             ].merging(lookProps) { a, _ in a }, required: ["path", "x", "y"])),
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
                "stroke": prop("string", "Line color, hex; its label follows it unless textColor is set"),
                "sketchy": prop("boolean", "Hand-drawn look (default true)"),
                "from_port": prop("string", "Pins the start: top, right, bottom or left, or the number of one of an extension "
                    + "shape's connection points (\"0\" up, in the order the shape declares them). Default: follows the edge"),
                "to_port": prop("string", "Pins the end, like from_port"),
                "when": whenProp,
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
                "capacity": prop("number", "The most add_flow volume it carries (a worker pool's throughput, a rate limit, a lane's "
                    + "trucks a day); flows are placed in page order, each on its cheapest route with room, the rest on the next, "
                    + "and what fits nowhere is backlog waiting in front of the bottleneck. null removes it"),
                "delay": prop("number", "Shapes: seconds add_flow traffic stays inside when passing through (processing, queueing). "
                    + "null removes it"),
                "queue": prop("boolean", "Shapes: it's a queue (an SQS queue, a dock), so traffic that can't go on waits here, at the "
                    + "nearest queue before whatever is full, rather than right in front of it"),
                "link": prop("string", "Id of a shape this element jumps to when its link badge is clicked in the app, on any page "
                    + "(the app switches tabs to follow it). On a shape on another page it is also how people drill in "
                    + "on the web: export_animation's pages: all / split exports show that page when it is clicked "
                    + "(drill_in sets one up, page and way back included). An empty string removes the link"),
                "url": prop("string", "Where the link badge goes outside the drawing, instead of link: an http(s) or mailto link, or "
                    + "another drawing as a path relative to this file, optionally with #anchor (or #page name) to open it at, "
                    + "e.g. plans/next.dottie#Login. PDF and SVG exports make web links clickable, and the web players open them "
                    + "when the element has no click. Setting it clears link and the other way round; an empty string removes it"),
                "click_scene": prop("string", "When the drawing plays on the web (HTML export, <dottie-player>), clicking this element "
                    + "jumps to the scene of this name (see add_scene) and plays on to the next one. Empty string removes the click"),
                "click_url": prop("string", "When played on the web, clicking this element opens this http(s) or mailto link in a "
                    + "new tab. Empty string removes the click"),
                "click_set": clickSetProp,
                "click_run": prop("string", "A handler in the page's logic (set_logic) that clicking runs; it returns new variable "
                    + "values. Where logic may not run, the click does its click_set / click_toggle instead. \"\" removes it"),
                "click_toggle": clickToggleProp,
                "when": whenProp,
                "parent": prop("string", "Id of the container it goes in (add_container); \"\" takes it out. Moving the container moves it"),
                "hover_stroke": prop("string", "Hex stroke color while the pointer is over a clickable element; empty string clears it"),
                "hover_fill": prop("string", "Hex fill color while the pointer is over a clickable element; empty string clears it"),
                "hover_opacity": prop("number", "Opacity 0-1 while the pointer is over a clickable element; -1 clears it"),
                "playback": prop("string", "For a symbol instance: loop, once, still or click", enum: SymbolPlayback.allCases.map(\.rawValue)),
                "offset": prop("number", "For a symbol instance: seconds into its symbol's animation at the page's start"),
                "args": .object(["type": "object", "additionalProperties": .object(["type": "string"]),
                                 "description": "For a symbol instance: its values for the symbol's params, replacing the ones it had ({} clears them)"]),
             ].merging(lookProps) { a, _ in a }, required: ["path", "id"])),
        Tool(name: "set_theme",
             description: "Set the page's theme: page color, ink (the default line and text color) and a palette of named "
                + "colors. Every tool that takes a hex color also takes a palette name (\"accent\", \"danger\", ...); a "
                + "shape's fill, stroke or text color given by name stays that palette color, so changing the palette "
                + "here recolors everything using it. With no arguments but path, returns the theme and palette.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "theme": prop("string", "A built-in to use (" + Theme.all.map(\.id).joined(separator: ", ")
                    + "), \"\" for none (follows the system, exports on white), or the starting point for a theme of the "
                    + "page's own when background, ink or palette are given too"),
                "name": prop("string", "A name for the page's own theme"),
                "background": prop("string", "Page color, hex; makes the theme the page's own"),
                "ink": prop("string", "Default line and text color, hex; makes the theme the page's own"),
                "palette": .object(["type": "object", "additionalProperties": .object(["type": "string"]),
                    "description": .string("Palette colors to set or add, name to hex, e.g. {\"accent\": \"#7c3aed\", "
                        + "\"brand\": \"#0f766e\"}; makes the theme the page's own")]),
             ], required: ["path"])),
        Tool(name: "set_logic",
             description: "Set the page's click logic: JavaScript defining handlers that clicks run (update_element click_run), "
                + "for what conditions and click_set can't say. A handler gets (state, click), the page's variables and "
                + "{id, anchor, text, time, scene}, and returns new variable values, e.g. "
                + "function next(s) { return { stage: (s.stage + 1) % 3 }; }. It runs only on clicks, in a sealed sandbox "
                + "(QuickJS): no page, network, timers, clock or randomness, and a time and memory limit, so the same click "
                + "on the same state always gives the same result. A player runs it only with allow-logic (export_animation "
                + "allow_logic); elsewhere a click does its own click_set / click_toggle. simulate runs it. \"\" removes it.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "logic": prop("string", "The JavaScript, at most 64 KB; \"\" removes it"),
             ], required: ["path", "logic"])),
        Tool(name: "set_variable",
             description: "Add, change or remove a page variable: true or false, or a number (a counter, a step), that clicks change on the web "
                + "(update_element click_set / click_toggle) and elements follow (update_element when, send_packet when). "
                + "This is how a diagram that keeps looping reacts to clicks: \"take a region down\" hides its shapes, "
                + "connectors and packets, shows others, and the animation never stops. Exports and previews show the "
                + "starting values; the HTML export and <dottie-player> change them on click.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "name": prop("string", "Letters, digits and _, not starting with a digit, e.g. eastDown"),
                "value": .object(["type": .array([.string("boolean"), .string("number")]),
                                  "description": .string("Its starting value: true or false (default false), or a number for a "
                                                         + "counter or a step, read by conditions like count >= 3")]),
                "remove": prop("boolean", "Remove the variable instead (elements and clicks that name it are left as they are)"),
             ], required: ["path", "name"])),
        Tool(name: "define_state",
             description: "Describe one page variable all at once, instead of element by element: its starting value, what "
                + "it hides and shows, what it dims or restyles, which connectors' packets detour onto which, and which elements' "
                + "clicks flip or set it. Writes the when conditions, overrides and clicks this means (in one undo step); running it "
                + "again changes nothing more. Prefer it to set_variable plus when on each element: one shape can dim and relabel "
                + "itself, and the same packets keep flowing along a detour, instead of drawing every state twice. Check the "
                + "result with simulate, or an export with a state.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "name": prop("string", "The variable: letters, digits and _, not starting with a digit, e.g. eastDown"),
                "initial": prop("boolean", "Its starting value (default false)"),
                "hide": idListProp("Drawn only while it is false (connectors attached go with them)"),
                "show": idListProp("Drawn only while it is true"),
                "dim": idListProp("Faded while it is true, still drawn"),
                "down": idListProp("Down while it is true: faded like dim and carrying no traffic, so add_flow traffic goes round them"),
                "dim_opacity": prop("number", "How faded dim makes them, 0...1 (default 0.3)"),
                "restyle": stateRestyleProp,
                "reroute": .object(["type": "object", "additionalProperties": .object(["type": "string"]),
                                    "description": "Connector id to connector id: while it is true, everything that follows the first (packets) follows the second"]),
                "toggled_by": idListProp("Elements whose click flips it (on the web: the HTML export and <dottie-player>)"),
                "turned_on_by": idListProp("Elements whose click sets it true"),
                "turned_off_by": idListProp("Elements whose click sets it false"),
             ], required: ["path", "name"])),
        Tool(name: "add_button",
             description: "Add a clean button that changes page variables when clicked on the web (HTML export, <dottie-player>): "
                + "toggles flips one, sets gives several values. It looks pressed (filled, and on_text as its label) while it is on. "
                + "Variables it names are added, starting false, if missing. Pair with define_state for what the variable does.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "text": prop("string", "The label"), "x": prop("number", "Left"), "y": prop("number", "Top"), "after": prop("string", "Instead of x and y: an element id to sit 12 points to the right of (with neither, above the content)"),
                "width": prop("number", "Width (default fits the label, at least 100)"), "height": prop("number", "Height (default 40)"),
                "toggles": prop("string", "The variable a click flips"),
                "sets": .object(["type": "object", "additionalProperties": .object(["type": .array([.string("boolean"), .string("number"), .string("string")])]),
                                 "description": "Variables a click sets, name to true, false, a number or an expression like \"count + 1\""]),
                "on_text": prop("string", "The label while pressed, e.g. \"Bring east back\""),
                "color": prop("string", "Hex color of its outline and label, and its fill while pressed (default blue)"),
             ], required: ["path", "text"])),
        Tool(name: "add_choice",
             description: "Add a row (or column) of buttons of which exactly one is on: one variable per option, named "
                + "<name>_<option>, clicking an option sets it true and the others false. For exclusive scenarios "
                + "(normal, region down, traffic spike); give each variable its meaning with define_state.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "name": prop("string", "The prefix of the options' variables, e.g. scenario"),
                "options": .object(["type": "array", "items": .object(["type": "string"]), "description": "The options' labels, in order"]),
                "x": prop("number", "Left"), "y": prop("number", "Top"), "after": prop("string", "Instead of x and y: an element id to sit 12 points to the right of (with neither, above the content)"),
                "direction": prop("string", "row (default) or column", enum: ["row", "column"]),
                "initial": prop("string", "The option on at the start (default the first)"),
                "color": prop("string", "Hex color (default blue)"),
             ], required: ["path", "name", "options"])),
        Tool(name: "add_reset",
             description: "Add a button that sets every page variable back to its starting value when clicked (click reset: "
                + "true), including variables added later.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "x": prop("number", "Left"), "y": prop("number", "Top"), "after": prop("string", "Instead of x and y: an element id to sit 12 points to the right of (with neither, above the content)"), "text": prop("string", "The label (default Reset)"),
                "id": prop("string", "An existing reset button to update instead of adding one"),
                "color": prop("string", "Hex color (default grey)"),
             ], required: ["path"])),
        Tool(name: "add_legend",
             description: "Add a legend of the page's flows: a swatch in each flow's color and a label. Clicking a row on "
                + "the web hides or shows that flow (a variable show_<n>, starting true, joined onto its when).",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "x": prop("number", "Left"), "y": prop("number", "Top"),
                "labels": .object(["type": "object", "additionalProperties": .object(["type": "string"]),
                                   "description": "Flow id to its label (default \"from → to\")"]),
             ], required: ["path"])),
        Tool(name: "add_flow",
             description: "Send traffic from one shape to the first of a list of destinations (preferred first) it can reach "
                + "over the connectors drawn: a packet every `every` seconds, routed afresh in every frame by every renderer. When "
                + "a state hides a shape or connector (define_state hide, or when), the traffic goes round it with nothing more "
                + "drawn, and define_state down takes a shape out of the traffic while keeping it drawn, faded: failover, outages "
                + "and maintenance animate themselves. A connector carries traffic from its start to its "
                + "end, and back too when its start has an arrowhead. Traffic takes the cheapest route by connector `cost` "
                + "(1 each by default, set with update_element), so give a main path a lower cost than its backup. To split "
                + "traffic across several regions, add one flow per region, each with its own color and its fallbacks in `to`. Gives the page a 4-second timeline if it has none and rounds "
                + "every so the timeline loops seamlessly. With id, changes that flow; with remove, removes it. Prefer it to "
                + "send_packet for steady traffic in a system diagram.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "from": prop("string", "Id of the shape traffic leaves from"),
                "to": .object(["type": "array", "items": .object(["type": "string"]),
                               "description": "Ids of the destinations, preferred first: traffic goes to the first it can reach"]),
                "every": prop("number", "Seconds between packets (default 0.5)"),
                "speed": prop("number", "Points per second (default 160)"),
                "color": prop("string", "Hex color of the packets"),
                "size": prop("number", "Packet diameter (default 12)"),
                "when": prop("string", "A condition on page variables: nothing flows while it fails"),
                "spread": prop("boolean", "While the first destination can't be reached, deal packets in turn across every other "
                               + "destination that can (a downed region's traffic shared by the rest), rather than all to the next"),
                "volume": prop("number", "How much it carries, in the page's own unit (requests a second, messages, trucks a day; "
                               + "default 1), or as a string an expression of page variables and `time` (the timeline's seconds) "
                               + "worked out each frame, a ramp like \"clamp((time - 15) * 180, 0, 3400)\". Illustrative: pick numbers that make the scenario read clearly, not a forecast. Shapes and connectors with a capacity (update_element) limit it; the biggest flow "
                               + "draws a packet every `every`, the rest proportionally fewer"),
                "overrides": .object(["type": "array", "items": .object(["type": "object", "required": .array(["when"]),
                    "properties": .object(["when": .object(["type": "string"]),
                                           "volume": .object(["type": .array([.string("number"), .string("string")])]),
                                           "to": .object(["type": "array", "items": .object(["type": "string"])])])]),
                    "description": .string("Its volume (a number or an expression), or destinations (`to`, shape ids), while a condition "
                        + "on page variables or `time` holds, the last that holds winning, e.g. [{\"when\": \"spike\", \"volume\": 12}] or "
                        + "[{\"when\": \"split\", \"to\": [\"<id>\"]}]: one flow instead of an extra one per scenario, and its queue "
                        + "drains to where it goes now")]),
                "id": prop("string", "An existing flow's id, to change or remove it"),
                "remove": prop("boolean", "Remove the flow named by id"),
             ], required: ["path"])),
        Tool(name: "add_override",
             description: "Add an override to an element, keeping the ones it has: how it looks (and, for conditions on "
                + "variables, whether it carries traffic, its cost, capacity or delay, or where its packets go) while a condition "
                + "holds. Merged into an existing override with the same `when`, else appended. The condition can compare a "
                + "metric by anchor, like \"load(workers) >= 0.9\", or the element's own, like \"load >= 0.9\" (see add_alarm); "
                + "such an override changes only looks. Prefer define_state for a variable's whole meaning at once.",
             inputSchema: schema([
                "path": pathProp, "id": prop("string", "Element id (its page is found from it)"),
                "when": prop("string", "The condition: variables with !, && and ||, or metric comparisons like load(workers) > 0.9"),
                "stroke": prop("string", "Hex stroke color"), "fill": prop("string", "Hex fill color"),
                "text_color": prop("string", "Hex label color"), "opacity": prop("number", "Multiplies its opacity, 0 to 1"),
                "stroke_width": prop("number", "Stroke width"), "dash": prop("string", "Dash", enum: ["solid", "dashed", "dotted"]),
                "text": prop("string", "Label shown meanwhile"),
                "offline": prop("boolean", "Still drawn but carries no add_flow traffic (a region that's down)"),
                "cost": prop("number", "A connector's cost for add_flow traffic meanwhile"),
                "capacity": prop("number", "Its capacity meanwhile"), "delay": prop("number", "A shape's delay meanwhile"),
                "reroute": .object(["type": "object", "additionalProperties": .object(["type": "string"]),
                                    "description": .string("Connector id to connector id: send_packet packets following the first take the second")]),
             ], required: ["path", "id", "when"])),
        Tool(name: "add_container",
             description: "A container: a titled box holding shapes (a subsystem, an account, a VPC), which fits round them, "
                + "moves them when it moves, and takes connectors like any shape. Nest them with parent. With lanes it is a "
                + "swimlane, and its children should be containers (one per lane), stacked as rows or columns across it. "
                + "Shapes join one with parent on add_shape or update_element; in the app, by being dropped in.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "title": prop("string", "Its title, at the top"),
                "ids": idListProp("The shapes (or containers) it holds, if any"),
                "parent": prop("string", "Id of a container it goes in"),
                "lanes": prop("string", "Make it a swimlane: its child containers as rows or columns", enum: ["rows", "columns"]),
                "x": prop("number", "Left, for an empty container"), "y": prop("number", "Top, for an empty container"),
                "width": prop("number", "Width, for an empty container (it then keeps its size)"),
                "height": prop("number", "Height, for an empty container"),
                "fill": prop("string", "Fill, hex or palette name (default a faint grey-blue)"),
                "stroke": prop("string", "Outline, hex or palette name"),
             ], required: ["path"])),
        Tool(name: "add_group",
             description: "Draw a labelled dashed frame behind some elements: a region, an account, a VPC, a site. It is "
                + "drawn once and doesn't follow them; add_container makes a box that holds them.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "ids": idListProp("The elements it frames"),
                "label": prop("string", "Its label, top left"),
                "padding": prop("number", "Points round the elements (default 24)"),
                "color": prop("string", "Hex color"),
             ], required: ["path", "ids", "label"])),
        Tool(name: "add_alarm",
             description: "Turn elements red (or color) while their own metric is at or past a threshold, e.g. every worker pool "
                + "and table at load >= 1: an override with the condition \"load >= 1\" on each (a condition without a target means "
                + "the element's own). Shows whatever is saturated as states and traffic change.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "ids": idListProp("The elements"),
                "metric": prop("string", "The metric (default load)", enum: PageState.metricNames),
                "at": prop("number", "At or past this (default 1)"),
                "color": prop("string", "Hex color (default red)"),
             ], required: ["path", "ids"])),
        Tool(name: "add_gauge",
             description: "Add a gauge, to present a scenario: a box showing a metric of a shape, connector or flow as a number, a bar, a dial or slots (a grid of squares, one per unit of max, in the colors of the flows filling it), green, "
                + "amber at warn and red at alarm (load defaults to 0.7 and 0.9), drawn by every renderer and updated as states "
                + "change. Metrics come from add_flow traffic and capacities: throughput (volume through it), load (throughput "
                + "over capacity), delay, backlog (volume waiting at a shape: how fast its queue grows), inFlight (packets on a "
                + "connector now), and for a flow transit (seconds end to end) and backup (share not reaching its first "
                + "destination). To recolor a shape by a metric instead, give it an anchor and an override like {when: "
                + "\"load(workers) >= 0.9\", stroke: \"#dc2626\"} (run_script dottie.update); such overrides change only looks.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "metric": prop("string", "What it shows", enum: PageState.metricNames),
                "of": prop("string", "Id of the shape, connector or flow it measures"),
                "x": prop("number", "Left edge"), "y": prop("number", "Top edge"),
                "near": prop("string", "Instead of x and y: beside its target (a flow's: its source), clear of other gauges",
                             enum: ["right", "left", "above", "below"]),
                "width": prop("number", "Width (default 160)"), "height": prop("number", "Height (default 80, 110 for a dial)"),
                "style": prop("string", "How it shows it (default number)", enum: Gauge.Style.allCases.map(\.rawValue)),
                "max": prop("number", "What a full bar or dial stands for (default 1 for load, else the target's capacity)"),
                "warn": prop("number", "At or past this it turns amber"),
                "alarm": prop("number", "At or past this it turns red"),
                "label": prop("string", "Its title (default the metric and the target's name)"),
             ], required: ["path", "metric", "of"])),
        Tool(name: "list_extensions",
             description: "List the extensions installed in Dottie's Extensions folder: each one's id, version, shapes and "
                + "commands, or why it did not load. Shapes are added with add_shape (extension, shape, params); commands run with run_command.",
             inputSchema: schema([:])),
        Tool(name: "reload_extensions",
             description: "Rescan the Extensions folder, picking up bundles added or edited since the last call, and list them as list_extensions does.",
             inputSchema: schema([:])),
        Tool(name: "install_extension",
             description: "Install a .dottieext bundle (a folder with manifest.json and main.js) into the Extensions folder. It must load "
                + "first, and an extension with the same id must not be installed already.",
             inputSchema: schema(["path_to_bundle": prop("string", "Absolute path of the .dottieext folder")], required: ["path_to_bundle"])),
        Tool(name: "run_command",
             description: "Run an installed extension's command on a page, in one call and one undo step. Nothing changes if it throws. "
                + "Returns what it logged and its result.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "extension": prop("string", "The extension's id (see list_extensions)"),
                "command": prop("string", "The command's id"),
                "params": .object(["type": "object", "description": "Values for the command's parameters; ones left out take their defaults"]),
             ], required: ["path", "extension", "command"])),
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
                "typecheck": prop("boolean", "Check the script against dottie.d.ts with the TypeScript compiler, when one is "
                    + "installed, and list any problems as warnings (default true; the script runs either way)"),
             ], required: ["path", "code"])),
        Tool(name: "script_api",
             description: "Reference for the JavaScript API available to run_script (also served as the resource dottie://script-api). "
                + "format \"typescript\" returns it as dottie.d.ts declarations instead (the resource dottie://dottie.d.ts). "
                + "example returns a worked run_script program for an interactive page (also dottie://examples/<name>): "
                + ScriptExamples.all.map { "\($0.name) (\($0.title.lowercased()))" }.joined(separator: ", ") + ".",
             inputSchema: schema([
                "format": prop("string", "reference (default) or typescript", enum: ["reference", "typescript"]),
                "example": prop("string", "A worked example to return instead", enum: ScriptExamples.all.map(\.name)),
             ])),
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
                "params": .object(["type": "object", "additionalProperties": .object(["type": "string"]),
                                   "description": .string("Parameters copies fill in, like Flash component parameters: name to default. "
                                    + "Write {{name}} in the shapes' text; each copy shows its own args value there")]),
                "button": prop("boolean", "Make a Flash-style button: the page's scenes named up, over, down and hit (see add_scene) "
                    + "move into it as its states. Copies show up; on the web, over under the pointer, down while pressed, and the hit "
                    + "state's shapes take clicks. Give a copy click_scene or click_url with update_element"),
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
                "playback": prop("string", "loop (default), once, still (its poster frame), or click (rests at the start; in "
                    + "<dottie-player> a click plays it once)", enum: SymbolPlayback.allCases.map(\.rawValue)),
                "offset": prop("number", "Seconds into the symbol's animation at the page's start, so copies don't move in step; "
                    + "negative starts a once copy that many seconds into the page"),
                "args": .object(["type": "object", "additionalProperties": .object(["type": "string"]),
                                 "description": "Values for the symbol's params (see make_symbol); ones left out take the default"]),
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
        Tool(name: "drill_in",
             description: "Make a shape lead to a page of its own, for a drawing people drill into (an overview whose "
                + "boxes open their details): clicking the shape shows that page in the app and in export_animation's "
                + "pages: all / split web exports. Uses the page the shape already links to, else the page called "
                + "page_name, else adds one after the shape's page with its theme. The link lands on a title naming the "
                + "page (added at the top if there is none), and a \"← <page>\" shape there leads back. Returns the "
                + "page and ids; draw the details on that page with the usual tools (page: its name), then check the "
                + "path with simulate (click the shape, then {back: true}).",
             inputSchema: schema([
                "path": pathProp,
                "id": prop("string", "The shape to drill in from"),
                "page_name": prop("string", "The page to lead to; default the shape's text (its first line), else its anchor"),
                "back": prop("boolean", "Add a shape on that page leading back (default true)"),
             ], required: ["path", "id"])),
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
                "state": stateProp,
                "max_width": prop("number", "Largest image width in pixels: the scale is lowered to fit, e.g. 600 for a "
                    + "small preview"),
                "include_image": prop("boolean", "Default true. false (with out_path) saves the image but returns only its "
                    + "path, size and the element map, keeping the result small"),
                "elements": prop("string", "The element map returned: full (JSON, the default), compact (one short line "
                    + "each) or none", enum: ["full", "compact", "none"]),
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
                "state": stateProp,
             ], required: ["path"])),
        Tool(name: "set_timeline",
             description: "Animate a page, or adjust its animation: frame rate, length, hand-drawn line boil and more. "
                + "With only path (and page), reports the page's animation: length, each animated element's keys, "
                + "camera keys and scenes. Animation tools: animate_build, add_transition, add_keyframe, send_packet, "
                + "set_camera, add_scene, update_scene, clear_animation; check with export_animation's preview or export_png's at.",
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
                "when": whenProp,
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
                "name": prop("string", "What the scene shows; default Scene n. Clicks (click_scene) play it by this name"),
                "loop": prop("boolean", "A looping scene: playing doesn't stop on entering it, and at its end (the next scene, "
                    + "or the end) goes back to its start, until a click or next leaves it. For clicks that switch between "
                    + "states that keep moving; set_variable is usually simpler"),
             ], required: ["path", "t"])),
        Tool(name: "update_scene",
             description: "Rename, move or remove one of the page's scenes (see add_scene). Renaming keeps the clicks that "
                + "play it (click_scene) pointing at it; removing it leaves them doing nothing.",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "scene": prop("string", "The scene: its name, or the second it is at"),
                "name": prop("string", "Its new name"),
                "t": prop("number", "The second to move it to"),
                "loop": prop("boolean", "true makes it a looping scene (see add_scene), false stops at it again"),
                "remove": prop("boolean", "Remove the scene instead"),
             ], required: ["path", "scene"])),
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
                "out_path": prop("string", "Absolute path ending in .gif, .apng, .mp4, .json (Lottie) or .html; or .png for a "
                    + "still of the poster frame (or of `preview`), e.g. a thumbnail"),
                "lottie_mode": prop("string", "For .json: smooth (default; tweened, lines held steady) or exact "
                                    + "(every frame as the GIF draws it, boil included)", enum: Exporter.LottieMode.allCases.map(\.rawValue)),
                "scale": prop("number", "Pixel scale for gif, apng, mp4 and png, 0.25 to 4 (default 1.5)"),
                "transparent": prop("boolean", "No page background (apng, png and json only)"),
                "sketchy": prop("boolean", "Override the look for this export only"),
                "preview": prop("number", "Second of the animation to return as a PNG preview"),
                "allow_logic": prop("boolean", "HTML only: let the page's click logic (set_logic) run in the exported page; it "
                    + "carries the sandboxed engine (about 850 KB). Off by default: clicks then do their own click_set / click_toggle"),
                "pages": prop("string", "HTML only, for a drawing people drill into: all = every page in one .html, where a "
                    + "link to a shape on another page shows that page, each page has its own address (#Page) and Back goes "
                    + "back (`page` is the one to start on); split = out_path is a folder, with index.html for the first page "
                    + "and a file named after each other page, linked to each other. Pages need no animation for either. "
                    + "Default: just this page", enum: ["all", "split"]),
                "state": exportStateProp,
             ], required: ["path", "out_path"])),
        Tool(name: "simulate",
             description: "Play an interactive page as the web player (<dottie-player>, the HTML export) would, without a "
                + "browser, to check it does what you built: clicks set and flip variables and jump to scenes, waits play "
                + "on (stopping at each scene unless it loops, round a looping scene), snapshots return a PNG of that "
                + "moment. Returns one line per step (time, scene, playing or stopped, variables, elements their "
                + "conditions hide) and each snapshot as an image. A click on a shape that links to a shape on another page shows that page, as the HTML export of every page does, and {back: true} returns; web links are reported, not followed. "
                + "With record_path, also writes the whole run, every frame a viewer would see, as a looping movie or GIF "
                + "(end with a wait, or the last click's result never shows).",
             inputSchema: schema([
                "path": pathProp, "page": pageProp,
                "steps": simulateStepsProp,
                "start": prop("string", "Start at this scene, playing (default the start, as the player does)"),
                "state": exportStateProp,
                "scale": prop("number", "Snapshot and recording pixel scale, 0.25 to 4 (default 1)"),
                "record_path": prop("string", "Record the run from the start to the last step: a .mp4, .gif or animated .png"),
             ], required: ["path", "steps"])),
    ]

    func call(name: String, arguments: [String: Value]) -> CallTool.Result {
        let result: CallTool.Result
        do {
            result = try run(name, Args(raw: arguments))
        } catch let e as ToolFailure {
            result = .init(content: [.plain(e.message)], isError: true)
        } catch {
            result = .init(content: [.plain("\(error)")], isError: true)
        }
        var content = result.content
        // After an edit that can change an interactive page's wiring, what looks wrong with it (DiagramOps.stateWarnings).
        if result.isError != true, Self.wiringTools.contains(name), let warnings = try? wiringWarnings(Args(raw: arguments)), !warnings.isEmpty {
            content.append(.plain("Warnings:\n" + warnings.map { "  - " + $0 }.joined(separator: "\n")))
        }
        // What extensions logged with `console` while generating, migrating or loading, so an agent can debug a shape.
        let logs = extensionLogs()
        if !logs.isEmpty { content.append(.plain("Extension console:\n" + logs.joined(separator: "\n"))) }
        return .init(content: content, isError: result.isError)
    }

    /// The tools after which a page's wiring is checked.
    static let wiringTools: Set<String> = ["run_script", "update_element", "define_state", "set_variable", "add_flow", "add_gauge",
                                           "add_button", "add_choice", "add_reset", "add_legend", "add_override", "add_alarm", "delete_element",
                                           "add_shape", "add_connector"]

    /// A control's position from a tool call: x and y, else after `after`, else above the page's content.
    private func controlOrigin(_ doc: DottieDocument, _ a: Args) throws -> CGPoint {
        if let x = a.double("x"), let y = a.double("y") { return CGPoint(x: x, y: y) }
        do { return try DiagramOps.controlOrigin(doc, after: a.string("after") == nil ? nil : try a.uuid("after")) }
        catch let e as OpsError { throw ToolFailure(message: e.description) }
    }

    /// The wiring warnings for the page a tool call edited.
    private func wiringWarnings(_ a: Args) throws -> [String] {
        let file = try load(try fileURL(a))
        let element = a.string("id").flatMap(UUID.init(uuidString:))
        let p = (try? pageIndex(file, a, element: element)) ?? 0
        return DiagramOps.stateWarnings(file.pages[p])
    }

    /// A connector end's pin from a tool argument: a side name, or a connection point number (as text or a number).
    private func connectionPoint(_ a: Args, _ k: String) throws -> (DottieKit.Port?, Int?) {
        if let s = a.string(k) {
            if let port = DottieKit.Port(rawValue: s) { return (port, nil) }
            guard let i = Int(s), i >= 0 else { throw ToolFailure(message: "'\(k)' must be top, right, bottom, left or a number from 0") }
            return (nil, i)
        }
        guard let n = a.double(k) else { return (nil, nil) }
        guard n >= 0, n == n.rounded(), n < Double(Int32.max) else { throw ToolFailure(message: "'\(k)' must be a whole number from 0") }
        return (nil, Int(n))
    }

    /// The `console` lines the loaded extensions have logged since the last reply.
    private func extensionLogs() -> [String] {
        guard let registry = extensionCache?.registry else { return [] }
        return registry.entries.compactMap(\.runtime).flatMap { rt in rt.takeLogs().map { "\(rt.manifest.name): \($0)" } }
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

    /// The Extensions folder as last scanned, and what it looked like then.
    private var extensionCache: (fingerprint: [String], registry: ExtensionRegistry)?

    /// The Extensions folder, rescanned only when a file in it has changed since the last call (or when `rescan`),
    /// so each extension's context stays warm between calls.
    private func extensionRegistry(rescan: Bool = false) -> ExtensionRegistry {
        let fingerprint = ExtensionRegistry.fingerprint()
        if !rescan, let cache = extensionCache, cache.fingerprint == fingerprint { return cache.registry }
        let registry = ExtensionRegistry()
        registry.scan()
        extensionCache = (fingerprint, registry)
        return registry
    }

    /// The extensions in the Extensions folder that loaded.
    private func loadedRuntimes() -> [ExtensionRuntime] {
        extensionRegistry().entries.compactMap(\.runtime)
    }

    private func extensionListing(rescan: Bool = false) -> String {
        let registry = extensionRegistry(rescan: rescan)
        guard !registry.entries.isEmpty else { return "No extensions are installed in \(ExtensionRegistry.folder.path)." }
        return registry.entries.map { entry -> String in
            if let rt = entry.runtime {
                let lines = ["\(rt.manifest.name) (\(rt.manifest.id)) \(rt.manifest.version): loaded"]
                    + rt.shapes.map { "  shape \($0.id): \($0.name)" }
                    + rt.commands.map { "  command \($0.id): \($0.name)" }
                    + rt.tools.map { "  tool \($0.id): \($0.name)" }
                return lines.joined(separator: "\n")
            }
            return entry.enabled ? "\(entry.name): not loaded: \(entry.error ?? "unknown error")" : "\(entry.name): turned off in Settings"
        }.joined(separator: "\n")
    }

    /// Parameter values from a tool argument: numbers, booleans and text.
    private func extensionParams(_ value: Value?) throws -> [String: ExtensionValue] {
        var out: [String: ExtensionValue] = [:]
        for (name, v) in value?.objectValue ?? [:] {
            if let b = v.boolValue { out[name] = .bool(b) }
            else if let n = v.doubleValue ?? v.intValue.map(Double.init) { out[name] = .number(n) }
            else if let s = v.stringValue { out[name] = .string(s) }
            else { throw ToolFailure(message: "params.\(name) must be a number, boolean or text") }
        }
        return out
    }

    /// export_animation with `pages`: every page as one web page (`all`), or a folder of them (`split`).
    private func exportPages(_ a: Args, mode: String) throws -> CallTool.Result {
        guard mode == "all" || mode == "split" else { throw ToolFailure(message: "'pages' must be all or split") }
        var file = try load(try fileURL(a))
        let start = try pageIndex(file, a)
        file.pages[start] = file.pages[start].starting(with: try a.state())
        if let r = a.roughness { file.pages = file.pages.map { $0.withRoughness(r) } }
        guard file.pages.contains(where: { !$0.elements.isEmpty }) else { throw ToolFailure(message: "The drawing is empty") }
        let allow = a.bool("allow_logic") == true
        // The tab's title: the drawing's file name.
        let name = try fileURL(a).deletingPathExtension().lastPathComponent
        var written: [String] = []
        if mode == "all" {
            let out = try fileURL(a, key: "out_path", ext: "html")
            let startName = (a.string("page") ?? "").isEmpty ? nil : file.pages[start].name
            guard let html = Exporter.player(file: file, title: name, start: startName, allowLogic: allow) else {
                throw ToolFailure(message: "Rendering failed")
            }
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(html.utf8).write(to: out, options: .atomic)
            written = [out.path]
        } else {
            let raw = (try a.require("out_path") as NSString).expandingTildeInPath
            guard raw.hasPrefix("/") else { throw ToolFailure(message: "'out_path' must be an absolute path") }
            guard !raw.lowercased().hasSuffix(".html") else {
                throw ToolFailure(message: "With pages: split, out_path is a folder for the pages (index.html and the rest)")
            }
            let folder = URL(fileURLWithPath: raw, isDirectory: true)
            guard let pages = Exporter.playerPages(file, title: name, allowLogic: allow) else { throw ToolFailure(message: "Rendering failed") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (page, html) in pages {
                let target = folder.appendingPathComponent(page)
                try Data(html.utf8).write(to: target, options: .atomic)
                written.append(target.path)
            }
        }
        let links = file.pages.reduce(0) { $0 + $1.elements.filter { $0.link != nil }.count }
        var lines = ["Exported \(file.pages.count) page\(file.pages.count == 1 ? "" : "s") (\(file.pages.map(\.name).joined(separator: ", "))) to:"]
        lines += written.map { "  " + $0 }
        if links == 0, file.pages.count > 1 {
            lines.append("No shape links to another page yet: link shapes (link) so people can drill in.")
        }
        var content: [Tool.Content] = [.plain(lines.joined(separator: "\n"))]
        let still = file.pages[start].still
        if !still.elements.isEmpty, let png = Exporter.png(still, scale: 1) { content.insert(.png(png), at: 0) }
        return .init(content: content)
    }

    private func fileURL(_ args: Args, key: String = "path", ext: String = "dottie") throws -> URL {
        let raw = try args.require(key)
        if key == "path", raw == "current" { return Self.currentURL }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ToolFailure(message: "'\(key)' must be an absolute path") }
        guard expanded.lowercased().hasSuffix("." + ext) else { throw ToolFailure(message: "'\(key)' must end in .\(ext)") }
        return URL(fileURLWithPath: expanded)
    }

    private func load(_ url: URL, createIfMissing: Bool = false) throws -> DottieFile {
        let file = try read(url, createIfMissing: createIfMissing)
        loaded = file
        return file
    }

    private func read(_ url: URL, createIfMissing: Bool) throws -> DottieFile {
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
        let i = try findPage(file, a, element: element)
        // Palette names in color arguments are that page's.
        DiagramOps.colorContext = file.pages[i]
        return i
    }

    private func findPage(_ file: DottieFile, _ a: Args, element: UUID?) throws -> Int {
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
        let doc = doc.reconcilingContainers(from: loaded)
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
                                    routing: try e.routing("routing"), arrow: e.bool("arrow") ?? true, label: e.string("label"),
                                    look: try e.look(), stroke: try e.color("stroke"), when: e.string("when"))
            }
            let direction = LayoutDirection(rawValue: a.string("direction") ?? "TB") ?? .topToBottom
            let ids: [String: UUID]
            do {
                let clusters = try (a.array("clusters") ?? []).map { c in
                    DiagramOps.ClusterSpec(key: try c.require("key"), title: c.string("title"), nodes: c.raw["nodes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                           parent: c.string("parent"),
                                           lanes: try c.string("lanes").map { s in
                                               guard let l = LaneDirection(rawValue: s) else { throw ToolFailure(message: "'lanes' must be rows or columns") }
                                               return l
                                           })
                }
                ids = try DiagramOps.build(&file.pages[p], nodes: nodes, edges: edges, direction: direction, roughness: a.roughness ?? 1,
                                         font: a.string("font"), clusters: clusters)
                for n in nodeArgs { if let id = ids[n.string("key") ?? ""] { try DiagramOps.nameColors(&file.pages[p], id: id, fill: n.string("fill"), stroke: nil, textColor: nil) } }
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
                result = try MermaidImporter.build(&file.pages[p], mermaid: source, roughness: a.roughness ?? 1, font: a.string("font"))
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
            let e: Element
            if let extensionID = a.string("extension") {
                guard let runtime = loadedRuntimes().first(where: { $0.manifest.id == extensionID }) else {
                    throw ToolFailure(message: "No loaded extension with id '\(extensionID)'; see list_extensions")
                }
                e = try DiagramOps.addExtensionShape(&file.pages[p], runtime: runtime, shape: try a.require("shape"),
                                                     params: try extensionParams(a.raw["params"]), frame: frame, at: CGPoint(x: x, y: y),
                                                     text: a.string("text"), fill: try a.color("fill"), stroke: try a.color("stroke"),
                                                     look: try a.look())
            } else {
                e = try DiagramOps.addShape(&file.pages[p], kind: try a.kind("kind"), frame: frame, at: CGPoint(x: x, y: y),
                                            text: a.string("text"), fill: try a.color("fill"), stroke: try a.color("stroke"),
                                            roughness: a.roughness, look: try a.look())
            }
            if let w = a.string("when") {
                do { try DiagramOps.setWhen(&file.pages[p], id: e.id, w) } catch let e as OpsError { throw ToolFailure(message: e.description) }
            }
            do {
                try DiagramOps.nameColors(&file.pages[p], id: e.id, fill: a.string("fill"), stroke: a.string("stroke"),
                                          textColor: a.string("text_color"))
                if let parent = a.string("parent") { try DiagramOps.setParent(&file.pages[p], id: e.id, parent: parent.isEmpty ? nil : try a.uuid("parent")) }
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
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
                let start = try connectionPoint(a, "from_port"), end = try connectionPoint(a, "to_port")
                c = try DiagramOps.addConnector(&file.pages[p], from: from, to: to,
                                                routing: try a.routing("routing") ?? .straight, arrow: a.bool("arrow") ?? true,
                                                port: (start.0, end.0), portIndex: (start.1, end.1),
                                                roughness: a.roughness, label: a.string("label"), look: try a.look(),
                                                stroke: try a.color("stroke"))
                if let w = a.string("when") { try DiagramOps.setWhen(&file.pages[p], id: c.id, w) }
                try DiagramOps.nameColors(&file.pages[p], id: c.id, fill: nil, stroke: a.string("stroke"), textColor: a.string("text_color"))
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text("id: \(c.id.uuidString)")

        case "update_element":
            let url = try fileURL(a)
            var file = try load(url)
            let id = try a.uuid("id")
            let p = try pageIndex(file, a, element: id)
            let before = file.pages[p]
            var link: UUID?? = nil
            if let s = a.string("link") { link = .some(s.isEmpty ? nil : try a.uuid("link")) }
            do {
                var click: ClickAction?? = nil
                if a.string("click_scene") != nil || a.string("click_url") != nil || a.raw["click_set"] != nil || a.raw["click_toggle"] != nil
                    || a.string("click_run") != nil {
                    click = .some(try DiagramOps.click(scene: a.string("click_scene"), url: a.string("click_url"),
                                                       set: try a.flags("click_set"), toggle: try a.names("click_toggle"),
                                                       run: a.string("click_run")))
                }
                var hover: HoverLook?? = nil
                if a.string("hover_stroke") != nil || a.string("hover_fill") != nil || a.double("hover_opacity") != nil {
                    let base = file.pages[p].elements.first { $0.id == id }?.hover
                    hover = .some(try DiagramOps.hover(base, stroke: a.string("hover_stroke"), fill: a.string("hover_fill"),
                                                       opacity: a.double("hover_opacity")))
                }
                if let i = file.pages[p].elements.firstIndex(where: { $0.id == id }), file.pages[p].elements[i].kind == .symbol {
                    if let s = a.string("playback") {
                        guard let v = SymbolPlayback(rawValue: s) else { throw ToolFailure(message: "'playback' must be loop, once, still or click") }
                        file.pages[p].elements[i].playback = v == .loop ? nil : v
                    }
                    if let o = a.double("offset") { file.pages[p].elements[i].offset = o == 0 || !o.isFinite ? nil : o }
                    if a.raw["args"] != nil { file.pages[p].elements[i].args = try a.strings("args") }
                }
                try DiagramOps.update(&file.pages[p], id: id, text: a.string("text").map { Optional($0) },
                                      x: a.double("x"), y: a.double("y"), width: a.double("width"), height: a.double("height"),
                                      fill: try a.color("fill"), stroke: try a.color("stroke"), roughness: a.roughness,
                                      routing: try a.routing("routing"), look: try a.look(), link: link,
                                      url: a.string("url").map { Optional($0) },
                                      anchor: a.string("anchor").map { Optional($0) }, click: click, hover: hover,
                                      otherPages: file.pages)
                if let w = a.string("when") { try DiagramOps.setWhen(&file.pages[p], id: id, w) }
                func measure(_ k: String) -> Double?? {
                    guard let v = a.raw[k] else { return nil }
                    if case .null = v { return .some(nil) }
                    return a.double(k).map { .some($0) } ?? .some(.nan)
                }
                let capacity = measure("capacity"), delay = measure("delay")
                if capacity != nil || delay != nil { try DiagramOps.setCapacity(&file.pages[p], id: id, capacity: capacity, delay: delay) }
                if let q = a.bool("queue") { try DiagramOps.setQueue(&file.pages[p], id: id, q) }
                try DiagramOps.nameColors(&file.pages[p], id: id, fill: a.string("fill"), stroke: a.string("stroke"),
                                          textColor: a.string("text_color"))
                if let parent = a.string("parent") { try DiagramOps.setParent(&file.pages[p], id: id, parent: parent.isEmpty ? nil : try a.uuid("parent")) }
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            // A resized extension shape reflows rather than stretching; one whose extension fails keeps its path.
            let problems = file.pages[p].reflowExtensionShapes(from: before, using: loadedRuntimes())
            try save(file, to: url)
            return text((["Updated"] + problems).joined(separator: "\n"))

        case "set_theme":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            let custom = a.string("background") != nil || a.string("ink") != nil || a.raw["palette"] != nil || a.string("name") != nil
            func hex(_ k: String) throws -> RGBA? {
                guard let s = a.string(k) else { return nil }
                guard let c = RGBA(hex: s) else { throw ToolFailure(message: "'\(k)' must be a hex color like #ffcc00, got '\(s)'") }
                return c
            }
            do {
                if custom {
                    let start = a.string("theme").flatMap { $0.isEmpty ? nil : Theme.named($0) }
                    if let t = a.string("theme"), !t.isEmpty, start == nil {
                        throw ToolFailure(message: "No theme '\(t)'; the built-ins are " + Theme.all.map(\.id).joined(separator: ", "))
                    }
                    var theme = start.map { CustomTheme(from: $0, name: $0.name + " (custom)") } ?? file.pages[p].customTheme
                        ?? CustomTheme(from: file.pages[p].resolvedTheme ?? .white, name: (file.pages[p].resolvedTheme?.name ?? "White") + " (custom)")
                    if let n = a.string("name"), !n.isEmpty { theme.name = n }
                    if let c = try hex("background") { theme.background = c }
                    if let c = try hex("ink") { theme.ink = c }
                    try DiagramOps.setTheme(&file.pages[p], id: nil, custom: theme)
                    for (k, v) in a.raw["palette"]?.objectValue ?? [:] {
                        guard let s = v.stringValue, let c = RGBA(hex: s) else {
                            throw ToolFailure(message: "'palette' maps names to hex colors; '\(k)' isn't one")
                        }
                        try DiagramOps.setPaletteColor(&file.pages[p], name: k, color: c)
                    }
                } else if let t = a.string("theme") {
                    try DiagramOps.setTheme(&file.pages[p], id: t)
                }
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            if custom || a.string("theme") != nil { try save(file, to: url) }
            let page = file.pages[p]
            func h(_ c: RGBA) -> String { String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }
            let head = page.resolvedTheme.map { "Theme: \($0.name)" + (page.customTheme != nil ? " (the page's own)" : "") + ", page \(h($0.background)), ink \(h($0.ink))" }
                ?? "Theme: none (follows the system; exports on white)"
            return text(head + "\nPalette: " + page.palette.map { "\($0.name) \(h($0.color))" }.joined(separator: ", ") + on(file, p))

        case "set_logic":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            let handlers: [String]
            do { handlers = try DiagramOps.setLogic(&file.pages[p], a.string("logic")) } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text(file.pages[p].logic == nil ? "Removed the page's logic" + on(file, p)
                        : "Handlers: " + (handlers.isEmpty ? "none found at the top level" : handlers.joined(separator: ", ")) + on(file, p))

        case "set_variable":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            let name = try a.require("name")
            do {
                let value: Var = a.bool("value").map(Var.bool) ?? a.double("value").map(Var.number) ?? false
                try file.pages[p].setVariable(name, to: a.bool("remove") == true ? nil : value)
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            let vars = (file.pages[p].variables ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            return text("Variables: " + (vars.isEmpty ? "none" : vars.joined(separator: ", ")) + on(file, p))

        case "add_flow":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            if a.bool("remove") == true {
                let id = try a.uuid("id")
                guard DiagramOps.removeFlow(&file.pages[p], id) else { throw ToolFailure(message: "No flow \(id.uuidString)") }
                try save(file, to: url)
                return text("Removed flow \(id.uuidString)" + on(file, p))
            }
            let flow: Flow
            do {
                flow = try DiagramOps.addFlow(&file.pages[p], from: try a.uuid("from"), to: try a.uuids("to") ?? [],
                                              every: a.double("every"), speed: a.double("speed"),
                                              color: try a.string("color").map { s in
                                                  guard let c = RGBA.parse(s, in: DiagramOps.colorContext)?.color else {
                                                      throw ToolFailure(message: "'color' must be \(RGBA.expected(in: DiagramOps.colorContext))")
                                                  }
                                                  return c
                                              },
                                              size: a.double("size"), when: a.string("when"), spread: a.bool("spread"),
                                              volume: a.double("volume"), volumeExpression: a.string("volume"),
                                              overrides: try a.array("overrides").map { list in
                                                  try list.map { o -> FlowOverride in
                                                      guard let w = o.string("when") else { throw ToolFailure(message: "Each flow override needs 'when'") }
                                                      return FlowOverride(when: w, volume: o.double("volume"), volumeExpression: o.string("volume"),
                                                                          to: try o.uuids("to"))
                                                  }
                                              },
                                              replacing: a.string("id") == nil ? nil : try a.uuid("id"))
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            let line = DiagramOps.describeFlows(file.pages[p]).first { $0.contains(flow.id.uuidString) } ?? flow.id.uuidString
            return text((a.string("id") == nil ? "Added " : "Changed ") + line + on(file, p))

        case "define_state":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            var spec = StateSpec(name: try a.require("name"))
            if let v = a.bool("initial") { spec.initial = v }
            spec.hide = try a.uuids("hide") ?? []; spec.show = try a.uuids("show") ?? []; spec.dim = try a.uuids("dim") ?? []; spec.down = try a.uuids("down") ?? []
            if let v = a.double("dim_opacity") { spec.dimOpacity = v }
            func color(_ o: Args, _ k: String) throws -> RGBA? {
                guard let s = o.string(k) else { return nil }
                guard let c = RGBA.parse(s, in: DiagramOps.colorContext)?.color else {
                    throw ToolFailure(message: "'restyle' \(k) must be \(RGBA.expected(in: DiagramOps.colorContext)), got '\(s)'")
                }
                return c
            }
            for (k, v) in a.raw["restyle"]?.objectValue ?? [:] {
                guard let id = UUID(uuidString: k) else { throw ToolFailure(message: "'restyle' has an invalid element id: \(k)") }
                let o = Args(raw: v.objectValue ?? [:])
                spec.restyle[id] = StateOverride(when: spec.name, stroke: try color(o, "stroke"), fill: try color(o, "fill"),
                                                 textColor: try color(o, "text_color"), opacity: o.double("opacity"),
                                                 strokeWidth: o.double("stroke_width"),
                                                 dash: o.string("dash").flatMap(DashStyle.init(rawValue:)), text: o.string("text"),
                                                 cost: o.double("cost"))
                spec.restyle[id]?.capacity = o.double("capacity"); spec.restyle[id]?.delay = o.double("delay")
            }
            for (k, v) in a.raw["reroute"]?.objectValue ?? [:] {
                guard let from = UUID(uuidString: k), let to = v.stringValue.flatMap(UUID.init(uuidString:)) else {
                    throw ToolFailure(message: "'reroute' maps connector ids to connector ids")
                }
                spec.reroute[from] = to
            }
            spec.toggledBy = try a.uuids("toggled_by") ?? []
            spec.turnedOnBy = try a.uuids("turned_on_by") ?? []
            spec.turnedOffBy = try a.uuids("turned_off_by") ?? []
            let summary: String
            do { summary = try DiagramOps.defineState(&file.pages[p], spec) } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text("State " + summary + on(file, p))

        case "add_button", "add_choice", "add_reset", "add_legend":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            let summary: String
            do {
                switch currentTool {
                case "add_button":
                    var spec = ButtonSpec(text: try a.require("text"))
                    let origin = try controlOrigin(file.pages[p], a)
                    spec.x = origin.x; spec.y = origin.y
                    spec.width = a.double("width"); spec.height = a.double("height")
                    spec.toggles = a.string("toggles"); spec.onText = a.string("on_text"); spec.color = try a.color("color")
                    spec.sets = try a.flags("sets") ?? [:]
                    let b = try DiagramOps.addButton(&file.pages[p], spec)
                    summary = "Added button \(b.id.uuidString)"
                case "add_choice":
                    guard let options = a.raw["options"]?.arrayValue?.compactMap(\.stringValue), !options.isEmpty else {
                        throw ToolFailure(message: "'options' must be a list of labels")
                    }
                    let origin = try controlOrigin(file.pages[p], a)
                    let made = try DiagramOps.addChoice(&file.pages[p], name: try a.require("name"), options: options,
                                                        x: origin.x, y: origin.y,
                                                        row: a.string("direction") != "column", initial: a.string("initial"),
                                                        color: try a.color("color"))
                    summary = "Added a choice: " + made.map { "\($0.variable) (button \($0.button.id.uuidString))" }.joined(separator: ", ")
                case "add_reset":
                    let origin = try controlOrigin(file.pages[p], a)
                    let r = try DiagramOps.addReset(&file.pages[p], x: origin.x, y: origin.y,
                                                    text: a.string("text") ?? "Reset",
                                                    replacing: a.string("id") == nil ? nil : try a.uuid("id"), color: try a.color("color"))
                    summary = "Reset button \(r.id.uuidString) puts every variable back to its starting value"
                default:
                    var labels: [UUID: String] = [:]
                    for (k, v) in a.raw["labels"]?.objectValue ?? [:] {
                        guard let id = UUID(uuidString: k), let s = v.stringValue else { throw ToolFailure(message: "'labels' maps flow ids to text") }
                        labels[id] = s
                    }
                    let rows = try DiagramOps.addLegend(&file.pages[p], x: a.double("x") ?? 0, y: a.double("y") ?? 0, labels: labels)
                    summary = "Added a legend of \(rows.count) flow\(rows.count == 1 ? "" : "s") (variables show_1…show_\(rows.count))"
                }
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text(summary + on(file, p))

        case "script_api":
            if let name = a.string("example") {
                guard let e = ScriptExamples.named(name) else {
                    throw ToolFailure(message: "No example '\(name)'. Examples: " + ScriptExamples.all.map(\.name).joined(separator: ", "))
                }
                return text("// \(e.title): \(e.summary)\n// Run it with run_script on an empty page, then adapt it.\n\n" + e.code)
            }
            if a.string("format") == "typescript" { return text(DottieScript.typeDefinitions) }
            let installed = DottieScript.installedModules()
            return text(DottieScript.apiReference + "\n\nInstalled modules for require(): "
                + (installed.isEmpty ? "none (add .js files to \(DottieScript.modulesDirectory.path))" : installed.joined(separator: ", "))
                + "\n\nWorked examples (script_api with example): "
                + ScriptExamples.all.map { "\($0.name): \($0.summary)" }.joined(separator: "\n  "))

        case "list_extensions":
            return text(extensionListing())

        case "reload_extensions":
            return text(extensionListing(rescan: true))

        case "install_extension":
            let source = URL(fileURLWithPath: (try a.require("path_to_bundle") as NSString).expandingTildeInPath)
            let runtime = try ExtensionRuntime(bundle: source)
            if extensionRegistry().entries.contains(where: { $0.runtime?.manifest.id == runtime.manifest.id }) {
                throw ToolFailure(message: "An extension with id \(runtime.manifest.id) is installed already")
            }
            let folder = ExtensionRegistry.folder
            let destination = folder.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ToolFailure(message: "\(destination.lastPathComponent) already exists in the Extensions folder")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            return text("Installed \(runtime.manifest.name) \(runtime.manifest.version) at \(destination.path)")

        case "run_command":
            let url = try fileURL(a)
            var file = try load(url, createIfMissing: true)
            let p = try pageIndex(file, a)
            var doc = file.pages[p]
            let before = doc
            let extensionID = try a.require("extension")
            let runtimes = loadedRuntimes()
            guard let runtime = runtimes.first(where: { $0.manifest.id == extensionID }) else {
                throw ToolFailure(message: "No loaded extension with id '\(extensionID)'; see list_extensions")
            }
            let result = try runtime.runCommand(try a.require("command"), params: try extensionParams(a.raw["params"]),
                                                on: &doc, in: file, extensions: runtimes)
            var report = result.logs.joined(separator: "\n")
            func append(_ line: String) { report += (report.isEmpty ? "" : "\n") + line }
            if let error = result.error {
                append("Command error: \(error)")
                append("Nothing was changed.")
                return .init(content: [.plain(report)], isError: true)
            }
            if doc != before {
                file.pages[p] = doc
                try save(file, to: url)
                append("Applied\(on(file, p)): \(doc.elements.count) elements now (was \(before.elements.count)).")
            } else { append("No changes.") }
            if let value = result.value { append("Result: \(value)") }
            return text(report)

        case "run_script":
            let url = try fileURL(a)
            var file = try load(url, createIfMissing: true)
            let p = try pageIndex(file, a)
            var doc = file.pages[p]
            let before = doc
            let code = try a.require("code")
            let limit = min(max(a.double("timeout") ?? DottieScript.defaultTimeLimit, 1), 60)
            let modules = (a.raw["modules"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            let result = DottieScript.run(code, on: &doc, in: file, modules: modules, extensions: loadedRuntimes(), timeLimit: limit)
            let typeCheck = a.bool("typecheck") == false ? [] : DottieScript.typeCheckSummary(code)
            var report = result.logs.joined(separator: "\n")
            func append(_ line: String) { report += (report.isEmpty ? "" : "\n") + line }
            if let error = result.error {
                append("Script error: \(error)")
                append("Nothing was changed.")
                if let typeCheck { typeCheck.forEach(append) } else { append(DottieScript.typeScriptHint) }
                return .init(content: [.plain(report)], isError: true)
            }
            if doc != before {
                file.pages[p] = doc
                try save(file, to: url)
                append("Applied\(on(file, p)): \(doc.elements.count) elements now (was \(before.elements.count)).")
            }
            else { append("No changes.") }
            if let value = result.value { append("Result: \(value)") }
            typeCheck?.forEach(append)
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
            guard let made = file.pages[p].makeSymbol(of: Set(ids), name: name, button: a.bool("button") ?? false) else {
                throw ToolFailure(message: "None of those ids is a shape on this page.")
            }
            if let params = try a.strings("params"), let i = file.pages[p].symbols?.firstIndex(where: { $0.id == made.symbol.id }) {
                file.pages[p].symbols![i].params = params
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
                guard let v = SymbolPlayback(rawValue: s) else { throw ToolFailure(message: "'playback' must be loop, once, still or click") }
                playback = v
            }
            guard let e = file.pages[p].placeSymbol(symbol.id, at: CGPoint(x: x, y: y), size: size, playback: playback,
                                                    offset: a.double("offset")) else { throw ToolFailure(message: "Couldn't place it") }
            if let args = try a.strings("args"), let i = file.pages[p].elements.lastIndex(where: { $0.id == e.id }) {
                file.pages[p].elements[i].args = args
            }
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
            var list = try json(DiagramOps.summarize(file.pages[p]))
            let flows = DiagramOps.describeFlows(file.pages[p])
            if !flows.isEmpty { list = "Flows:\n" + flows.map { "  " + $0 }.joined(separator: "\n") + "\n" + list }
            let measured = DiagramOps.describeMetrics(file.pages[p])
            if !measured.isEmpty, !flows.isEmpty {
                list = "Metrics (starting values):\n" + measured.map { "  " + $0 }.joined(separator: "\n") + "\n" + list
            }
            let vars = DiagramOps.describeVariables(file.pages[p])
            if !vars.isEmpty { list = "Variables:\n" + vars.map { "  " + $0 }.joined(separator: "\n") + "\n" + list }
            let warnings = DiagramOps.stateWarnings(file.pages[p])
            if !warnings.isEmpty { list = "Warnings:\n" + warnings.map { "  - " + $0 }.joined(separator: "\n") + "\n" + list }
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

        case "drill_in":
            let url = try fileURL(a)
            var file = try load(url)
            let id = try a.uuid("id")
            let made: DottieFile.DrillIn
            do { made = try file.drillIn(from: id, pageName: a.string("page_name"), back: a.bool("back") ?? true) }
            catch { throw ToolFailure(message: "\(error)") }
            try save(file, to: url)
            let i = file.index(of: made.page)!
            var lines = ["\(made.newPage ? "Added" : "Using") page \"\(file.pages[i].name)\" (\(i + 1) of \(file.pages.count)): "
                         + "\(id.uuidString) now leads to its title \(made.title.uuidString)"]
            if let back = made.back { lines.append("Back: \(back.uuidString) leads back to \(id.uuidString)") }
            lines.append("Draw the details on page \"\(file.pages[i].name)\"; export with export_animation pages: all or split.")
            var content: [Tool.Content] = [.plain(lines.joined(separator: "\n"))]
            if let png = Exporter.png(file.pages[i].still, scale: 1) { content.insert(.png(png), at: 0) }
            return .init(content: content)

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
            let page = file.pages[try pageIndex(file, a)].starting(with: try a.state())
            var doc = a.double("at").map(page.resolved) ?? page.still
            if let r = a.roughness { doc = doc.withRoughness(r) }
            guard !doc.elements.isEmpty else { throw ToolFailure(message: "The diagram is empty; nothing to render") }
            let includeImage = a.bool("include_image") ?? true
            guard includeImage || a.string("out_path") != nil else {
                throw ToolFailure(message: "include_image: false needs an out_path to save the image to")
            }
            let listing = a.string("elements") ?? "full"
            guard ["full", "compact", "none"].contains(listing) else {
                throw ToolFailure(message: "'elements' must be full, compact or none, got '\(listing)'")
            }
            let scale = DiagramOps.exportScale(doc, scale: a.double("scale"), maxWidth: a.double("max_width"))
            guard let png = Exporter.png(doc, scale: scale) else { throw ToolFailure(message: "Rendering failed") }
            let size = Exporter.bounds(of: doc)
            var note = "Rendered \(doc.elements.count) elements, \(Int((size.width * scale).rounded()))x\(Int((size.height * scale).rounded())) "
                + "pixels at scale \((scale * 1000).rounded() / 1000)"
            if a.string("out_path") != nil {
                let out = try fileURL(a, key: "out_path", ext: "png")
                try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: out, options: .atomic)
                note += ", saved to \(out.path)"
            }
            let map = DiagramOps.annotations(doc, scale: scale)
            switch listing {
            case "none": break
            case "compact": note += "\nElements in the image (id kind x,y widthxheight, pixels from its top-left):\n" + DiagramOps.compactAnnotations(map)
            default: note += "\nElements in the image (pixels from its top-left):\n" + (try json(map))
            }
            return .init(content: (includeImage ? [.png(png)] : []) + [.plain(note)])

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
            let page = file.pages[try pageIndex(file, a)].starting(with: try a.state())
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
             "update_scene", "clear_animation":
            return try animation(name, a)

        case "export_animation":
            if let pages = try a.string("pages") {
                return try exportPages(a, mode: pages)
            }
            let file = try load(try fileURL(a))
            var doc = file.pages[try pageIndex(file, a)].starting(with: try a.state())
            if let r = a.roughness { doc = doc.withRoughness(r) }
            guard let timeline = doc.timeline else {
                throw ToolFailure(message: "This page has no animation; add one with run_script (dottie.timeline, dottie.key, ...)")
            }
            let raw = try a.require("out_path")
            let ext = URL(fileURLWithPath: raw).pathExtension.lowercased()
            guard ["gif", "apng", "mp4", "json", "html", "png"].contains(ext) else {
                throw ToolFailure(message: "'out_path' must end in .gif, .apng, .mp4, .json, .html or .png (a still of the poster frame, or of preview)")
            }
            let lottieMode = try a.string("lottie_mode").map { s -> Exporter.LottieMode in
                guard let m = Exporter.LottieMode(rawValue: s) else { throw ToolFailure(message: "'lottie_mode' must be smooth or exact") }
                return m
            } ?? .smooth
            let out = try fileURL(a, key: "out_path", ext: ext)
            let scale = min(max(a.double("scale") ?? 1.5, 0.25), 4)
            guard ext == "html" || !Exporter.animationTooLong(doc) else {
                throw ToolFailure(message: "The animation has more than \(Exporter.maxAnimationFrames) frames; shorten it or lower its fps")
            }
            let frame = a.double("preview").map(doc.resolved) ?? doc.still
            let data: Data? = switch ext {
            case "png": Exporter.png(frame, scale: scale, background: a.bool("transparent") == true ? nil : CGColor(gray: 1, alpha: 1))
            case "gif": Exporter.gif(doc, scale: scale)
            case "apng": Exporter.apng(doc, scale: scale, background: a.bool("transparent") == true ? nil : CGColor(gray: 1, alpha: 1))
            case "mp4": Exporter.mp4(doc, scale: scale)
            case "json": Exporter.lottie(doc, mode: lottieMode, transparent: a.bool("transparent") == true, name: doc.name)
            default: Exporter.player(doc, title: doc.name, allowLogic: a.bool("allow_logic") == true).map { Data($0.utf8) }
            }
            guard let data else { throw ToolFailure(message: "Rendering failed") }
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: out, options: .atomic)
            let what = ext == "png" ? "the frame at \(Self.secs(a.double("preview") ?? timeline.poster ?? timeline.duration))"
                : "\(timeline.frameCount) frames (\(timeline.duration)s at \(timeline.fps) fps)"
            var content: [Tool.Content] = [.plain("Exported \(what) to \(out.path)")]
            if !frame.elements.isEmpty, let png = Exporter.png(frame, scale: 1) { content.insert(.png(png), at: 0) }
            return .init(content: content)

        case "simulate":
            return try simulate(a)

        case "add_container":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            let c: Element
            do {
                var frame: CGRect?
                if let w = a.double("width"), let h = a.double("height") { frame = CGRect(x: a.double("x") ?? 0, y: a.double("y") ?? 0, width: w, height: h) }
                c = try DiagramOps.addContainer(&file.pages[p], title: a.string("title"), children: try a.uuids("ids") ?? [], frame: frame,
                                                lanes: try a.string("lanes").map { s in
                                                    guard let l = LaneDirection(rawValue: s) else { throw ToolFailure(message: "'lanes' must be rows or columns") }
                                                    return l
                                                },
                                                parent: a.string("parent").flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) },
                                                roughness: a.roughness, fill: try a.color("fill"), stroke: try a.color("stroke"))
                try DiagramOps.nameColors(&file.pages[p], id: c.id, fill: a.string("fill"), stroke: a.string("stroke"), textColor: nil)
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            let saved = file.reconcilingContainers(from: loaded).pages[p].elements.first { $0.id == c.id } ?? c
            return text("id: \(c.id.uuidString)\nframe: x=\(saved.x) y=\(saved.y) w=\(saved.width) h=\(saved.height)" + on(file, p))

        case "add_group":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            let g: (frame: Element, label: Element)
            do {
                g = try DiagramOps.addGroup(&file.pages[p], ids: try a.uuids("ids") ?? [], label: try a.require("label"),
                                            padding: a.double("padding") ?? 24, color: try a.color("color") ?? RGBA(r: 0.6, g: 0.65, b: 0.72))
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text("Added group frame \(g.frame.id.uuidString) with label \(g.label.id.uuidString)" + on(file, p))

        case "add_alarm":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            let when: String
            do {
                when = try DiagramOps.addAlarm(&file.pages[p], ids: try a.uuids("ids") ?? [], metric: a.string("metric") ?? "load",
                                               at: a.double("at") ?? 1, color: try a.color("color") ?? RGBA(r: 0.86, g: 0.15, b: 0.15))
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text("Each turns its color while \(when)" + on(file, p))

        case "add_override":
            let url = try fileURL(a)
            var file = try load(url)
            let id = try a.uuid("id")
            let p = try pageIndex(file, a, element: id)
            var reroute: [UUID: UUID] = [:]
            for (k, v) in a.raw["reroute"]?.objectValue ?? [:] {
                guard let from = UUID(uuidString: k), let to = v.stringValue.flatMap(UUID.init(uuidString:)) else {
                    throw ToolFailure(message: "'reroute' maps connector ids to connector ids")
                }
                reroute[from] = to
            }
            let list: [StateOverride]
            do {
                var o = StateOverride(when: try a.require("when"), stroke: try a.color("stroke"), fill: try a.color("fill"),
                                      textColor: try a.color("text_color"), opacity: a.double("opacity"),
                                      strokeWidth: a.double("stroke_width"), dash: try a.string("dash").map { s in
                                          guard let d = DashStyle(rawValue: s) else { throw ToolFailure(message: "'dash' must be solid, dashed or dotted") }
                                          return d
                                      }, text: a.string("text"), reroute: reroute.isEmpty ? nil : reroute,
                                      offline: a.bool("offline"), cost: a.double("cost"))
                o.capacity = a.double("capacity"); o.delay = a.double("delay")
                list = try DiagramOps.addOverride(&file.pages[p], id: id, o)
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            return text("Overrides now:\n" + list.map { "  " + $0.summary }.joined(separator: "\n"))

        case "add_gauge":
            let url = try fileURL(a)
            var file = try load(url)
            let p = try pageIndex(file, a)
            let e: Element
            do {
                let dial = a.string("style") == "dial"
                let size = CGSize(width: a.double("width") ?? 160, height: a.double("height") ?? (dial ? 110 : 80))
                let frame = try a.string("near").map { try DiagramOps.gaugeFrame(file.pages[p], near: try a.uuid("of"), side: $0, size: size) }
                    ?? CGRect(x: a.double("x") ?? 0, y: a.double("y") ?? 0, width: size.width, height: size.height)
                e = try DiagramOps.addGauge(&file.pages[p], metric: try a.require("metric"), of: try a.uuid("of"), frame: frame,
                                            style: try a.string("style").map { s in
                                                guard let v = Gauge.Style(rawValue: s) else { throw ToolFailure(message: "'style' must be number, bar, dial or slots") }
                                                return v
                                            },
                                            max: a.double("max"), warn: a.double("warn"), alarm: a.double("alarm"), label: a.string("label"))
            } catch let e as OpsError { throw ToolFailure(message: e.description) }
            try save(file, to: url)
            let shown = file.pages[p].posed(at: 0).elements.first { $0.id == e.id }?.text?.replacingOccurrences(of: "\n", with: ": ") ?? ""
            return text("Added gauge \(e.id.uuidString) (\(shown) at the starting values)" + on(file, p))

        default:
            throw ToolFailure(message: "Unknown tool '\(name)'")
        }
    }

    /// The `simulate` tool: plays the page through the steps with `Simulation`.
    fileprivate func simulate(_ a: Args) throws -> CallTool.Result {
        var file = try load(try fileURL(a))
        let start = try pageIndex(file, a)
        file.pages[start] = file.pages[start].starting(with: try a.state())
        guard let steps = a.array("steps"), !steps.isEmpty else { throw ToolFailure(message: "Missing required argument 'steps'") }
        guard steps.count <= 200 else { throw ToolFailure(message: "At most 200 steps") }
        let scale = min(max(a.double("scale") ?? 1, 0.25), 4)
        var sim: Simulation
        do { sim = try Simulation(file: file, page: start, scene: a.string("start")) } catch { throw ToolFailure(message: "\(error)") }
        let recordURL = try a.string("record_path").map { path -> URL in
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard ["mp4", "gif", "png"].contains(ext) else { throw ToolFailure(message: "'record_path' must end in .mp4, .gif or .png") }
            return try fileURL(a, key: "record_path", ext: ext)
        }
        if recordURL != nil { sim.record() }
        var log = ["start: \(sim.summary)"]
        var images: [Tool.Content] = []
        for (n, step) in steps.enumerated() {
            if let target = step.string("click") {
                do { log.append("click \(target): \(try sim.click(target)). \(sim.summary)") }
                catch {
                    log.append("click \(target): \(error)")
                    return .init(content: images + [.plain(log.joined(separator: "\n"))], isError: true)
                }
            } else if let s = step.double("wait") {
                guard s.isFinite, s >= 0 else { throw ToolFailure(message: "Step \(n + 1): 'wait' must be seconds") }
                sim.wait(min(s, Timeline.maxDuration * 10))
                log.append("wait \(Self.secs(s)): \(sim.summary)")
            } else if step.bool("next") == true {
                sim.nextScene()
                log.append("next: \(sim.summary)")
            } else if step.bool("back") == true {
                log.append("back: \(sim.back()). \(sim.summary)")
            } else if step.bool("metrics") == true {
                let lines = DiagramOps.describeMetrics(sim.doc, at: sim.time, state: .values(sim.state), since: sim.sinceChange,
                                                       carried: sim.carried)
                log.append("metrics: " + (lines.isEmpty ? "no traffic" : "\n  " + lines.joined(separator: "\n  ")))
            } else if step.bool("routes") == true {
                let lines = DiagramOps.describeRoutes(sim.doc, at: sim.time, state: .values(sim.state), since: sim.sinceChange,
                                                      carried: sim.carried)
                log.append("routes: " + (lines.isEmpty ? "no flows" : "\n  " + lines.joined(separator: "\n  ")))
            } else if step.raw["snapshot"] != nil, step.bool("snapshot") != false {
                let picture = sim.picture
                guard !picture.elements.isEmpty, let png = Exporter.png(picture, scale: scale) else {
                    log.append("snapshot: nothing is drawn now"); continue
                }
                var line = "snapshot \(images.count + 1)"
                if step.string("snapshot") != nil {
                    let out = try fileURL(step, key: "snapshot", ext: "png")
                    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try png.write(to: out, options: .atomic)
                    line += " saved to \(out.path)"
                }
                log.append("\(line): \(sim.summary)")
                images.append(.png(png))
            } else {
                throw ToolFailure(message: "Step \(n + 1) must be {click}, {wait}, {next: true}, {back: true}, {snapshot}, {metrics: true} or {routes: true}")
            }
        }
        if let recordURL, let recording = sim.recording {
            let data: Data? = switch recordURL.pathExtension.lowercased() {
            case "mp4": Exporter.mp4(recording, scale: scale)
            case "gif": Exporter.gif(recording, scale: scale)
            default: Exporter.apng(recording, scale: scale)
            }
            guard let data else {
                log.append(recording.frames.count > Exporter.maxAnimationFrames
                           ? "record: more than \(Exporter.maxAnimationFrames) frames; wait less" : "record: rendering failed")
                return .init(content: images + [.plain(log.joined(separator: "\n"))], isError: true)
            }
            try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: recordURL, options: .atomic)
            log.append("recorded \(recordURL.path): \(recording.frames.count) frames, \(Self.secs(Double(recording.frames.count) / recording.fps))")
        }
        return .init(content: images + [.plain(log.joined(separator: "\n"))])
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
                if let w = a.string("when") { try DiagramOps.setWhen(&doc, id: dot.id, w) }
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
                doc.timeline!.addMarker(at: t, name: label, loop: a.bool("loop"))
                reply = "Scene \"\(label)\" at \(Self.secs(t))" + (a.bool("loop") == true ? ", looping" : "")
            case "update_scene":
                reply = try DiagramOps.editScene(&doc, scene: try a.require("scene"), rename: a.string("name"),
                                                 moveTo: a.raw["t"] == nil ? nil : try a.time("t"), loop: a.bool("loop"),
                                                 remove: a.bool("remove") ?? false)
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
        if let m = tl.markers, !m.isEmpty { lines.append("scenes: " + m.map { "\(secs($0.t)) \"\($0.name)\"" + ($0.loop == true ? " (loops)" : "") }.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
