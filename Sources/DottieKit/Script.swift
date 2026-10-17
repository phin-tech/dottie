import Foundation
import CoreGraphics
import JavaScriptCore

/// What a script run produced. `error` set means nothing was applied to the document.
public struct ScriptResult: Sendable, Equatable {
    /// Lines written with `console.log` (and friends), in order.
    public var logs: [String]
    /// The script's final value as JSON (a top-level `return` works too); nil when it is undefined.
    public var value: String?
    public var error: String?
    /// Number of `dottie.*` calls the script made.
    public var operations: Int
    public var succeeded: Bool { error == nil }
}

/// Runs JavaScript against a document, in JavaScriptCore. One engine for the app's script console and
/// the MCP server's `run_script` tool.
///
/// The context has no file system, network or timers: a script can only read and change the one
/// document it is given. Edits are transactional: they are applied to a copy and written back only
/// if the script finishes without throwing.
public enum DottieScript {
    public static let defaultTimeLimit: TimeInterval = 10
    /// Upper bound on `dottie.*` calls, so a loop that edits forever stops even without a time limit.
    /// ~/Library/Application Support/Dottie/Scripts: saved scripts, and `modules/` for `require`.
    public static var scriptsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dottie/Scripts", isDirectory: true)
    }
    public static var modulesDirectory: URL { scriptsDirectory.appendingPathComponent("modules", isDirectory: true) }

    /// Module names `require` can load from `directory`, for listing in the API reference.
    public static func installedModules(in directory: URL = modulesDirectory) -> [String] {
        var names = Set(BundledModules.sources.keys)
        if let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) {
            let base = directory.resolvingSymlinksInPath().path + "/"
            for case let url as URL in walker {
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.pathExtension == "js", resolved.path.hasPrefix(base) else { continue }
                names.insert(String(resolved.path.dropFirst(base.count).dropLast(3)))
            }
        }
        return names.sorted()
    }

    public enum ModuleCheck: Equatable, Sendable {
        case ok
        /// Loading it needs another module that is not available (a dependency, or a Node built-in).
        case missing(String)
        case failed(String)
    }

    /// Loads `module` from `directory` the way a script's `require` would, to vet a freshly downloaded file:
    /// ES-module syntax, Node-only APIs and missing dependencies all show up here instead of in a user's script.
    public static func check(module: String, in directory: URL) -> ModuleCheck {
        var doc = DottieDocument()
        let quoted = String(decoding: (try? JSONSerialization.data(withJSONObject: [module])) ?? Data("[\"\"]".utf8), as: UTF8.self)
        let r = run("require(\(quoted)[0]); 0", on: &doc, libraries: [], modulesDirectory: directory, timeLimit: 5)
        guard let error = r.error else { return .ok }
        if let open = error.range(of: "Cannot find module '"), let close = error[open.upperBound...].firstIndex(of: "'") {
            return .missing(String(error[open.upperBound..<close]))
        }
        return .failed(error)
    }

    static let operationLimit = 50_000
    static let logLimit = 200_000

    /// Runs `source` on one page. `selection` is what `dottie.selection` returns (the app passes the selected ids).
    /// `libraries` are the stencil libraries `dottie.stencils()` and `dottie.stencil()` see. `file` is the drawing
    /// the page belongs to, for `dottie.pages()` and links to other pages; it is read, never changed.
    public static func run(_ source: String, on doc: inout DottieDocument, in file: DottieFile? = nil, selection: [UUID] = [],
                           libraries: [StencilLibrary]? = nil, modules: [String: String] = [:],
                           modulesDirectory: URL? = DottieScript.modulesDirectory,
                           timeLimit: TimeInterval = defaultTimeLimit) -> ScriptResult {
        let host = Host(doc: doc, file: file, selection: selection, libraries: libraries,
                        modules: modules, modulesDirectory: modulesDirectory)
        guard let context = JSContext() else {
            return ScriptResult(logs: [], value: nil, error: "JavaScript is unavailable", operations: 0)
        }
        host.install(in: context)
        ExecutionLimit.apply(to: context, seconds: timeLimit)

        var failure: String?
        var json: String?
        var result = context.evaluateScript(source, withSourceURL: scriptURL)
        // A top-level `return` is a syntax error for a plain script; nothing ran, so wrap and retry. The source
        // starts on the wrapper's first line, so errors keep its line numbers.
        if let e = context.exception, isReturnSyntaxError(e) {
            context.exception = nil
            result = context.evaluateScript("(function () {" + source + "\n})()", withSourceURL: scriptURL)
        }
        if let e = context.exception {
            failure = describe(e)
        } else if host.failure == nil, let result, !result.isUndefined {
            json = jsonString(result, in: context)
        }
        failure = failure ?? host.failure
        if failure == nil { doc = host.doc }
        return ScriptResult(logs: host.logs, value: json, error: failure, operations: host.operations)
    }

    private static func isReturnSyntaxError(_ e: JSValue) -> Bool {
        e.forProperty("name")?.toString() == "SyntaxError" && (e.forProperty("message")?.toString() ?? "").lowercased().contains("return")
    }

    /// The script's source URL, so its frames can be told from the prelude's and modules' in a stack.
    private static let scriptURL = URL(string: "script.js")

    private static func describe(_ e: JSValue) -> String {
        var s = e.forProperty("message")?.isString == true ? (e.forProperty("name")?.toString() ?? "Error") + ": " + e.forProperty("message")!.toString() : e.toString() ?? "Error"
        // An error from a dottie call is made in the prelude, so its `line` is the prelude's; the innermost
        // frame in the script is the line that made the call.
        let stack = e.forProperty("stack")?.isString == true ? e.forProperty("stack")!.toString()! : ""
        if let m = stack.firstMatch(of: /script\.js:(\d+):/) { s += " (line \(m.1))" }
        else if let line = e.forProperty("line"), line.isNumber { s += " (line \(line.toInt32()))" }
        return s
    }

    private static func jsonString(_ v: JSValue, in context: JSContext) -> String? {
        if let s = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [v]), s.isString {
            return s.toString()
        }
        context.exception = nil
        return v.toString()
    }

    // MARK: Host

    /// Native half of the `dottie` object. Every bridge call is one string in, one string out.
    final class Host: @unchecked Sendable {
        var doc: DottieDocument
        let file: DottieFile?
        let selection: [UUID]
        let libraries: [StencilLibrary]?
        var logs: [String] = []
        var logBytes = 0
        var operations = 0
        /// A native error raised while the script was running, kept in case the script swallows it.
        var failure: String?

        let modules: [String: String]
        let modulesDirectory: URL?

        init(doc: DottieDocument, file: DottieFile?, selection: [UUID], libraries: [StencilLibrary]?,
             modules: [String: String], modulesDirectory: URL?) {
            self.doc = doc; self.file = file; self.selection = selection; self.libraries = libraries
            self.modules = modules; self.modulesDirectory = modulesDirectory
        }

        /// Source for a module id already normalized by the JS shim (no `.`/`..`, no leading slash).
        /// Inline modules win; files must stay inside the modules directory, symlinks included.
        func moduleSource(_ id: String) throws -> (path: String, text: String) {
            if let inline = modules[id] ?? modules[id + ".js"] { return (id, inline) }
            guard !id.isEmpty, !id.hasPrefix("/"), !id.contains("\\"), !id.split(separator: "/").contains("..") else {
                throw OpsError.invalid("Cannot load module '\(id)'")
            }
            guard let root = modulesDirectory?.resolvingSymlinksInPath() else {
                if let bundled = BundledModules.sources[id] { return (id, bundled) }
                throw OpsError.notFound("Cannot find module '\(id)'")
            }
            for candidate in [id + ".js", id, id + "/index.js"] {
                let url = root.appendingPathComponent(candidate).resolvingSymlinksInPath()
                var isDir: ObjCBool = false
                guard url.path.hasPrefix(root.path + "/"),
                      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                return (String(url.path.dropFirst(root.path.count + 1)), text)
            }
            if let bundled = BundledModules.sources[id] { return (id, bundled) }
            throw OpsError.notFound("Cannot find module '\(id)'. Modules are .js files in \(DottieScript.modulesDirectory.path) "
                + "or passed inline.")
        }

        func install(in context: JSContext) {
            let call: @convention(block) (String, String) -> String = { [unowned self] name, args in
                guard let ctx = JSContext.current() else { return "" }
                do { return try self.dispatch(name, args) }
                catch {
                    let message = (error as? OpsError)?.description ?? "\(error)"
                    ctx.exception = JSValue(newErrorFromMessage: message, in: ctx)
                    return ""
                }
            }
            let log: @convention(block) (String) -> Void = { [unowned self] line in
                guard self.logBytes < DottieScript.logLimit else { return }
                self.logBytes += line.utf8.count
                self.logs.append(line)
            }
            let source: @convention(block) (String) -> String = { [unowned self] id in
                guard let ctx = JSContext.current() else { return "" }
                do { let m = try self.moduleSource(id); return m.path + "\n" + m.text }
                catch {
                    ctx.exception = JSValue(newErrorFromMessage: (error as? OpsError)?.description ?? "\(error)", in: ctx)
                    return ""
                }
            }
            context.setObject(unsafeBitCast(source, to: AnyObject.self), forKeyedSubscript: "__source" as NSString)
            context.setObject(unsafeBitCast(call, to: AnyObject.self), forKeyedSubscript: "__dottie" as NSString)
            context.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "__log" as NSString)
            context.evaluateScript(DottieScript.prelude)
        }

        struct Args {
            let raw: [String: Any]
            /// Keys match regardless of case and underscores: `fillStyle`, `fill_style` and `fillstyle` are one key.
            init(_ raw: [String: Any]) {
                var norm: [String: Any] = [:]
                for (k, v) in raw where !(v is NSNull) { norm[Args.normalize(k)] = v }
                self.raw = norm
            }
            static func normalize(_ k: String) -> String { k.replacingOccurrences(of: "_", with: "").lowercased() }

            func string(_ k: String) -> String? { raw[Args.normalize(k)] as? String }
            func double(_ k: String) -> Double? { (raw[Args.normalize(k)] as? NSNumber).flatMap { $0.doubleValue } }
            func bool(_ k: String) -> Bool? {
                guard let n = raw[Args.normalize(k)] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
                return n.boolValue
            }
            func list(_ k: String) -> [Args]? {
                (raw[Args.normalize(k)] as? [Any])?.map { Args($0 as? [String: Any] ?? [:]) }
            }
            func has(_ k: String) -> Bool { raw[Args.normalize(k)] != nil }
            func object(_ k: String) -> Args? { (raw[Args.normalize(k)] as? [String: Any]).map(Args.init) }

            func require(_ k: String) throws -> String {
                guard let s = string(k), !s.isEmpty else { throw OpsError.invalid("Missing required argument '\(k)'") }
                return s
            }
            func uuid(_ k: String) throws -> UUID {
                let s = try require(k)
                guard let u = UUID(uuidString: s) else { throw OpsError.invalid("'\(k)' is not an element id: \(s)") }
                return u
            }
            func color(_ k: String) throws -> RGBA? {
                guard let s = string(k) else { return nil }
                guard let c = RGBA(hex: s) else { throw OpsError.invalid("'\(k)' must be a hex color like #ffcc00, got '\(s)'") }
                return c
            }
            func enumValue<T: RawRepresentable & CaseIterable>(_ k: String, as: T.Type) throws -> T? where T.RawValue == String {
                guard let s = string(k) else { return nil }
                guard let v = T(rawValue: s) else {
                    throw OpsError.invalid("'\(k)' must be one of \(T.allCases.map(\.rawValue).joined(separator: ", ")), got '\(s)'")
                }
                return v
            }
            func look() throws -> DiagramOps.Look {
                DiagramOps.Look(fillStyle: try enumValue("fillStyle", as: FillStyle.self),
                                dash: try enumValue("dash", as: DashStyle.self),
                                strokeWidth: double("strokeWidth"), bowing: double("bowing"),
                                startHead: try enumValue("startHead", as: Arrowhead.self),
                                endHead: try enumValue("endHead", as: Arrowhead.self), rotation: double("rotation"),
                                gridSize: double("gridSize"))
            }
            /// `sketchy: true|false` as a roughness override.
            var roughness: Double? { bool("sketchy").map { $0 ? 1 : 0 } }
        }

        func dispatch(_ name: String, _ json: String) throws -> String {
            operations += 1
            guard operations <= DottieScript.operationLimit else {
                throw OpsError.invalid("Script made more than \(DottieScript.operationLimit) dottie calls; stopping.")
            }
            let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
            let a = Args(parsed as? [String: Any] ?? [:])
            let out: Any? = try run(name, a)
            guard let out else { return "" }
            return String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.fragmentsAllowed]), as: UTF8.self)
        }

        // MARK: Operations

        private func element(_ id: UUID) throws -> Element {
            guard let e = doc.elements.first(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
            return e
        }

        private func hex(_ c: RGBA) -> String {
            func b(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
            let base = String(format: "#%02x%02x%02x", b(c.r), b(c.g), b(c.b))
            return c.a < 1 ? base + String(format: "%02x", b(c.a)) : base
        }

        private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

        private func describe(_ e: Element, index: [UUID: Element]? = nil) -> [String: Any] {
            let b = e.kind == .connector ? Connector.bounds(of: e, in: doc, index: index) : e.frame
            var d: [String: Any] = [
                "id": e.id.uuidString, "kind": e.kind.rawValue,
                "x": round1(b.minX), "y": round1(b.minY), "width": round1(b.width), "height": round1(b.height),
                "stroke": hex(e.style.stroke), "sketchy": e.style.roughness > 0,
                "strokeWidth": e.style.strokeWidth,
            ]
            if let t = e.text { d["text"] = t }
            if e.style.fill.a > 0 { d["fill"] = hex(e.style.fill) }
            if e.style.fillStyle != .solid { d["fillStyle"] = e.style.fillStyle.rawValue }
            if e.style.fillStyle == .grid { d["gridSize"] = e.style.cellSize }
            if e.style.dash != .solid { d["dash"] = e.style.dash.rawValue }
            if let r = e.rotation { d["rotation"] = round1(r * 180 / .pi) }
            if let g = e.groupID { d["group"] = g.uuidString }
            if let l = e.link { d["link"] = l.uuidString }
            if let n = e.anchor { d["anchor"] = n }
            if let c = e.click {
                var o: [String: Any] = [:]
                if let s = c.scene { o["scene"] = s }
                if let u = c.url { o["url"] = u }
                d["click"] = o
            }
            if let id = e.symbol {
                d["symbol"] = id.uuidString
                if let p = e.playback { d["playback"] = p.rawValue }
                if let o = e.offset { d["offset"] = o }
            }
            if let h = e.hover {
                var o: [String: Any] = [:]
                if let c = h.stroke { o["stroke"] = hex(c) }
                if let c = h.fill { o["fill"] = hex(c) }
                if let v = h.opacity { o["opacity"] = v }
                d["hover"] = o
            }
            if let layer = doc.layers.first(where: { $0.id == e.layerID }) { d["layer"] = layer.name }
            if let c = e.connector {
                d["routing"] = c.routing.rawValue
                if let f = c.start.elementID { d["from"] = f.uuidString }
                if let t = c.end.elementID { d["to"] = t.uuidString }
            }
            return d
        }

        /// A symbol on this page by id or name.
        private func symbolID(_ spec: String?) throws -> UUID {
            guard let spec, !spec.isEmpty else { throw OpsError.invalid("Missing required argument 'symbol'") }
            if let id = UUID(uuidString: spec), doc.symbolIndex[id] != nil { return id }
            if let s = doc.symbols?.first(where: { $0.name.caseInsensitiveCompare(spec) == .orderedSame }) { return s.id }
            throw OpsError.invalid("No symbol '\(spec)' on this page (see dottie.symbols())")
        }

        /// The file's other pages, as they were when the script started.
        private var otherPages: [DottieDocument] { file?.pages.filter { $0.id != doc.id } ?? [] }

        private func libs() -> [StencilLibrary] {
            libraries ?? ([StencilLibrary.starter] + StencilLibrary.load(directory: StencilLibrary.defaultDirectory).map(\.library))
        }

        private func run(_ name: String, _ a: Args) throws -> Any? {
            switch name {
            case "elements":
                let index = doc.elements.contains { $0.kind == .connector } ? doc.elementIndex : nil
                let kind = a.string("kind"), text = a.string("text")?.lowercased(), anchor = a.string("anchor")?.lowercased()
                return doc.elements
                    .filter { kind == nil || $0.kind.rawValue == kind }
                    .filter { anchor == nil || ($0.anchor ?? "").lowercased().contains(anchor!) }
                    .filter { text == nil || ($0.text ?? "").lowercased().contains(text!) }
                    .map { describe($0, index: index) }

            case "get":
                return describe(try element(try a.uuid("id")))

            case "shape":
                let kindName = a.string("kind") ?? "rectangle"
                guard let kind = ElementKind(rawValue: kindName), kind != .connector, kind != .path, kind != .freehand, kind != .image else {
                    throw OpsError.invalid("'kind' must be one of rectangle, ellipse, diamond, text, note, got '\(kindName)'")
                }
                let x = a.double("x") ?? 0, y = a.double("y") ?? 0
                var frame: CGRect?
                if let w = a.double("width"), let h = a.double("height") { frame = CGRect(x: x, y: y, width: w, height: h) }
                let e = try DiagramOps.addShape(&doc, kind: kind, frame: frame, at: CGPoint(x: x, y: y), text: a.string("text"),
                                                fill: try a.color("fill"), stroke: try a.color("stroke"),
                                                roughness: a.roughness, look: try a.look())
                if let n = a.string("anchor"), !n.isEmpty, let i = doc.elements.firstIndex(where: { $0.id == e.id }) { doc.elements[i].anchor = n }
                return describe(try element(e.id))

            case "connector":
                let routing = try a.enumValue("routing", as: Routing.self) ?? .straight
                let c = try DiagramOps.addConnector(&doc, from: try a.uuid("from"), to: try a.uuid("to"), routing: routing,
                                                    arrow: a.bool("arrow") ?? true, roughness: a.roughness,
                                                    label: a.string("label"), look: try a.look())
                return describe(c)

            case "update":
                let id = try a.uuid("id")
                let text: String?? = a.has("text") ? .some(a.string("text").flatMap { $0.isEmpty ? nil : $0 }) : nil
                var link: UUID?? = nil
                if a.has("link") { link = .some(a.string("link") == "" ? nil : try a.uuid("link")) }
                var click: ClickAction?? = nil
                if a.has("click") {
                    let c = a.object("click")
                    click = .some(try DiagramOps.click(scene: c?.string("scene"), url: c?.string("url")))
                }
                var hover: HoverLook?? = nil
                if a.has("hover") {
                    if let h = a.object("hover") {
                        hover = .some(try DiagramOps.hover(nil, stroke: h.string("stroke"), fill: h.string("fill"), opacity: h.double("opacity")))
                    } else {
                        hover = .some(nil)
                    }
                }
                if a.has("playback") || a.has("offset"), let i = doc.elements.firstIndex(where: { $0.id == id }), doc.elements[i].kind == .symbol {
                    if a.has("playback") { let p = try a.enumValue("playback", as: SymbolPlayback.self); doc.elements[i].playback = p == .loop ? nil : p }
                    if let o = a.double("offset") { doc.elements[i].offset = o == 0 || !o.isFinite ? nil : o }
                }
                try DiagramOps.update(&doc, id: id, text: text, x: a.double("x"), y: a.double("y"),
                                      width: a.double("width"), height: a.double("height"),
                                      fill: try a.color("fill"), stroke: try a.color("stroke"), roughness: a.roughness,
                                      routing: try a.enumValue("routing", as: Routing.self), look: try a.look(),
                                      link: link, anchor: a.has("anchor") ? .some(a.string("anchor")) : nil,
                                      click: click, hover: hover, otherPages: otherPages)
                return describe(try element(id))

            case "pages":
                let pages = file?.pages.map { $0.id == doc.id ? doc : $0 } ?? [doc]
                return pages.map { p -> [String: Any] in
                    let shapes = p.elements.filter { $0.kind != .connector }.map { e -> [String: Any] in
                        var d: [String: Any] = ["id": e.id.uuidString, "kind": e.kind.rawValue]
                        if let t = e.text { d["text"] = t }
                        if let n = e.anchor { d["anchor"] = n }
                        return d
                    }
                    return ["id": p.id.uuidString, "name": p.name, "current": p.id == doc.id, "shapes": shapes]
                }

            case "remove":
                var ids: [UUID] = []
                if let list = a.raw["ids"] as? [Any] {
                    for v in list {
                        guard let s = v as? String, let u = UUID(uuidString: s) else { throw OpsError.invalid("'ids' must be element ids") }
                        ids.append(u)
                    }
                } else {
                    ids = [try a.uuid("id")]
                }
                for id in ids { _ = try element(id) }
                doc.remove(Set(ids))
                return ids.count

            case "build":
                guard let nodeArgs = a.list("nodes"), !nodeArgs.isEmpty else { throw OpsError.invalid("'nodes' must be a non-empty array") }
                let nodes = try nodeArgs.map { n -> DiagramOps.NodeSpec in
                    let kindName = n.string("kind") ?? "rectangle"
                    guard let kind = ElementKind(rawValue: kindName), [.rectangle, .ellipse, .diamond, .text, .note].contains(kind) else {
                        throw OpsError.invalid("node 'kind' must be one of rectangle, ellipse, diamond, text, note, got '\(kindName)'")
                    }
                    return DiagramOps.NodeSpec(key: try n.require("key"), text: n.string("text") ?? "", kind: kind,
                                               fill: try n.color("fill"), width: n.double("width"), height: n.double("height"))
                }
                let edges = try (a.list("edges") ?? []).map { e in
                    DiagramOps.EdgeSpec(from: try e.require("from"), to: try e.require("to"),
                                        routing: try e.enumValue("routing", as: Routing.self),
                                        arrow: e.bool("arrow") ?? true, label: e.string("label"))
                }
                let direction = LayoutDirection(rawValue: a.string("direction") ?? "TB") ?? .topToBottom
                let ids = try DiagramOps.build(&doc, nodes: nodes, edges: edges, direction: direction, roughness: a.roughness ?? 1)
                return ids.mapValues(\.uuidString)

            case "layout":
                DiagramOps.autoLayout(&doc, direction: LayoutDirection(rawValue: a.string("direction") ?? "TB") ?? .topToBottom)
                return nil

            case "bounds":
                guard !doc.elements.isEmpty else { return ["x": 0, "y": 0, "width": 0, "height": 0] }
                let b = Exporter.bounds(of: doc, padding: 0)
                return ["x": round1(b.minX), "y": round1(b.minY), "width": round1(b.width), "height": round1(b.height)]

            case "selection":
                let live = Set(doc.elements.map(\.id))
                return selection.filter(live.contains).map(\.uuidString)

            case "stencils":
                let query = a.string("query")?.lowercased(), library = a.string("library")
                return libs()
                    .filter { library == nil || $0.name.caseInsensitiveCompare(library!) == .orderedSame }
                    .flatMap { lib in
                        lib.items.map { (lib: lib.name, item: $0) }
                    }
                    .filter { row in
                        guard let q = query else { return true }
                        return row.item.name.lowercased().contains(q) || row.item.tags.contains { $0.lowercased().contains(q) }
                    }
                    .map { ["library": $0.lib, "name": $0.item.name, "tags": $0.item.tags,
                            "width": $0.item.width, "height": $0.item.height] as [String: Any] }

            case "stencil":
                let wanted = try a.require("name"), library = a.string("library")
                guard let item = libs()
                    .filter({ library == nil || $0.name.caseInsensitiveCompare(library!) == .orderedSame })
                    .flatMap(\.items).first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                    throw OpsError.notFound("No stencil named '\(wanted)'. Call dottie.stencils() to see what is available.")
                }
                let placed = DiagramOps.addStencil(&doc, item: item, x: a.double("x") ?? 0, y: a.double("y") ?? 0,
                                                   scale: a.double("scale") ?? 1,
                                                   keepOriginalColors: a.bool("keepOriginalColors") ?? false,
                                                   roughness: a.roughness)
                return ["ids": doc.elements.map(\.id).filter(placed.ids.contains).map(\.uuidString),
                        "width": round1(placed.size.width), "height": round1(placed.size.height)] as [String: Any]

            case "timeline":
                var tl = doc.timeline ?? Timeline(duration: 0)
                if let v = a.double("fps") { tl.fps = min(max(v, 1), 60) }
                if let v = a.double("duration") { tl.duration = max(0, v) }
                if a.has("boil") { tl.boil = a.double("boil").map { max(0, Int($0)) }.flatMap { $0 == 0 ? nil : $0 } }
                if let v = a.bool("settle") { tl.settle = v }
                if a.has("poster") { tl.poster = a.double("poster").map { max(0, $0) } }
                if doc.timeline != nil || !a.raw.isEmpty { doc.timeline = tl }
                var info: [String: Any] = ["fps": tl.fps, "duration": tl.duration, "boil": tl.boil ?? 0,
                                           "settle": tl.settle ?? false, "frames": tl.frameCount]
                if let p = tl.poster { info["poster"] = p }
                return info

            case "key":
                let id = try a.uuid("id")
                _ = try element(id)
                guard let t = a.double("t"), t.isFinite, t >= 0, t <= Timeline.maxDuration else {
                    throw OpsError.invalid("'t' (seconds, 0 to \(Int(Timeline.maxDuration))) is required")
                }
                let k = Keyframe(t: t, x: a.double("x"), y: a.double("y"), width: a.double("width"), height: a.double("height"),
                                 rotation: a.double("rotation").map { $0 * .pi / 180 }, strokeWidth: a.double("strokeWidth"),
                                 stroke: try a.color("stroke"), fill: try a.color("fill"), visible: a.bool("visible"),
                                 reveal: a.double("reveal").map { min(max($0, 0), 1) },
                                 opacity: a.double("opacity").map { min(max($0, 0), 1) },
                                 ease: try a.enumValue("ease", as: Ease.self))
                var tl = doc.timeline ?? Timeline(duration: t)
                tl.duration = max(tl.duration, t)
                tl.setKey(k, for: id)
                doc.timeline = tl
                return nil

            case "transition":
                guard let tr = try a.enumValue("name", as: Transition.self) else {
                    throw OpsError.invalid("'name' must be one of \(Transition.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                let t = Timeline.clampTime(a.double("t") ?? 0)
                if let list = a.raw["ids"] as? [Any] {
                    let ids = try list.map { v -> UUID in
                        guard let s = v as? String, let u = UUID(uuidString: s) else { throw OpsError.invalid("'ids' must be element ids") }
                        return u
                    }
                    let stagger = a.double("stagger").map { $0.isFinite ? min(max($0, 0), 60) : 0.15 } ?? 0.15
                    return try doc.addTransition(tr, to: ids, at: t, stagger: stagger, duration: a.double("duration"))
                }
                let id = try a.uuid("id")
                let span = try doc.addTransition(tr, to: id, at: t, duration: a.double("duration"))
                // repeat: true plays it forever, a number plays it that many times in all.
                if a.bool("repeat") == true { doc.timeline!.addRepeat(for: id, from: span.start, to: span.end) }
                else if let n = a.double("repeat"), n.isFinite, n >= 2 {
                    doc.timeline!.addRepeat(for: id, from: span.start, to: span.end, count: Int(min(n, 10_000)))
                }
                return nil

            case "repeat":
                let id = try a.uuid("id")
                _ = try element(id)
                guard let start = a.double("start"), let end = a.double("end"), end > start else {
                    throw OpsError.invalid("'start' and 'end' (seconds, end after start) are required")
                }
                var tl = doc.timeline ?? Timeline(duration: end)
                tl.duration = max(tl.duration, end)
                tl.addRepeat(for: id, from: start, to: end, count: a.double("count").map { Int(min(max($0, 1), 10_000)) })
                doc.timeline = tl
                return nil

            case "camera":
                var tl = doc.timeline ?? Timeline(duration: 0)
                if a.has("clear") { tl.camera = nil; doc.timeline = tl; return nil }
                guard let t = a.double("t"), t.isFinite, t >= 0 else { throw OpsError.invalid("'t' (seconds) is required") }
                var rect: CGRect
                if let list = a.raw["ids"] as? [Any] {
                    let ids = Set(list.compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) })
                    let shapes = doc.elements.filter { ids.contains($0.id) }
                    guard !shapes.isEmpty else { throw OpsError.invalid("'ids' names no elements on this page") }
                    let index = doc.elementIndex
                    rect = shapes.map { $0.kind == .connector ? Connector.bounds(of: $0, in: doc, index: index) : $0.rotatedBounds }
                        .reduce(CGRect.null) { $0.union($1) }
                    let pad = a.double("padding") ?? 40
                    rect = rect.insetBy(dx: -pad, dy: -pad)
                } else {
                    guard let x = a.double("x"), let y = a.double("y"), let w = a.double("width"), let h = a.double("height"), w > 1, h > 1 else {
                        throw OpsError.invalid("give {x, y, width, height} or elements to frame")
                    }
                    rect = CGRect(x: x, y: y, width: w, height: h)
                }
                tl.setCamera(CameraKey(t: t, rect: rect, ease: try a.enumValue("ease", as: Ease.self)))
                doc.timeline = tl
                return ["x": round1(rect.minX), "y": round1(rect.minY), "width": round1(rect.width), "height": round1(rect.height)]

            case "scene":
                guard let t = a.double("t"), t.isFinite, t >= 0 else { throw OpsError.invalid("'t' (seconds) is required") }
                var tl = doc.timeline ?? Timeline(duration: t)
                tl.addMarker(at: t, name: a.string("name") ?? "Scene \((tl.markers?.count ?? 0) + 1)")
                doc.timeline = tl
                return nil

            case "follow":
                try doc.addFollow(try a.uuid("id"), along: try a.uuid("path"), at: max(0, a.double("t") ?? 0),
                                  duration: a.double("duration") ?? 1, ease: try a.enumValue("ease", as: Ease.self),
                                  reverse: a.bool("reverse") ?? false, orient: a.bool("orient") ?? false, laps: a.double("laps"))
                return nil

            case "packet":
                let dot = try doc.addPacket(along: try a.uuid("id"), at: max(0, a.double("t") ?? 0),
                                            duration: a.double("duration") ?? 0.6,
                                            color: try a.color("color") ?? RGBA(r: 0.95, g: 0.36, b: 0.33),
                                            size: min(max(a.double("size") ?? 14, 2), 200), label: a.string("label"))
                return describe(dot)

            case "animateBuild":
                try doc.addBuild(try a.enumValue("transition", as: Transition.self) ?? .popIn, at: max(0, a.double("start") ?? 0),
                                 stagger: a.double("stagger") ?? 0.4, packets: a.bool("packets") ?? false,
                                 drawArrows: a.bool("drawArrows") ?? false, travel: a.double("travel") ?? 0.6)
                return nil

            case "boil":
                let id = try a.uuid("id")
                _ = try element(id)
                var tl = doc.timeline ?? Timeline(duration: 0)
                tl.setBoil(a.bool("boil"), for: id)
                doc.timeline = tl
                return nil

            case "symbol":
                var ids: [UUID] = []
                for v in a.raw["ids"] as? [Any] ?? [] {
                    guard let str = v as? String, let id = UUID(uuidString: str) else { throw OpsError.invalid("symbol: 'ids' must be element ids") }
                    ids.append(id)
                }
                guard let made = doc.makeSymbol(of: Set(ids), name: a.string("name") ?? "Symbol \((doc.symbols?.count ?? 0) + 1)",
                                                button: a.bool("button") ?? false) else {
                    throw OpsError.invalid("symbol: give the ids of shapes on this page")
                }
                return ["symbol": made.symbol.id.uuidString, "instance": describe(made.instance)]

            case "place":
                let id = try symbolID(a.string("symbol"))
                let size: CGSize? = a.double("width").flatMap { w in a.double("height").map { CGSize(width: w, height: $0) } }
                    ?? a.double("width").map { w in let s = doc.symbolIndex[id]!; return CGSize(width: w, height: w * s.height / s.width) }
                    ?? a.double("height").map { h in let s = doc.symbolIndex[id]!; return CGSize(width: h * s.width / s.height, height: h) }
                guard let e = doc.placeSymbol(id, at: CGPoint(x: a.double("x") ?? 0, y: a.double("y") ?? 0), size: size,
                                              playback: try a.enumValue("playback", as: SymbolPlayback.self), offset: a.double("offset")) else {
                    throw OpsError.invalid("place: no symbol \(id.uuidString)")
                }
                return describe(e)

            case "symbols":
                return (doc.symbols ?? []).map { s -> [String: Any] in
                    ["id": s.id.uuidString, "name": s.name, "width": s.width, "height": s.height,
                     "duration": s.timeline?.duration ?? 0, "instances": doc.elements.filter { $0.symbol == s.id }.count]
                }

            case "breakApart":
                let id = try a.uuid("id")
                guard try element(id).kind == .symbol else { throw OpsError.invalid("breakApart: \(id.uuidString) isn't a symbol") }
                return doc.breakApart(id).map(\.uuidString).sorted()

            case "magicMove":
                guard let file else { throw OpsError.invalid("magicMove needs the drawing's other pages") }
                let spec = (a.raw["page"] as? NSNumber).map { String($0.intValue) } ?? (a.raw["page"] as? String) ?? ""
                let target = UUID(uuidString: spec).flatMap(file.page) ?? file.pageIndex(matching: spec).map { file.pages[$0] }
                guard let target, target.id != doc.id else {
                    throw OpsError.invalid("magicMove: no other page '\(spec)' (give a page's name, number or id)")
                }
                let s = try doc.magicMove(to: target, at: a.double("t"), duration: a.double("duration") ?? 1,
                                          ease: try a.enumValue("ease", as: Ease.self) ?? .easeInOut)
                return ["moved": s.moved, "entering": s.entering, "leaving": s.leaving]

            case "march":
                let id = try a.uuid("id")
                let e = try element(id)
                let speed = a.double("speed")
                var tl = doc.timeline ?? Timeline(duration: 0)
                tl.setMarch(speed, for: id)
                doc.timeline = tl
                // Marching needs dashes to show: a solid line becomes dashed.
                if tl.track(for: id)?.march != nil, e.style.dash == .solid,
                   let i = doc.elements.firstIndex(where: { $0.id == id }) {
                    doc.elements[i].style.dash = .dashed
                }
                return nil

            default:
                throw OpsError.invalid("Unknown dottie call '\(name)'")
            }
        }
    }

    // MARK: JavaScript side

    /// The `dottie` object and `console`, defined over the native bridge.
    static let prelude = #"""
    (function (g) {
      var call = function (name, args) {
        var r = __dottie(name, JSON.stringify(args === undefined ? {} : args));
        return r === "" ? undefined : JSON.parse(r);
      };
      var idOf = function (x) { return x !== null && typeof x === "object" ? x.id : x; };
      var merge = function (a, b) { var o = {}, k; for (k in a) o[k] = a[k]; for (k in b) o[k] = b[k]; return o; };
      var kind = function (k) { return function (o) { return call("shape", merge(o, { kind: k })); }; };
      g.dottie = {
        elements: function (filter) { return call("elements", filter); },
        get: function (id) { return call("get", { id: idOf(id) }); },
        shape: function (o) { return call("shape", o); },
        rect: kind("rectangle"), ellipse: kind("ellipse"), diamond: kind("diamond"), text: kind("text"), note: kind("note"),
        connect: function (from, to, o) { return call("connector", merge(o, { from: idOf(from), to: idOf(to) })); },
        update: function (id, changes) {
          var o = merge(changes, { id: idOf(id) });
          if (o.link !== undefined) o.link = o.link === null ? "" : idOf(o.link); // null is dropped by the bridge
          if (o.click === null) o.click = "";
          if (o.hover === null) o.hover = "";
          return call("update", o);
        },
        remove: function (idOrIds) {
          return Array.isArray(idOrIds) ? call("remove", { ids: idOrIds.map(idOf) }) : call("remove", { id: idOf(idOrIds) });
        },
        build: function (o) { return call("build", o); },
        layout: function (o) { return call("layout", o); },
        bounds: function () { return call("bounds"); },
        stencils: function (o) { return call("stencils", o); },
        stencil: function (o) { return call("stencil", o); },
        pages: function () { return call("pages"); },
        timeline: function (o) { return call("timeline", o); },
        key: function (id, t, props) { call("key", merge(props, { id: idOf(id), t: t })); },
        transition: function (id, name, t, o) {
          if (Array.isArray(id)) return call("transition", merge(o, { ids: id.map(idOf), name: name, t: t }));
          call("transition", merge(o, { id: idOf(id), name: name, t: t }));
        },
        boil: function (id, on) { call("boil", { id: idOf(id), boil: on }); },
        symbol: function (ids, o) {
          return call("symbol", merge(o, { ids: (Array.isArray(ids) ? ids : [ids]).map(idOf) }));
        },
        place: function (symbol, o) {
          var s = symbol && typeof symbol === "object" ? (symbol.symbol || symbol.id) : symbol;
          return call("place", merge(o, { symbol: s }));
        },
        symbols: function () { return call("symbols"); },
        breakApart: function (id) { return call("breakApart", { id: idOf(id) }); },
        magicMove: function (page, o) {
          var p = page && typeof page === "object" ? page.id : page;
          return call("magicMove", merge(o, { page: p }));
        },
        march: function (id, o) {
          var speed = o === null ? null : typeof o === "number" ? o : (o && o.speed !== undefined ? o.speed : 40);
          call("march", { id: idOf(id), speed: speed });
        },
        repeat: function (id, start, end, count) { call("repeat", { id: idOf(id), start: start, end: end, count: count }); },
        camera: function (t, view, o) {
          if (t === null) return call("camera", { clear: true });
          var target = Array.isArray(view) ? { ids: view.map(idOf) }
            : (view && view.x === undefined && (typeof view === "string" || view.id)) ? { ids: [idOf(view)] } : view;
          return call("camera", merge(merge(o, target), { t: t }));
        },
        scene: function (t, name) { call("scene", { t: t, name: name }); },
        follow: function (id, path, t, o) { call("follow", merge(o, { id: idOf(id), path: idOf(path), t: t })); },
        packet: function (connector, t, o) { return call("packet", merge(o, { id: idOf(connector), t: t })); },
        animateBuild: function (o) { call("animateBuild", o); },
        selection: call("selection"),
      };
      var fmt = function (v) {
        if (typeof v === "string") return v;
        if (v instanceof Error) return String(v);
        try { var s = JSON.stringify(v); return s === undefined ? String(v) : s; } catch (e) { return String(v); }
      };
      var write = function () { __log(Array.prototype.map.call(arguments, fmt).join(" ")); };
      g.console = { log: write, info: write, warn: write, error: write };

      // Scripts are synchronous, so there is no event loop: timers are accepted so libraries that schedule
      // work (d3-timer, d3-force) load, but never fire. Drive them by hand, e.g. simulation.stop().tick(300).
      var timerId = 0;
      g.setTimeout = g.setInterval = function () { return ++timerId; };
      g.clearTimeout = g.clearInterval = function () {};
      var t0 = Date.now();
      if (!g.performance) g.performance = { now: function () { return Date.now() - t0; } };

      // CommonJS-style require over the host's module lookup. Ids are normalized here, so the host only
      // ever sees paths inside the modules folder.
      var cache = {};
      var resolve = function (from, request) {
        var parts = /^\.\.?(\/|$)/.test(request) ? from.concat(request.split("/")) : request.split("/");
        var out = [];
        parts.forEach(function (p) {
          if (p === "" || p === ".") return;
          if (p === "..") { if (!out.length) throw new Error("Cannot load module '" + request + "'"); out.pop(); } else out.push(p);
        });
        return out.join("/").replace(/\.js$/, "");
      };
      var makeRequire = function (dir) {
        return function require(request) {
          var id = resolve(dir, String(request));
          if (cache[id]) return cache[id].exports;
          var loaded = __source(id), nl = loaded.indexOf("\n");
          var file = loaded.slice(0, nl), src = loaded.slice(nl + 1);
          var module = { exports: {}, id: id };
          cache[id] = module;
          try {
            var fn = new Function("module", "exports", "require", src + "\n//# sourceURL=" + id);
            fn.call(module.exports, module, module.exports, makeRequire(file.split("/").slice(0, -1)));
          } catch (e) { delete cache[id]; throw e; }
          return module.exports;
        };
      };
      g.require = makeRequire([]);
    })(this);
    """#

    /// A short reference for people and agents writing scripts.
    public static let apiReference = """
    Runs in JavaScript with one global, `dottie`, which edits the document. There is no file or network access.
    Edits apply only if the script finishes without throwing. The value of the last expression (or of a top-level `return`) \
    is returned as JSON; console.log output is returned too. Ids are strings; any call that takes an id also takes an \
    element object returned by another call. Colors are hex strings like "#ffcc00". Units are canvas points, y down.

    Types: the same API as TypeScript declarations is script_api with format "typescript" (the resource \
    dottie://dottie.d.ts); `dottie script-types <dir>` writes it with a tsconfig.json for an editor or `tsc -p .`. \
    When TypeScript's tsc is installed, run_script checks each script against it and lists mistakes (unknown \
    options, misspelled values) after the script's output; the script runs either way.

    Reading
      dottie.elements({kind?, text?, anchor?})  all elements: {id, kind, x, y, width, height, text, fill, stroke, from, to, ...}
      dottie.get(id)                   one element
      dottie.selection                 ids selected in the app (empty when run from an agent)
      dottie.pages()                   every page (tab) in order: {id, name, current, shapes: [{id, kind, text?, anchor?}]}; \
    the script edits only the current page
      dottie.bounds()                  {x, y, width, height} of all content
      dottie.stencils({query?, library?})  stencil items: {library, name, tags, width, height}

    Drawing (each returns the new element)
      dottie.rect/ellipse/diamond/text/note({x, y, width?, height?, text?, fill?, stroke?, sketchy?, ...look})
        (a note is a sticky note: its text is GitHub Flavored Markdown, tables included, drawn from the top left;
         a single newline is a line break; the fill defaults to yellow)
      dottie.shape({kind, ...})        same, with kind as a field
      dottie.connect(from, to, {routing?, arrow?, label?, sketchy?, ...look})   routing: straight | curved | elbow
      dottie.stencil({name, x, y, library?, scale?, keepOriginalColors?, sketchy?})  returns {ids, width, height}
      dottie.build({nodes: [{key, text, kind?, fill?, width?, height?}], edges: [{from, to, routing?, arrow?, label?}], \
    direction?: "TB"|"LR", sketchy?})   laid out below existing content; returns {key: id}

    Changing
      dottie.update(id, {text?, x?, y?, width?, height?, fill?, stroke?, sketchy?, routing?, link?, anchor?, ...look})  returns the element
      link: another shape (id or element) this one jumps to when its badge is clicked in the app, on this page or \
    another (find it with dottie.pages()); null removes it
      anchor: a hidden label for finding and linking to the element (never drawn); "" removes it
      click: {scene} or {url}: when the drawing plays on the web (HTML export, <dottie-player>), clicking the element \
    jumps to that scene (see dottie.scene) and plays on to the next, or opens an http(s) or mailto link; null removes it
      hover: {stroke?, fill?, opacity?}: how a clickable element looks under the pointer; null removes it
      dottie.remove(id | [ids])        deletes; connectors on a deleted shape stay as free arrows

    Symbols (drawings defined once and placed many times, each copy playing the symbol's own animation on its own clock)
      dottie.symbol([ids], {name?, button?})    turns those shapes, with the arrows between them and their keys, into a \
    symbol, put back as one instance where they were; arrows and links from outside attach to the instance. Its \
    animation is the page timeline's length when made: set dottie.timeline({duration}) first to choose the loop. \
    button: true makes a Flash-style button: the page's scenes named up, over, down and hit (dottie.scene) move into \
    it as its states; copies show up, and on the web over under the pointer, down while pressed, and hit is the area \
    that takes clicks. Give a copy a click with dottie.update(copy, {click: {scene}}). Returns {symbol, instance}
      dottie.place(symbol, {x, y, width?, height?, playback?, offset?})  another instance (symbol: its id or name); \
    playback: loop (default) | once | still | click (rests at the start; in <dottie-player> a click plays it once); \
    offset: seconds into the symbol's animation at the page's start, so copies don't move in step. An animated symbol gives a still page a timeline. Returns the element
      dottie.symbols()                 [{id, name, width, height, duration, instances}]
      dottie.update(instance, {playback?, offset?, ...})  instances move, resize, turn and fade like shapes, and take keys
      dottie.breakApart(instance)      replaces it with plain copies of what it shows at rest; returns their ids
      dottie.layout({direction?})      re-arranges all shapes into ranks along their connectors

    Animation (the current page's timeline; export it with `dottie render page.dottie -o out.gif`)
      dottie.timeline({fps?, duration?, boil?, settle?, poster?})  sets and returns {fps, duration, boil, settle, \
    frames, poster?}. boil: reseed sketchy lines every n frames (0 off). settle: boil a shape only while it moves. \
    poster: the second exports and previews show (default the end; the editor shows the page unanimated)
      dottie.key(id, t, {x?, y?, width?, height?, rotation?, strokeWidth?, stroke?, fill?, visible?, reveal?, opacity?, ease?})  \
    a keyframe at t seconds; each property tweens between the keys that set it. ease (towards the next key): \
    linear | easeIn | easeOut | easeInOut | hold | spring | bounce | elastic (the last three overshoot and settle). visible switches at the key: a lone visible:true key is where the \
    element appears. reveal 0-1 draws the stroke on (fill and text follow once it is complete); opacity 0-1 fades. \
    Connectors follow their shapes and hide with them; key only their visible, reveal and opacity.
      dottie.transition(id | [ids], name, t, {duration?, stagger?})  given a list, starts each stagger seconds \
    (default 0.15) after the last, in list order, and returns how many it animated (arrows only take drawIn and \
    fades). Canned keys: popIn, growIn, wipeIn, dropIn, slideIn, drawIn, fadeIn \
    (enter), popOut, shrinkOut, wipeOut, fadeOut (exit), pulse, wiggle (emphasis); arrows take drawIn, fadeIn, fadeOut
      dottie.boil(id, true|false|null)  keep this element boiling while still, never boil it, or follow the timeline
      dottie.magicMove(page, {t?, duration?, ease?})  Keynote-style Magic Move: tweens this page into another \
    page (its name, number or id) from t (default the end of the timeline) over duration (default 1 s, easeInOut). \
    Shapes match by anchor, else seed (a duplicated page keeps them), else identical text; matched shapes tween \
    frame, rotation, line width, colors and opacity (kind, text and other style stay this page's). Shapes only \
    this page has fade out; the other page's extras are copied in and fade in. Returns {moved, entering, leaving}
      dottie.march(id, {speed?} | speed | null)  marching ants: the line's dashes travel from its start to its end \
    at speed points per second (default 40; negative runs backwards) for the whole timeline, evened out to loop \
    seamlessly; a solid line becomes dashed. null stops it. For a live stream or flow direction on an arrow
      transition option repeat: true plays it forever, a number that many times (e.g. a pulse that never stops)
      dottie.repeat(id, start, end, count?)  play the element's keys from start to end again, count times in all \
    (default forever)
      dottie.camera(t, view, {ease?, padding?})  where exports look from t on: view is {x, y, width, height}, an \
    element, or a list of elements to frame (padding default 40). Views ease between keys; the first key's shape \
    sets the export's. dottie.camera(null) removes the camera
      dottie.scene(t, name?)  a scene marker: the HTML player stops at each, and next/back step through them
      dottie.follow(id, path, t, {duration?, ease?, reverse?, orient?, laps?})  the element's center travels along \
    path (a connector's route or any shape's outline) from t, and stays at the end afterwards. orient turns it to \
    face along the path; laps > 1 goes round a closed outline more than once
      dottie.packet(connector, t, {duration?, color?, size?, label?})  a dot (or with a label, a pill carrying that \
    text, like "POST /orders") that runs along the connector, shown only while it travels; returns it
      dottie.animateBuild({transition?, start?, stagger?, packets?, drawArrows?, travel?})  reveals every shape in \
    connector order with an entrance (default popIn). With packets a dot runs down each arrow, with drawArrows each \
    arrow draws itself on, and the shape it points to enters when it arrives (travel seconds later, default 0.6)

    Libraries
      require("name")                  loads name.js (or name/index.js) CommonJS/UMD modules from the modules \
      folder, or from the `modules` argument of run_script; ./ and ../ resolve relative to the requiring module. \
      Bundled: lodash, d3-array, d3-color, d3-hierarchy, dagre (graph layout: dagre.graphlib.Graph, dagre.layout), dayjs. Other single-file bundles work (the Scripting settings tab installs more); timers never fire, so step d3-force by hand with simulation.stop().tick(n); there is no npm, import syntax or Node built-ins.

    Look fields (any shape or connector): fillStyle solid|hachure|crossHatch|grid, dash solid|dashed|dotted, \
    gridSize 8-400 (cell size of a grid fill: a dungeon floor ruled on a page-wide lattice, Dyson hatching around it), \
    strokeWidth 0.5-24, bowing 0-3, rotation degrees, startHead/endHead none|arrow|triangle|dot|bar (connectors).

    Example
      const a = dottie.rect({x: 0, y: 0, text: "Start", fill: "#d6f5d6"});
      const b = dottie.diamond({x: 0, y: 140, text: "OK?"});
      dottie.connect(a, b, {routing: "elbow"});
      return dottie.elements().length;
    """
}

// MARK: Execution limit

/// JavaScriptCore can terminate a runaway script, but only through a function it does not declare in
/// its public headers. It is looked up at run time; if it is ever missing, scripts still run, they
/// just aren't time-limited (the operation limit still bounds ones that edit in a loop).
private enum ExecutionLimit {
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    static func apply(to context: JSContext, seconds: TimeInterval) {
        guard seconds > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
        let set = unsafeBitCast(symbol, to: SetLimit.self)
        set(JSContextGetGroup(context.jsGlobalContextRef), seconds, { _, _ in true }, nil)
    }
}
