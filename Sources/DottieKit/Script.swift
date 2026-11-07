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
                           extensions: [ExtensionRuntime] = [],
                           timeLimit: TimeInterval = defaultTimeLimit) -> ScriptResult {
        let host = Host(doc: doc, file: file, selection: selection, libraries: libraries,
                        modules: modules, modulesDirectory: modulesDirectory, extensions: extensions)
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
        var logs = host.logs
        if failure == nil {
            // An extension shape the script resized reflows rather than stretching; one that can't keeps its path.
            var edited = host.doc
            logs += edited.reflowExtensionShapes(from: doc, using: extensions, includingNew: true)
            doc = edited
        }
        return ScriptResult(logs: logs, value: json, error: failure, operations: host.operations)
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

        /// The extensions `dottie.shape({extension, params})` can draw from.
        let extensions: [ExtensionRuntime]

        init(doc: DottieDocument, file: DottieFile?, selection: [UUID], libraries: [StencilLibrary]?,
             modules: [String: String], modulesDirectory: URL?, extensions: [ExtensionRuntime]) {
            self.doc = doc; self.file = file; self.selection = selection; self.libraries = libraries
            self.modules = modules; self.modulesDirectory = modulesDirectory; self.extensions = extensions
        }

        func moduleSource(_ id: String) throws -> (path: String, text: String) {
            try DottieScript.moduleSource(id, modules: modules, directory: modulesDirectory)
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
            context.evaluateScript(DottieScript.runtimeShim)
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

            /// Where a connector end attaches: a side ("top", "right", "bottom", "left"), or a number for one of an
            /// extension shape's connection points.
            func connectionPoint(_ k: String) throws -> (Port?, Int?) {
                guard let v = raw[Args.normalize(k)] else { return (nil, nil) }
                if let s = v as? String {
                    guard let port = Port(rawValue: s) else { throw OpsError.invalid("'\(k)' must be top, right, bottom, left or a number, got '\(s)'") }
                    return (port, nil)
                }
                guard let n = (v as? NSNumber)?.doubleValue, n >= 0, n == n.rounded(), n < Double(Int32.max) else {
                    throw OpsError.invalid("'\(k)' must be top, right, bottom, left or a whole number from 0")
                }
                return (nil, Int(n))
            }
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
            /// A map of names to text, as a symbol's params and a copy's args are; numbers and booleans become text.
            /// Its keys are kept as written. Empty is nil.
            func strings(_ k: String) throws -> [String: String]? {
                guard let v = raw[Args.normalize(k)] else { return nil }
                guard let d = v as? [String: Any] else { throw OpsError.invalid("'\(k)' must be an object of names to text") }
                var out: [String: String] = [:]
                for (name, x) in d where !(x is NSNull) {
                    if let t = x as? String { out[name] = t } else if let n = x as? NSNumber { out[name] = n.stringValue }
                    else { throw OpsError.invalid("'\(k).\(name)' must be text") }
                }
                return out.isEmpty ? nil : out
            }

            /// Variable names to values, keys as written (`ClickAction.set`).
            func flags(_ k: String) throws -> [String: Bool]? {
                guard let v = raw[Args.normalize(k)] else { return nil }
                guard let d = v as? [String: Any] else { throw OpsError.invalid("'\(k)' must be an object of variable names to true or false") }
                var out: [String: Bool] = [:]
                for (name, x) in d {
                    guard let n = x as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                        throw OpsError.invalid("'\(k).\(name)' must be true or false")
                    }
                    out[name] = n.boolValue
                }
                return out
            }
            /// One name or a list of them (`ClickAction.toggle`).
            func names(_ k: String) throws -> [String]? {
                guard let v = raw[Args.normalize(k)] else { return nil }
                if let one = v as? String { return [one] }
                guard let list = v as? [Any], list.allSatisfy({ $0 is String }) else { throw OpsError.invalid("'\(k)' must be a name or a list of names") }
                return list as? [String]
            }

            /// A list of element ids (or one), as the JavaScript side sends them.
            func ids(_ k: String) throws -> [UUID] {
                guard let v = raw[Args.normalize(k)] else { return [] }
                let list = (v as? [Any]) ?? [v]
                return try list.map { x in
                    guard let s = x as? String, let u = UUID(uuidString: s) else { throw OpsError.invalid("'\(k)' must be element ids") }
                    return u
                }
            }
            /// An object of element ids to element ids (`reroute`).
            func idMap(_ k: String) throws -> [UUID: UUID] {
                guard let v = raw[Args.normalize(k)] else { return [:] }
                guard let d = v as? [String: Any] else { throw OpsError.invalid("'\(k)' must map connector ids to connector ids") }
                var out: [UUID: UUID] = [:]
                for (from, to) in d {
                    guard let f = UUID(uuidString: from), let s = to as? String, let t = UUID(uuidString: s) else {
                        throw OpsError.invalid("'\(k)' must map connector ids to connector ids")
                    }
                    out[f] = t
                }
                return out
            }
            /// A state override (`StateOverride`); `when` may be left out where the caller supplies it.
            func override(when fallback: String? = nil) throws -> StateOverride {
                let when = try PageState.checked(string("when") ?? fallback ?? "", metrics: true)
                guard let when else { throw OpsError.invalid("An override needs 'when', a condition like \"down\"") }
                var o = StateOverride(when: when, stroke: try color("stroke"), fill: try color("fill"),
                                      textColor: try color("textColor"), opacity: double("opacity"),
                                      strokeWidth: double("strokeWidth"), dash: try enumValue("dash", as: DashStyle.self),
                                      text: string("text"))
                let r = try idMap("reroute")
                if !r.isEmpty { o.reroute = Dictionary(uniqueKeysWithValues: r.map { ($0.key.uuidString, $0.value) }) }
                if bool("offline") == true { o.offline = true }
                o.cost = double("cost"); o.capacity = double("capacity"); o.delay = double("delay")
                return o
            }

            /// Sets `capacity` and `delay` on `id` when given; "" (null in the prelude) clears one.
            func measure(_ doc: inout DottieDocument, _ id: UUID) throws {
                func value(_ k: String) throws -> Double?? {
                    guard has(k) else { return nil }
                    if let s = raw[Args.normalize(k)] as? String, s.isEmpty { return .some(nil) }
                    guard let d = double(k) else { throw OpsError.invalid("'\(k)' is a number, or null to remove it") }
                    return .some(d)
                }
                let c = try value("capacity"), d = try value("delay")
                if c != nil || d != nil { try DiagramOps.setCapacity(&doc, id: id, capacity: c, delay: d) }
            }

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
                                gridSize: double("gridSize"), font: string("font"), fontSize: double("fontSize"),
                                waypoints: try points("waypoints"), hops: bool("hops"),
                                textColor: try string("textColor").map { $0.isEmpty ? nil : try color("textColor") },
                                cost: double("cost"))
            }
            /// A list of {x, y} points.
            func points(_ k: String) throws -> [CGPoint]? {
                guard has(k) else { return nil }
                guard let list = list(k) else { throw OpsError.invalid("'\(k)' must be a list of {x, y} points") }
                return try list.map { p in
                    guard let x = p.double("x"), let y = p.double("y") else { throw OpsError.invalid("Each of '\(k)' needs a number x and y") }
                    return CGPoint(x: x, y: y)
                }
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

        private static func describe(_ f: Flow) -> [String: Any] {
            var d: [String: Any] = ["id": f.id.uuidString, "from": f.from.uuidString, "to": f.to.map(\.uuidString),
                                    "every": f.interval, "speed": f.pace, "size": f.diameter]
            if let c = f.color { d["color"] = String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }
            if let w = f.when { d["when"] = w }
            if f.spread == true { d["spread"] = true }
            if let v = f.volume { d["volume"] = v }
            return d
        }

        private func describe(_ e: Element, index: [UUID: Element]? = nil) -> [String: Any] {
            let b = e.kind == .connector ? Connector.bounds(of: e, in: doc, index: index) : e.frame
            var d: [String: Any] = [
                "id": e.id.uuidString, "kind": e.kind.rawValue,
                "x": round1(b.minX), "y": round1(b.minY), "width": round1(b.width), "height": round1(b.height),
                "stroke": hex(e.style.stroke), "sketchy": e.style.roughness > 0,
                "strokeWidth": e.style.strokeWidth,
            ]
            if let t = e.text { d["text"] = t; d["fontSize"] = e.style.fontSize }
            if let c = e.style.textColor { d["textColor"] = hex(c) }
            if let f = e.style.font { d["font"] = f }
            if e.style.fill.a > 0 { d["fill"] = hex(e.style.fill) }
            if e.style.fillStyle != .solid { d["fillStyle"] = e.style.fillStyle.rawValue }
            if e.style.fillStyle == .grid { d["gridSize"] = e.style.cellSize }
            if e.style.dash != .solid { d["dash"] = e.style.dash.rawValue }
            if let r = e.rotation { d["rotation"] = round1(r * 180 / .pi) }
            if let g = e.groupID { d["group"] = g.uuidString }
            if let l = e.link { d["link"] = l.uuidString }
            if let u = e.url { d["url"] = u }
            if let n = e.anchor { d["anchor"] = n }
            if let c = e.click {
                var o: [String: Any] = [:]
                if let s = c.scene { o["scene"] = s }
                if let u = c.url { o["url"] = u }
                if let v = c.set { o["set"] = v }
                if let v = c.toggle { o["toggle"] = v }
                d["click"] = o
            }
            if let w = e.when { d["when"] = w }
            if let v = e.capacity { d["capacity"] = v }
            if let v = e.delay { d["delay"] = v }
            if let g = e.gauge {
                var o: [String: Any] = ["metric": g.metric, "of": g.of.uuidString, "style": (g.style ?? .number).rawValue]
                if let v = g.max { o["max"] = v }
                if let v = g.warn { o["warn"] = v }
                if let v = g.alarm { o["alarm"] = v }
                if let v = g.label { o["label"] = v }
                d["gauge"] = o
            }
            if let id = e.symbol {
                d["symbol"] = id.uuidString
                if let p = e.playback { d["playback"] = p.rawValue }
                if let o = e.offset { d["offset"] = o }
                if let g = e.args { d["args"] = g }
            }
            if let list = e.overrides {
                d["overrides"] = list.map { o -> [String: Any] in
                    var x: [String: Any] = ["when": o.when]
                    if let c = o.stroke { x["stroke"] = hex(c) }
                    if let c = o.fill { x["fill"] = hex(c) }
                    if let c = o.textColor { x["textColor"] = hex(c) }
                    if let v = o.opacity { x["opacity"] = v }
                    if let v = o.strokeWidth { x["strokeWidth"] = v }
                    if let v = o.dash { x["dash"] = v.rawValue }
                    if let v = o.text { x["text"] = v }
                    if let r = o.reroute { x["reroute"] = r.mapValues(\.uuidString) }
                    if o.offline == true { x["offline"] = true }
                    if let v = o.cost { x["cost"] = v }
                    if let v = o.capacity { x["capacity"] = v }
                    if let v = o.delay { x["delay"] = v }
                    return x
                }
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
                if let w = c.waypoints { d["waypoints"] = w.map { ["x": $0.x, "y": $0.y] } }
                if c.hops == true { d["hops"] = true }
                if let cost = c.cost { d["cost"] = cost }
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

            case "shape" where a.has("extension"):
                // dottie.shape({extension: {id, shape}, params, x, y, width, height, text, ...}): an extension's shape.
                guard let ext = a.object("extension"), let extID = ext.string("id"), let shape = ext.string("shape") else {
                    throw OpsError.invalid("'extension' needs an id and a shape")
                }
                guard let runtime = extensions.first(where: { $0.manifest.id == extID }) else {
                    throw OpsError.invalid("no installed extension with id '\(extID)'")
                }
                let x = a.double("x") ?? 0, y = a.double("y") ?? 0
                var frame: CGRect?
                if let w = a.double("width"), let h = a.double("height") { frame = CGRect(x: x, y: y, width: w, height: h) }
                let e = try DiagramOps.addExtensionShape(&doc, runtime: runtime, shape: shape,
                                                         params: try ExtensionValue.values(in: a.raw["params"] as? [String: Any] ?? [:]),
                                                         frame: frame, at: CGPoint(x: x, y: y), text: a.string("text"),
                                                         fill: try a.color("fill"), stroke: try a.color("stroke"),
                                                         look: try a.look())
                return describe(try element(e.id))

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
                if let w = a.string("when") { try DiagramOps.setWhen(&doc, id: e.id, w) }
                try a.measure(&doc, e.id)
                return describe(try element(e.id))

            case "connector":
                let routing = try a.enumValue("routing", as: Routing.self) ?? .straight
                let start = try a.connectionPoint("fromPort"), end = try a.connectionPoint("toPort")
                let c = try DiagramOps.addConnector(&doc, from: try a.uuid("from"), to: try a.uuid("to"), routing: routing,
                                                    arrow: a.bool("arrow") ?? true, port: (start.0, end.0),
                                                    portIndex: (start.1, end.1), roughness: a.roughness,
                                                    label: a.string("label"), look: try a.look())
                if let w = a.string("when") { try DiagramOps.setWhen(&doc, id: c.id, w) }
                try a.measure(&doc, c.id)
                return describe(try element(c.id))

            case "update":
                let id = try a.uuid("id")
                let text: String?? = a.has("text") ? .some(a.string("text").flatMap { $0.isEmpty ? nil : $0 }) : nil
                var link: UUID?? = nil
                if a.has("link") { link = .some(a.string("link") == "" ? nil : try a.uuid("link")) }
                var click: ClickAction?? = nil
                if a.has("click") {
                    let c = a.object("click")
                    click = .some(try DiagramOps.click(scene: c?.string("scene"), url: c?.string("url"),
                                                       set: try c?.flags("set"), toggle: try c?.names("toggle")))
                }
                var hover: HoverLook?? = nil
                if a.has("hover") {
                    if let h = a.object("hover") {
                        hover = .some(try DiagramOps.hover(nil, stroke: h.string("stroke"), fill: h.string("fill"), opacity: h.double("opacity")))
                    } else {
                        hover = .some(nil)
                    }
                }
                if a.has("playback") || a.has("offset") || a.has("args"), let i = doc.elements.firstIndex(where: { $0.id == id }), doc.elements[i].kind == .symbol {
                    if a.has("playback") { let p = try a.enumValue("playback", as: SymbolPlayback.self); doc.elements[i].playback = p == .loop ? nil : p }
                    if let o = a.double("offset") { doc.elements[i].offset = o == 0 || !o.isFinite ? nil : o }
                    if a.has("args") { doc.elements[i].args = try a.strings("args") }
                }
                try DiagramOps.update(&doc, id: id, text: text, x: a.double("x"), y: a.double("y"),
                                      width: a.double("width"), height: a.double("height"),
                                      fill: try a.color("fill"), stroke: try a.color("stroke"), roughness: a.roughness,
                                      routing: try a.enumValue("routing", as: Routing.self), look: try a.look(),
                                      link: link, url: a.has("url") ? .some(a.string("url")) : nil,
                                      anchor: a.has("anchor") ? .some(a.string("anchor")) : nil,
                                      click: click, hover: hover, otherPages: otherPages)
                if a.has("when") { try DiagramOps.setWhen(&doc, id: id, a.string("when")) }
                if a.has("overrides"), let i = doc.elements.firstIndex(where: { $0.id == id }) {
                    guard let list = a.list("overrides") else { throw OpsError.invalid("'overrides' must be a list of overrides, or null") }
                    let parsed = try list.map { try $0.override() }
                    doc.elements[i].overrides = parsed.isEmpty ? nil : parsed
                }
                try a.measure(&doc, id)
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
                                        arrow: e.bool("arrow") ?? true, label: e.string("label"), look: try e.look(),
                                        stroke: try e.color("stroke"), when: e.string("when"))
                }
                let direction = LayoutDirection(rawValue: a.string("direction") ?? "TB") ?? .topToBottom
                let ids = try DiagramOps.build(&doc, nodes: nodes, edges: edges, direction: direction, roughness: a.roughness ?? 1,
                                               font: a.string("font"))
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
                let name = a.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? tl.nextSceneName
                tl.addMarker(at: t, name: name, loop: a.bool("loop"))
                doc.timeline = tl
                // The name is what a click plays: dottie.update(id, {click: {scene: dottie.scene(2)}}).
                return name

            case "editScene":
                try DiagramOps.editScene(&doc, scene: a.string("scene") ?? "", rename: a.string("name"), moveTo: a.double("to"),
                                         loop: a.bool("loop"), remove: a.bool("remove") ?? false)
                return nil

            case "variable":
                let name = try a.require("name")
                if a.has("value") {
                    guard let v = a.bool("value") else { throw OpsError.invalid("A variable's value must be true or false (null removes it)") }
                    try doc.setVariable(name, to: v)
                } else {
                    try doc.setVariable(name, to: nil)
                }
                return doc.variables ?? [:]

            case "variables":
                return doc.variables ?? [:]

            case "flow":
                let f = try DiagramOps.addFlow(&doc, from: try a.uuid("from"), to: try a.ids("to"), every: a.double("every"),
                                               speed: a.double("speed"), color: try a.color("color"), size: a.double("size"),
                                               when: a.string("when"), spread: a.bool("spread"), volume: a.double("volume"),
                                               replacing: a.has("id") ? try a.uuid("id") : nil)
                return Self.describe(f)

            case "addOverride":
                guard let o = a.object("override") else { throw OpsError.invalid("addOverride takes an element and an override {when, ...}") }
                let id = try a.uuid("id")
                try DiagramOps.addOverride(&doc, id: id, try o.override())
                return describe(try element(id))

            case "gauge":
                let style = try a.enumValue("style", as: Gauge.Style.self)
                let e = try DiagramOps.addGauge(&doc, metric: try a.require("metric"), of: try a.uuid("of"),
                                                frame: CGRect(x: a.double("x") ?? 0, y: a.double("y") ?? 0,
                                                              width: a.double("width") ?? 0, height: a.double("height") ?? 0),
                                                style: style, max: a.double("max"), warn: a.double("warn"), alarm: a.double("alarm"),
                                                label: a.string("label"))
                return describe(e)

            case "metrics":
                let state: StateChoice = a.object("state").map { o in
                    .values(o.raw.compactMapValues { $0 as? Bool })
                } ?? .initial
                let m = doc.metrics(at: a.double("at") ?? 0, state: state, since: a.double("since"))
                var elements: [String: Any] = [:], flows: [String: Any] = [:]
                for (id, x) in m.elements where x.throughput > 0 || x.load != nil || x.backlog > 0 || x.delay > 0 || x.inFlight > 0 {
                    var o: [String: Any] = ["throughput": x.throughput, "delay": x.delay, "backlog": x.backlog, "depth": x.depth, "inFlight": x.inFlight]
                    if let l = x.load { o["load"] = l }
                    elements[id.uuidString] = o
                }
                for (id, x) in m.flows {
                    var o: [String: Any] = ["volume": x.volume, "placed": x.placed, "backlog": x.backlog, "backup": x.backup]
                    if let tr = x.transit { o["transit"] = tr }
                    flows[id.uuidString] = o
                }
                return ["elements": elements, "flows": flows]

            case "flows":
                return (doc.flows ?? []).map(Self.describe)

            case "removeFlow":
                return DiagramOps.removeFlow(&doc, try a.uuid("id"))

            case "button":
                var spec = ButtonSpec(text: try a.require("text"))
                spec.x = a.double("x") ?? 0; spec.y = a.double("y") ?? 0
                spec.width = a.double("width"); spec.height = a.double("height")
                spec.toggles = a.string("toggles"); spec.onText = a.string("onText"); spec.color = try a.color("color")
                if let s = a.object("sets") {
                    for (k, v) in s.raw {
                        guard let b = (v as? NSNumber).map(\.boolValue) else { throw OpsError.invalid("'sets' maps variable names to true or false") }
                        spec.sets[k] = b
                    }
                }
                let b = try DiagramOps.addButton(&doc, spec)
                return describe(try element(b.id))

            case "choice":
                guard let options = a.raw["options"] as? [String] else { throw OpsError.invalid("'options' is a list of names") }
                let made = try DiagramOps.addChoice(&doc, name: try a.require("name"), options: options,
                                                    x: a.double("x") ?? 0, y: a.double("y") ?? 0,
                                                    row: a.string("direction") != "column", initial: a.string("initial"),
                                                    color: try a.color("color"))
                return try made.map { m -> [String: Any] in
                    var d = describe(try element(m.button.id)); d["variable"] = m.variable; return d
                }

            case "reset":
                let r = try DiagramOps.addReset(&doc, x: a.double("x") ?? 0, y: a.double("y") ?? 0, text: a.string("text") ?? "Reset",
                                                replacing: a.has("id") ? try a.uuid("id") : nil, color: try a.color("color"))
                return describe(try element(r.id))

            case "legend":
                var labels: [UUID: String] = [:]
                for (k, v) in a.object("labels")?.raw ?? [:] {
                    guard let id = UUID(uuidString: k), let s = v as? String else { throw OpsError.invalid("'labels' maps flow ids to text") }
                    labels[id] = s
                }
                let rows = try DiagramOps.addLegend(&doc, x: a.double("x") ?? 0, y: a.double("y") ?? 0, labels: labels)
                return try rows.map { r -> [String: Any] in
                    ["swatch": describe(try element(r.swatch.id)), "label": describe(try element(r.label.id))]
                }

            case "defineState":
                var spec = StateSpec(name: try a.require("name"))
                if let v = a.bool("initial") { spec.initial = v }
                spec.hide = try a.ids("hide"); spec.show = try a.ids("show"); spec.dim = try a.ids("dim"); spec.down = try a.ids("down")
                if let v = a.double("dimOpacity") { spec.dimOpacity = v }
                if let r = a.object("restyle") {
                    for (k, _) in r.raw {
                        guard let id = UUID(uuidString: k), let look = r.object(k) else { throw OpsError.invalid("'restyle' maps element ids to looks") }
                        spec.restyle[id] = try look.override(when: spec.name)
                    }
                }
                spec.reroute = try a.idMap("reroute")
                spec.toggledBy = try a.ids("toggledBy"); spec.turnedOnBy = try a.ids("turnedOnBy"); spec.turnedOffBy = try a.ids("turnedOffBy")
                return try DiagramOps.defineState(&doc, spec)

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
                if let w = a.string("when") { try DiagramOps.setWhen(&doc, id: dot.id, w); return describe(try element(dot.id)) }
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
                if let params = try a.strings("params"), let i = doc.symbols?.firstIndex(where: { $0.id == made.symbol.id }) {
                    doc.symbols![i].params = params
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
                if let args = try a.strings("args"), let i = doc.elements.lastIndex(where: { $0.id == e.id }) {
                    doc.elements[i].args = args
                    return describe(doc.elements[i])
                }
                return describe(e)

            case "symbols":
                return (doc.symbols ?? []).map { s -> [String: Any] in
                    var d: [String: Any] = ["id": s.id.uuidString, "name": s.name, "width": s.width, "height": s.height,
                                            "duration": s.timeline?.duration ?? 0, "instances": doc.elements.filter { $0.symbol == s.id }.count]
                    if let p = s.params { d["params"] = p }
                    return d
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
      // A missing id is usually a lookup that found nothing, often in a snapshot taken before an update changed it.
      var idOf = function (x) {
        var id = x !== null && typeof x === "object" ? x.id : x;
        if (id === undefined || id === null || id === "") {
          throw new Error("Expected an element or its id, got " + (x === undefined ? "undefined" : JSON.stringify(x))
            + ". Objects from dottie.elements() and dottie.get() are snapshots: after dottie.update(), look the element up again.");
        }
        return id;
      };
      var merge = function (a, b) { var o = {}, k; for (k in a) o[k] = a[k]; for (k in b) o[k] = b[k]; return o; };
      // Element lists and maps keyed by element, as defineState takes them: one or a list; {id: value} or [[el, value]].
      var ids = function (v) { return v === undefined ? undefined : (Array.isArray(v) ? v : [v]).map(idOf); };
      var pairs = function (v, value) {
        if (v === undefined) return undefined;
        var out = {}, k;
        if (Array.isArray(v)) v.forEach(function (p) { out[idOf(p[0])] = value(p[1]); });
        else for (k in v) out[k] = value(v[k]);
        return out;
      };
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
          if (o.overrides === null) o.overrides = [];
          if (o.capacity === null) o.capacity = "";
          if (o.delay === null) o.delay = "";
          if (Array.isArray(o.overrides)) o.overrides = o.overrides.map(function (x) {
            if (!x || !x.reroute) return x;
            var r = {}, k;
            if (Array.isArray(x.reroute)) x.reroute.forEach(function (p) { r[idOf(p[0])] = idOf(p[1]); });
            else for (k in x.reroute) r[k] = idOf(x.reroute[k]);
            return merge(x, { reroute: r });
          });
          if (o.url === null) o.url = "";
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
        scene: function (t, name, o) {
          if (name && typeof name === "object") { o = name; name = undefined; }
          return call("scene", merge(o, { t: t, name: name }));
        },
        loopScene: function (scene, loop) { call("editScene", { scene: String(scene), loop: loop !== false }); },
        variable: function (name, value) { return call("variable", value === null ? { name: name } : { name: name, value: value === undefined ? false : value }); },
        variables: function () { return call("variables"); },
        flow: function (from, to, o) {
          return call("flow", merge(o, { from: idOf(from), to: (Array.isArray(to) ? to : [to]).map(idOf), id: o && o.id ? idOf(o.id) : undefined }));
        },
        flows: function () { return call("flows"); },
        addOverride: function (target, o) {
          var x = o || {};
          if (x.reroute) {
            var r = {}, k;
            if (Array.isArray(x.reroute)) x.reroute.forEach(function (p) { r[idOf(p[0])] = idOf(p[1]); });
            else for (k in x.reroute) r[k] = idOf(x.reroute[k]);
            x = merge(x, { reroute: r });
          }
          return call("addOverride", { id: idOf(target), override: x });
        },
        gauge: function (target, o) { return call("gauge", merge(o, { of: idOf(target) })); },
        metrics: function (o) { return call("metrics", o || {}); },
        removeFlow: function (flow) { return call("removeFlow", { id: idOf(flow) }); },
        button: function (o) { return call("button", o); },
        choice: function (name, options, o) { return call("choice", merge(o, { name: name, options: options })); },
        resetButton: function (o) { return call("reset", merge(o, { id: o && o.id ? idOf(o.id) : undefined })); },
        legend: function (o) {
          o = o || {};
          return call("legend", merge(o, { labels: pairs(o.labels, function (x) { return x; }) }));
        },
        defineState: function (name, o) {
          o = o || {};
          return call("defineState", merge(o, {
            name: name, hide: ids(o.hide), show: ids(o.show), dim: ids(o.dim), down: ids(o.down),
            toggledBy: ids(o.toggledBy), turnedOnBy: ids(o.turnedOnBy), turnedOffBy: ids(o.turnedOffBy),
            restyle: pairs(o.restyle, function (x) { return x; }), reroute: pairs(o.reroute, idOf),
          }));
        },
        renameScene: function (scene, name) { call("editScene", { scene: String(scene), name: name }); },
        moveScene: function (scene, t) { call("editScene", { scene: String(scene), to: t }); },
        removeScene: function (scene) { call("editScene", { scene: String(scene), remove: true }); },
        follow: function (id, path, t, o) { call("follow", merge(o, { id: idOf(id), path: idOf(path), t: t })); },
        packet: function (connector, t, o) { return call("packet", merge(o, { id: idOf(connector), t: t })); },
        animateBuild: function (o) { call("animateBuild", o); },
        selection: call("selection"),
      };
    })(this);
    """#

    /// Source for a module id already normalized by the JS shim (no `.`/`..`, no leading slash). Inline modules win,
    /// then files inside `directory` (symlinks included, nothing outside it), then the modules bundled with Dottie.
    static func moduleSource(_ id: String, modules: [String: String] = [:], directory: URL?) throws -> (path: String, text: String) {
        if let inline = modules[id] ?? modules[id + ".js"] { return (id, inline) }
        guard !id.isEmpty, !id.hasPrefix("/"), !id.contains("\\"), !id.split(separator: "/").contains("..") else {
            throw OpsError.invalid("Cannot load module '\(id)'")
        }
        guard let root = directory?.resolvingSymlinksInPath() else {
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
        throw OpsError.notFound("Cannot find module '\(id)'. Modules are .js files in \(root.path) or passed inline.")
    }

    /// What scripts and extensions share: console, inert timers, `performance.now`, and CommonJS `require` over
    /// `__source`, the host's module lookup. Evaluated before `prelude` (and alone in an extension's context).
    static let runtimeShim = #"""
    (function (g) {
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
      Elements returned by any call are snapshots, not live views: after dottie.update(id, {text}) an earlier     dottie.elements() result still holds the old text. Keep ids (they never change) and call dottie.get(id) or     dottie.elements() again to see an element as it is now.
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
      dottie.connect(from, to, {routing?, arrow?, label?, sketchy?, fromPort?, toPort?, ...look})   routing: straight | curved | elbow; \
        fromPort/toPort pin an end: top | right | bottom | left, or a number for an extension shape's connection points (0 up, as the shape declares them)
      dottie.stencil({name, x, y, library?, scale?, keepOriginalColors?, sketchy?})  returns {ids, width, height}
      dottie.build({nodes: [{key, text, kind?, fill?, width?, height?}], edges: [{from, to, routing?, arrow?, label?}], \
    direction?: "TB"|"LR", sketchy?, font?})   laid out below existing content; returns {key: id}

    Changing
      dottie.update(id, {text?, x?, y?, width?, height?, fill?, stroke?, sketchy?, routing?, link?, url?, anchor?, ...look})  returns the element
      link: another shape (id or element) this one jumps to when its badge is clicked in the app, on this page or \
    another (find it with dottie.pages()); null removes it
      url: where the badge goes outside the drawing instead: an http(s) or mailto link, or another drawing as a path \
    relative to this one ("plans/next.dottie#Login" opens it at the shape anchored Login, or the page named Login); \
    PDF and SVG exports make web links clickable, and the web players open them; null removes it. Setting url clears \
    link, and the other way round
      anchor: a hidden label for finding and linking to the element (never drawn); "" removes it
      click: {scene?, url?, set?, toggle?}: when the drawing plays on the web (HTML export, <dottie-player>), clicking \
    the element jumps to that scene (its name, which dottie.scene returns) and plays on to the next, or opens an http(s) \
    or mailto link. set: {name: true|false} and toggle: name or [names] change page variables (dottie.variable) without \
    stopping or moving the animation, alone or with a scene or link; null removes the click
      when: a condition on page variables, like "down", "!down" or "east && !west || maint": the element (and the \
    connectors attached to it) is drawn only while it holds; "" or null removes it. Packets, shapes and connectors \
    all take it, also as an option when made
      hover: {stroke?, fill?, opacity?}: how a clickable element looks under the pointer; null removes it
      dottie.remove(id | [ids])        deletes; connectors on a deleted shape stay as free arrows

    Symbols (drawings defined once and placed many times, each copy playing the symbol's own animation on its own clock)
      dottie.symbol([ids], {name?, button?, params?})    turns those shapes, with the arrows between them and their keys, into a \
    symbol, put back as one instance where they were; arrows and links from outside attach to the instance. Its \
    animation is the page timeline's length when made: set dottie.timeline({duration}) first to choose the loop. \
    button: true makes a Flash-style button: the page's scenes named up, over, down and hit (dottie.scene) move into \
    it as its states; copies show up, and on the web over under the pointer, down while pressed, and hit is the area \
    that takes clicks. Give a copy a click with dottie.update(copy, {click: {scene}}). params: {name: default} \
    that copies fill in, like Flash component parameters: write {{name}} in the symbol's text, and each copy shows its \
    own args value (or the default) there. Returns {symbol, instance}
      dottie.place(symbol, {x, y, width?, height?, playback?, offset?, args?})  another instance (symbol: its id or name); \
    playback: loop (default) | once | still | click (rests at the start; in <dottie-player> a click plays it once); \
    offset: seconds into the symbol's animation at the page's start, so copies don't move in step; a negative offset starts a once copy that many seconds into the page. args: {name: \
    value} for the symbol's params. An animated symbol gives a still page a timeline. Returns the element
      dottie.symbols()                 [{id, name, width, height, duration, instances, params?}]
      dottie.update(instance, {playback?, offset?, args?, ...})  instances move, resize, turn and fade like shapes, and take keys
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
      dottie.scene(t, name?, {loop?})  a scene marker: the HTML player stops at each, and next/back step through them. \
    Returns its name, which is what click: {scene} takes. loop: true makes a looping scene: playing doesn't stop on \
    entering it, and at its end (the next scene or the end) it goes back to its start, until a click or next leaves it
      dottie.renameScene(scene, name), dottie.moveScene(scene, t), dottie.removeScene(scene), dottie.loopScene(scene, \
    loop?)  change a scene, named by its name or its time; a rename keeps the clicks that play it

    State (diagrams people poke while they keep playing)
      dottie.variable(name, value?)  a page variable and its starting value (default false; null removes it); \
    returns every variable. Names are letters, digits and _, not starting with a digit. Clicks set and toggle them \
    on the web, elements with a when follow them, and the timeline keeps looping. Exports and previews show the \
    starting values; the editor shows every element while stopped. Inside a symbol, when sees no variables (all false)
      dottie.variables()               {name: startingValue}
      dottie.defineState(name, {initial?, hide?, show?, dim?, down?, dimOpacity?, restyle?, reroute?, toggledBy?, turnedOnBy?, \
    turnedOffBy?})  one variable described at once; writes the when conditions, overrides and clicks it means. hide: \
    drawn only while it is false; show: only while true; dim: faded while true; down: faded and carrying no flow \
    traffic while true (a region that's down: flows go round it); restyle: {id: look} while true; \
    reroute: {fromConnector: toConnector}, so the same packets take a detour while true; toggledBy, turnedOnBy, \
    turnedOffBy: elements whose click flips, sets or clears it. Running it again changes nothing more; returns a summary
      dottie.flow(from, to, {every?, speed?, color?, size?, when?, spread?, volume?, id?})  traffic from a shape to the first of to (a shape or \
    a list, preferred first) it can reach over the connectors drawn: a packet every every seconds (0.5) at speed \
    points per second (160), routed afresh each frame, so when a state hides a shape or connector the traffic goes \
    round it with nothing more drawn. A connector carries traffic from its start to its end, and back too when its \
    start has an arrowhead; the route is the cheapest by connector cost (1 each unless set: give a main path a lower \
    cost than its backup). One flow per region splits traffic, each with its own color, so a failed region's \
    packets keep its color on the regions that take them over; spread: true deals a flow's packets across every \
    other destination it can reach while the first is down, rather than all to the next. Packets vanish into the \
    shapes they pass through and come out the other side. Gives the page a 4-second timeline if it has none, and rounds every so the timeline \
    loops seamlessly. With id, changes that flow. Returns {id, from, to, every, speed, size, color?, when?}
      dottie.flows(), dottie.removeFlow(flow)  the page's flows; remove one by it or its id
      Capacity (ADR 0003), for showing a scenario (numbers are illustrative; this presents, it doesn't predict): \
    volume on a flow is how much it carries in the page's own unit (requests a second, \
    messages, trucks a day; default 1); the biggest flow draws a packet every `every`, the rest proportionally fewer. \
    capacity on a shape or connector (in dottie.rect/connect/update; null removes it) is the most volume it carries: \
    flows are placed in page order (earlier flows first), each on its cheapest route as far as it has room, the rest \
    on the next cheapest, and what fits nowhere is backlog, piled at the shape in front of the first full thing (a \
    queue in front of busy workers). delay on a shape is seconds traffic stays inside it when passing through. \
    Overrides may set capacity and delay too (half the workers down); a traffic spike is an extra flow with a when.
      dottie.metrics({at?, state?, since?})  {elements: {id: {throughput, load?, delay, backlog, depth, inFlight}}, flows: \
    {id: {volume, placed, backlog, backup, transit?}}}: load is throughput over capacity, backlog the rate a queue grows \
    at, depth how much has piled up (backlog times the seconds since the state last changed, since; default at), \
    backup the share not reaching the first destination, transit seconds end to end. A backlog's pile of packets \
    grows as you watch: the player counts from the last click, exports from the page's start
      dottie.gauge(target, {metric, x, y, width?, height?, style?, max?, warn?, alarm?, label?})  a gauge showing a \
    metric (throughput, load, delay, backlog, depth, inFlight, transit, backup) of an element or flow as a number, bar or \
    dial, green, amber at warn, red at alarm (load: 0.7 and 0.9); every renderer draws it
      dottie.addOverride(el, {when, ...})  adds an override, keeping the element's others (merged into one with the same \
    when); update with overrides replaces the whole list
      An override's condition can compare metrics, naming an element by its anchor or an element or flow by id: \
    {when: "load(workers) >= 0.9", stroke: "#dc2626"}; such an override changes only looks (no offline, cost, \
    capacity, delay or reroute), and a when on an element can't compare metrics
      Example: a queue in front of workers that take 2 a second:
        const api = dottie.rect({x: 0, y: 100, text: "api"}), q = dottie.rect({x: 200, y: 100, text: "queue", delay: 0.5});
        const w = dottie.rect({x: 400, y: 100, text: "workers", anchor: "workers", capacity: 2});
        dottie.connect(api, q); dottie.connect(q, w);
        dottie.flow(api, w, {volume: 3});   // 2 placed, 1 backlog in the queue
        dottie.gauge(w, {metric: "load", x: 400, y: 0, style: "bar"});
        dottie.update(w, {overrides: [{when: "load(workers) >= 1", stroke: "#dc2626", text: "workers (saturated)"}]});
      Controls, made of ordinary shapes, clicks and overrides (clicks work on the web):
      dottie.button({text, x, y, toggles?, sets?, onText?, width?, height?, color?})  a button that flips toggles or sets \
    sets ({name: bool}); filled, and labelled onText, while on. Returns it
      dottie.choice(name, [options], {x, y, direction?, initial?, color?})  exactly one on: variables name_option, each \
    click sets its own true and the rest false. Returns the buttons, each with its variable
      dottie.resetButton({x, y, text?, id?})  sets every variable back to its starting value (a click with reset: true, \
    so variables added later are covered too)
      dottie.legend({x, y, labels?})  a swatch and label per flow; clicking one hides or shows that flow (show_1, show_2…)
      Example: scenarios, each described once:
        const [normal, eastOut] = dottie.choice("scenario", ["normal", "east out"], {x: 40, y: 400});
        dottie.defineState(eastOut.variable, {down: east});
        dottie.resetButton({x: 300, y: 400}); dottie.legend({x: 600, y: 400});
      Example: failover: api sends to east, or west when east is down:
        dottie.flow(api, [east, west]);
        dottie.defineState("eastDown", {down: east, toggledBy: east});   // east fades, and traffic goes to west
      overrides (on dottie.update): [{when, stroke?, fill?, textColor?, opacity?, strokeWidth?, dash?, text?, \
    reroute?, offline?, cost?, capacity?, delay?}]: changes to one element while a condition holds, in order; opacity multiplies; cost: a \
    connector's cost meanwhile (a degraded link); offline: still \
    drawn but carries no flow traffic. Prefer these to a \
    second copy of a shape with the opposite when
      Example: a click that takes a region down while its packets keep flowing, the other way round:
        const east = dottie.rect({x: 300, y: 0, text: "east"}), west = dottie.rect({x: 300, y: 200, text: "west"});
        const eastLink = dottie.connect(api, east), westLink = dottie.connect(api, west);
        dottie.packet(eastLink, 0);
        dottie.defineState("eastDown", {dim: east, restyle: [[east, {text: "east (down)"}]],
                                        reroute: [[eastLink, westLink]], toggledBy: east});
      Check it with the simulate tool or an export with a state before calling it done.
      dottie.follow(id, path, t, {duration?, ease?, reverse?, orient?, laps?})  the element's center travels along \
    path (a connector's route or any shape's outline) from t, and stays at the end afterwards. orient turns it to \
    face along the path; laps > 1 goes round a closed outline more than once
      dottie.packet(connector, t, {duration?, color?, size?, label?, when?})  a dot (or with a label, a pill carrying that \
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
    strokeWidth 0.5-24, bowing 0-3, rotation degrees, startHead/endHead none|arrow|triangle|dot|bar (connectors), \
    waypoints [{x, y}, ...] (connectors: points the line bends through, start to end; [] removes them), hops true|false \
    (connectors: a small hop where the line crosses a connector drawn beneath it), cost 0-1000000 (connectors: what \
    flow traffic pays to take the line, default 1; flows take the cheapest route), \
    font (Caveat, Patrick Hand or Architects Daughter: handwriting, embedded in exports; an installed font, named in \
    exports but not embedded; "" for Helvetica Neue), fontSize 4-200, textColor hex (a shape's or connector's label; \
    "" follows the stroke again; setting stroke on update recolors the label too, as in Excalidraw).

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
enum ExecutionLimit {
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    static func apply(to context: JSContext, seconds: TimeInterval) {
        guard seconds > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
        let set = unsafeBitCast(symbol, to: SetLimit.self)
        set(JSContextGetGroup(context.jsGlobalContextRef), seconds, { _, _ in true }, nil)
    }
}
