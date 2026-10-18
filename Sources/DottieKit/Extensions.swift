import Foundation
import JavaScriptCore

/// The `dottieApi` major version this build runs. An extension built for another major version is listed with
/// the reason and not loaded.
public let dottieExtensionAPIMajor = 1

public enum ExtensionError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case incompatible(required: Int)
    case invalidParameter(String, String)
    case noSuchShape(String)
    case noSuchCommand(String)
    case failed(String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case .unreadable(let why): return why
        case .incompatible(let required):
            return "needs dottieApi \(required); this Dottie runs \(dottieExtensionAPIMajor)"
        case .invalidParameter(let name, let why): return "\(name): \(why)"
        case .noSuchShape(let id): return "no extension shape named \(id)"
        case .noSuchCommand(let id): return "no extension command named \(id)"
        case .failed(let message): return message
        case .invalidOutput(let why): return "generate returned something other than a path: \(why)"
        }
    }
}

/// `manifest.json` at the root of a `<name>.dottieext` bundle.
public struct ExtensionManifest: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var dottieApi: Int
    /// Reserved for the third-party phase; read, never acted on yet.
    public var permissions: [String]?
    public var category: String?
}

/// A parameter's value, as stored on an element and passed to `generate` or a command.
public enum ExtensionValue: Codable, Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        }
    }

    /// Parameter values from a JSON-like dictionary (a script's object, an MCP argument). Numbers, booleans and text
    /// are taken as they are; anything else is an error.
    public static func values(in raw: [String: Any]) throws -> [String: ExtensionValue] {
        var out: [String: ExtensionValue] = [:]
        for (name, v) in raw {
            if let n = v as? NSNumber {
                out[name] = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
            } else if let s = v as? String {
                out[name] = .string(s)
            } else {
                throw ExtensionError.invalidParameter(name, "must be a number, boolean or text")
            }
        }
        return out
    }

    /// The value as `JSContext` and JSON see it.
    var bridged: Any {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b
        case .string(let s): return s
        }
    }
}

/// One declared parameter of a shape or command. `default` is required, so every parameter has a value.
public struct ParameterSpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case number, integer, boolean, string
        case enumeration = "enum"
    }

    public var name: String
    public var type: Kind
    public var label: String?
    public var min: Double?
    public var max: Double?
    public var options: [String]?
    public var `default`: ExtensionValue

    /// Checks `value` against this parameter. Returns it unchanged when it fits.
    func validated(_ value: ExtensionValue) throws -> ExtensionValue {
        func reject(_ why: String) -> ExtensionError { .invalidParameter(name, why) }
        switch (type, value) {
        case (.boolean, .bool):
            return value
        case (.string, .string):
            return value
        case (.enumeration, .string(let s)):
            guard options?.contains(s) == true else { throw reject("\"\(s)\" is not one of \(options ?? [])") }
            return value
        case (.number, .number(let n)), (.integer, .number(let n)):
            guard n.isFinite else { throw reject("must be a finite number") }
            if type == .integer, n != n.rounded() { throw reject("must be a whole number") }
            if let min, n < min { throw reject("must be at least \(min)") }
            if let max, n > max { throw reject("must be at most \(max)") }
            return value
        default:
            throw reject("expected \(type.rawValue), got \(value)")
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, label, min, max, options
        case type
        case `default`
    }
}

/// One shape an extension provides, as declared by `extension.shape(...)` in its `main.js`.
public struct ShapeDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var parameters: [ParameterSpec]
    /// The adjustment handles the shape declares (v1.1), in the order declared. Missing means none.
    public var handles: [HandleDefinition]?
}

/// An adjustment handle: an on-canvas control that changes parameters by dragging. Its functions live in the
/// extension's JavaScript; this names it.
public struct HandleDefinition: Codable, Equatable, Sendable {
    public var id: String
}

/// One command an extension provides, as declared by `extension.command(...)`. `when` is "selection" when the
/// command belongs in the canvas context menu for a selection; `category` groups it in the Extensions menu.
public struct CommandDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var category: String?
    public var when: String?
    public var parameters: [ParameterSpec]
}

/// What an extension declares: its shapes and commands, in the order `main.js` declared them.
struct Described: Decodable {
    var shapes: [ShapeDefinition]
    var commands: [CommandDefinition]
}

/// What an extension shape's `generate` returned, normalized to the element's frame (0...1 on each axis).
public struct GeneratedShape: Equatable, Sendable {
    public var subpaths: [PathSubpath]
    public var ports: [NormalizedPoint]?
    public var labelRect: NormalizedRect?
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Stored on an extension shape: which shape of which extension made it, at what version, with which parameters.
public struct ExtensionRef: Codable, Equatable, Sendable {
    public var id: String
    public var shape: String
    public var version: String
    public var params: [String: ExtensionValue]

    public init(id: String, shape: String, version: String, params: [String: ExtensionValue]) {
        self.id = id; self.shape = shape; self.version = version; self.params = params
    }
}

/// A loaded `<name>.dottieext` bundle. Holds one long-lived `JSContext` for its `main.js`, rebuilt when a call
/// fails (a time-out leaves the context unusable). Shape functions are pure: plain data in, plain data out.
/// A runtime is not thread-safe: each process uses its runtimes from one thread at a time.
public final class ExtensionRuntime {
    /// How long one `generate`, `migrate` or command call may run before JavaScriptCore stops it.
    public static let callTimeLimit: TimeInterval = 2

    public let manifest: ExtensionManifest
    public let directory: URL
    public private(set) var shapes: [ShapeDefinition] = []
    public private(set) var commands: [CommandDefinition] = []
    private var context: JSContext?
    private let source: String
    /// `console` output from `main.js`, `generate`, `migrate` and handles, until `takeLogs` hands it on.
    private var logs: [String] = []
    static let logLimit = 200

    /// The `console` lines logged since the last call, for the Script Console or a tool's reply.
    public func takeLogs() -> [String] {
        defer { logs = [] }
        return logs
    }

    public init(bundle directory: URL) throws {
        self.directory = directory
        let manifestData: Data
        do { manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json")) }
        catch { throw ExtensionError.unreadable("no manifest.json") }
        do { manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData) }
        catch { throw ExtensionError.unreadable("manifest.json: \(error.localizedDescription)") }
        guard manifest.dottieApi == dottieExtensionAPIMajor else {
            throw ExtensionError.incompatible(required: manifest.dottieApi)
        }
        do { source = try String(contentsOf: directory.appendingPathComponent("main.js"), encoding: .utf8) }
        catch { throw ExtensionError.unreadable("no main.js") }
        try build()
    }

    /// Evaluates `main.js` in a fresh context and reads what it declared.
    private func build() throws {
        context = nil
        guard let context = JSContext() else { throw ExtensionError.failed("JavaScript is unavailable") }
        ExecutionLimit.apply(to: context, seconds: Self.callTimeLimit)
        // `require` reads only this bundle and the modules bundled with Dottie, so a bundle is self-contained.
        let directory = self.directory
        let lookup: @convention(block) (String) -> String = { id in
            guard let ctx = JSContext.current() else { return "" }
            do { let m = try DottieScript.moduleSource(id, directory: directory); return m.path + "\n" + m.text }
            catch {
                ctx.exception = JSValue(newErrorFromMessage: (error as? OpsError)?.description ?? "\(error)", in: ctx)
                return ""
            }
        }
        let log: @convention(block) (String) -> Void = { [weak self] line in
            guard let self, self.logs.count < Self.logLimit else { return }
            self.logs.append(line)
        }
        context.setObject(unsafeBitCast(lookup, to: AnyObject.self), forKeyedSubscript: "__source" as NSString)
        context.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "__log" as NSString)
        context.evaluateScript(DottieScript.runtimeShim)
        context.evaluateScript(Self.prelude, withSourceURL: directory.appendingPathComponent("prelude.js"))
        context.evaluateScript(source, withSourceURL: directory.appendingPathComponent("main.js"))
        if let e = context.exception { throw ExtensionError.failed(e.toString() ?? "error in main.js") }
        let described = context.objectForKeyedSubscript("__describe").call(withArguments: [])?.toString() ?? "{}"
        if let e = context.exception { throw ExtensionError.failed(e.toString() ?? "error reading shapes") }
        do {
            let d = try JSONDecoder().decode(Described.self, from: Data(described.utf8))
            shapes = d.shapes
            commands = d.commands
        } catch {
            throw ExtensionError.failed("shapes and commands: \(error.localizedDescription)")
        }
        self.context = context
    }

    public func shape(named id: String) -> ShapeDefinition? { shapes.first { $0.id == id } }

    /// Where an adjustment handle sits, in points from the frame's top-left, for `params` at this size.
    public func handlePosition(shape: String, handle: String, params: [String: ExtensionValue],
                               width: Double, height: Double) throws -> CGPoint {
        let params = try normalized(params, shape: shape)
        let raw = try call("__handlePosition", [shape, handle, params.mapValues(\.bridged), ["width": width, "height": height]])
        return try Self.point(raw, what: "position")
    }

    /// The parameters after dragging `handle` to `point` (in points from the frame's top-left). Only the drag
    /// function runs here; the caller regenerates the shape from the result, one step at a time as the drag moves.
    public func handleDrag(shape: String, handle: String, params: [String: ExtensionValue], width: Double, height: Double,
                           to point: CGPoint) throws -> [String: ExtensionValue] {
        let params = try normalized(params, shape: shape)
        let raw = try call("__handleDrag", [shape, handle, params.mapValues(\.bridged), ["width": width, "height": height],
                                            ["x": Double(point.x), "y": Double(point.y)]])
        guard let raw, let data = raw.data(using: .utf8) else { throw ExtensionError.failed("drag returned nothing") }
        do { return try Self.normalize(try JSONDecoder().decode([String: ExtensionValue].self, from: data),
                                       against: self.shape(named: shape)?.parameters ?? []) }
        catch let e as ExtensionError { throw e }
        catch { throw ExtensionError.failed("drag returned something other than parameters: \(error.localizedDescription)") }
    }

    private static func point(_ raw: String?, what: String) throws -> CGPoint {
        struct P: Decodable { var x: Double; var y: Double }
        guard let raw, let data = raw.data(using: .utf8), let p = try? JSONDecoder().decode(P.self, from: data),
              p.x.isFinite, p.y.isFinite else {
            throw ExtensionError.invalidOutput("handle \(what) must be {x, y} numbers")
        }
        return CGPoint(x: p.x, y: p.y)
    }

    /// Fills in defaults, drops unknown parameters and checks the rest against `parameters`.
    static func normalize(_ params: [String: ExtensionValue], against parameters: [ParameterSpec]) throws -> [String: ExtensionValue] {
        var out: [String: ExtensionValue] = [:]
        for spec in parameters {
            out[spec.name] = try spec.validated(params[spec.name] ?? spec.default)
        }
        return out
    }

    /// Normalizes parameters for a shape, so a stored or typed value is checked before `generate` sees it.
    public func normalized(_ params: [String: ExtensionValue], shape id: String) throws -> [String: ExtensionValue] {
        guard let shape = shape(named: id) else { throw ExtensionError.noSuchShape(id) }
        return try Self.normalize(params, against: shape.parameters)
    }

    /// Runs the shape's `generate` on normalized parameters. A throw, a time-out or output that isn't a path is an
    /// error; the caller keeps the element's last good path.
    public func generate(shape id: String, params: [String: ExtensionValue], width: Double, height: Double) throws -> GeneratedShape {
        let params = try normalized(params, shape: id)
        let raw = try call("__generate", [id, params.mapValues(\.bridged), ["width": width, "height": height]])
        guard let data = raw?.data(using: .utf8) else { throw ExtensionError.invalidOutput("nothing returned") }
        let decoded: RawShape
        do { decoded = try JSONDecoder().decode(RawShape.self, from: data) }
        catch { throw ExtensionError.invalidOutput(error.localizedDescription) }
        return try decoded.checked()
    }

    /// The parameters an element saved under another version mean at this one: runs the extension's `migrate` when
    /// the versions differ, then normalizes.
    public func migrated(_ ref: ExtensionRef) throws -> [String: ExtensionValue] {
        guard ref.version != manifest.version else { return try normalized(ref.params, shape: ref.shape) }
        let out = try call("__migrate_call", [ref.version, ref.params.mapValues(\.bridged), ref.shape])
        var params = ref.params
        if let out, let data = out.data(using: .utf8), let fresh = try? JSONDecoder().decode([String: ExtensionValue].self, from: data) {
            params = fresh
        }
        return try normalized(params, shape: ref.shape)
    }

    /// The script a command runs as: this bundle's code, then a call to the command, with the parameters checked
    /// first. Run it with `DottieScript.run` on a copy of the document, as `run_script` runs a script, so the command
    /// gets the full `dottie` object and is written back as one undo step only when it finishes.
    public func commandSource(_ id: String, params: [String: ExtensionValue]) throws -> String {
        guard let command = commands.first(where: { $0.id == id }) else { throw ExtensionError.noSuchCommand(id) }
        let values = try Self.normalize(params, against: command.parameters)
        let paramsJSON = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        let idJSON = String(decoding: try JSONSerialization.data(withJSONObject: [id], options: []), as: UTF8.self).dropFirst().dropLast()
        // The prelude shares line 1 with main.js, so error line numbers still match the bundle's.
        return Self.preludeOnOneLine + " " + source + "\n__runCommand(\(idJSON), \(paramsJSON));"
    }

    /// Runs a command on `doc` the way `run_script` runs a script, with `require` reading this bundle (and the
    /// modules bundled with Dottie) rather than the shared Scripts folder.
    public func runCommand(_ id: String, params: [String: ExtensionValue], on doc: inout DottieDocument,
                           in file: DottieFile? = nil, selection: [UUID] = [], extensions: [ExtensionRuntime] = [],
                           timeLimit: TimeInterval = DottieScript.defaultTimeLimit) throws -> ScriptResult {
        DottieScript.run(try commandSource(id, params: params), on: &doc, in: file, selection: selection,
                         modulesDirectory: directory, extensions: extensions, timeLimit: timeLimit)
    }

    /// Calls a prelude function by name. Any exception rebuilds the context, since a time-out leaves it unusable.
    private func call(_ name: String, _ arguments: [Any]) throws -> String? {
        guard let context else { throw ExtensionError.failed("extension is not loaded") }
        let result = context.objectForKeyedSubscript(name).call(withArguments: arguments)
        if let e = context.exception {
            context.exception = nil
            let message = e.toString() ?? "error"
            try? build()
            throw ExtensionError.failed(message)
        }
        guard let result, !result.isUndefined, !result.isNull else { return nil }
        return result.toString()
    }

    /// Declares the `extension` global. Each declaration is kept in order; `__describe` hands the lists to Swift.
    static let prelude = """
        var __shapes = {}, __commands = {}, __migrate = null;
        var extension = {
          shape: function (def) { __shapes[def.id] = def; },
          command: function (def) { __commands[def.id] = def; },
          migrate: function (fn) { __migrate = fn; }
        };
        function __params(def) {
          return Object.keys(def.parameters || {}).map(function (k) {
            return Object.assign({ name: k }, def.parameters[k]);
          });
        }
        function __describe() {
          return JSON.stringify({
            shapes: Object.keys(__shapes).map(function (k) {
              var s = __shapes[k];
              return { id: s.id, name: s.name, parameters: __params(s), handles: (s.handles || []).map(function (h) { return { id: h.id }; }) };
            }),
            commands: Object.keys(__commands).map(function (k) {
              var c = __commands[k];
              return { id: c.id, name: c.name, category: c.category || null, when: c.when || null, parameters: __params(c) };
            })
          });
        }
        function __generate(id, params, frame) {
          var s = __shapes[id];
          if (!s) throw new Error("no extension shape named " + id);
          var out = s.generate(params, frame);
          if (out === undefined || out === null) throw new Error(id + " generate returned nothing");
          return JSON.stringify(out);
        }
        function __handle(shape, handle) {
          var s = __shapes[shape];
          if (!s) throw new Error("no extension shape named " + shape);
          var h = (s.handles || []).filter(function (x) { return x.id === handle; })[0];
          if (!h) throw new Error("no handle named " + handle + " on " + shape);
          return h;
        }
        function __handlePosition(shape, handle, params, frame) {
          return JSON.stringify(__handle(shape, handle).position(params, frame));
        }
        function __handleDrag(shape, handle, params, frame, point) {
          return JSON.stringify(__handle(shape, handle).drag(params, frame, point));
        }
        function __migrate_call(from, params, shape) {
          if (!__migrate) return null;
          return JSON.stringify(__migrate(from, params, shape));
        }
        function __runCommand(id, params) {
          var c = __commands[id];
          if (!c) throw new Error("no extension command named " + id);
          return c.run(params);
        }
        """

    /// The prelude on one line, so a command's script keeps the bundle's line numbers.
    static let preludeOnOneLine = prelude.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")

    /// What `generate` returns, before it is checked.
    private struct RawShape: Decodable {
        struct Sub: Decodable { var closed: Bool; var coords: [Double] }
        var subpaths: [Sub]
        var ports: [NormalizedPoint]?
        var labelRect: NormalizedRect?

        func checked() throws -> GeneratedShape {
            guard !subpaths.isEmpty else { throw ExtensionError.invalidOutput("no subpaths") }
            var out: [PathSubpath] = []
            for sub in subpaths {
                // Bézier points: start, then c1, c2, end per segment, so 2 + 6n numbers.
                guard sub.coords.count >= 8, (sub.coords.count - 2) % 6 == 0, sub.coords.allSatisfy(\.isFinite) else {
                    throw ExtensionError.invalidOutput("a subpath needs 2 + 6n finite coordinates (start, then c1, c2, end per segment)")
                }
                out.append(PathSubpath(closed: sub.closed, coords: sub.coords))
            }
            return GeneratedShape(subpaths: out, ports: ports, labelRect: labelRect)
        }
    }
}

/// Every bundle in the Extensions folder, loaded or listed with the reason it wasn't.
public final class ExtensionRegistry {
    public struct Entry {
        /// The manifest's name when the bundle loads; the folder's name otherwise.
        public var name: String
        public var runtime: ExtensionRuntime?
        public var error: String?
        /// False when the user has switched the extension off in Settings. Its bundle is not loaded.
        public var enabled: Bool
    }

    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dottie/Extensions", isDirectory: true)
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Loads every `<name>.dottieext` in `directory`. A bundle with a duplicate id is listed, not loaded. Extensions
    /// whose ids are in `disabled` are listed as off and not loaded.
    public func scan(in directory: URL = ExtensionRegistry.folder, disabled: Set<String> = ExtensionRegistry.disabledIDs()) {
        let bundles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        entries = []
        var ids = Set<String>()
        for url in bundles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "dottieext" {
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let manifest = try Self.readManifest(url)
                if disabled.contains(manifest.id) {
                    entries.append(Entry(name: manifest.name, runtime: nil, error: nil, enabled: false))
                    continue
                }
                let runtime = try ExtensionRuntime(bundle: url)
                guard ids.insert(runtime.manifest.id).inserted else {
                    entries.append(Entry(name: name, runtime: nil, error: "another bundle already has id \(runtime.manifest.id)", enabled: true))
                    continue
                }
                entries.append(Entry(name: runtime.manifest.name, runtime: runtime, error: nil, enabled: true))
            } catch {
                entries.append(Entry(name: name, runtime: nil, error: (error as? ExtensionError)?.description ?? "\(error)", enabled: true))
            }
        }
    }

    /// The ids switched off in Settings, kept in `disabled.json` in the Extensions folder so the app, the MCP server
    /// and the CLI all agree.
    public static func disabledIDs(in directory: URL = ExtensionRegistry.folder) -> Set<String> {
        let file = directory.appendingPathComponent("disabled.json")
        guard let data = try? Data(contentsOf: file), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    /// Switches one extension on or off, writing `disabled.json`.
    public static func setDisabled(_ id: String, _ off: Bool, in directory: URL = ExtensionRegistry.folder) throws {
        var ids = disabledIDs(in: directory)
        if off { ids.insert(id) } else { ids.remove(id) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ids.sorted()).write(to: directory.appendingPathComponent("disabled.json"), options: .atomic)
    }

    /// Every file under `directory` with its size and modification time: equal fingerprints mean nothing a scan
    /// would see has changed (bundles, the modules they require, `disabled.json`).
    public static func fingerprint(of directory: URL = ExtensionRegistry.folder) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var out: [String] = []
        for case let url as URL in walk {
            let v = try? url.resourceValues(forKeys: Set(keys))
            out.append("\(url.path) \(v?.fileSize ?? -1) \(v?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)")
        }
        return out.sorted()
    }

    /// The manifest alone, so a disabled extension can be listed without running its code.
    public static func readManifest(_ directory: URL) throws -> ExtensionManifest {
        do {
            return try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        } catch {
            throw ExtensionError.unreadable("manifest.json: \(error.localizedDescription)")
        }
    }

    public func runtime(for extensionID: String) -> ExtensionRuntime? {
        entries.first { $0.runtime?.manifest.id == extensionID }?.runtime
    }

    /// Every loaded command, with the extension it belongs to.
    public var commands: [(extension: ExtensionRuntime, command: CommandDefinition)] {
        entries.compactMap(\.runtime).flatMap { rt in rt.commands.map { (rt, $0) } }
    }
}

extension DottieDocument {
    /// Regenerates the extension shapes whose size differs from `old`, so they reflow (a cylinder's lip keeps its
    /// height) instead of stretching. Shapes whose extension isn't in `runtimes` keep their path; so do ones whose
    /// extension fails, and those failures are returned. With `includingNew`, shapes that aren't in `old` at all are
    /// regenerated too (a script that adds a shape and then resizes it); without it they are left alone, so pasting
    /// a shape never reruns its extension.
    public mutating func reflowExtensionShapes(from old: DottieDocument, using runtimes: [ExtensionRuntime],
                                               includingNew: Bool = false) -> [String] {
        guard !runtimes.isEmpty, elements.contains(where: { $0.extension != nil }) else { return [] }
        let sizes = Dictionary(old.elements.map { ($0.id, CGSize(width: $0.width, height: $0.height)) },
                               uniquingKeysWith: { a, _ in a })
        var problems: [String] = []
        for i in elements.indices {
            let e = elements[i]
            guard let ref = e.extension, let rt = runtimes.first(where: { $0.manifest.id == ref.id }) else { continue }
            if let was = sizes[e.id] {
                guard was != CGSize(width: e.width, height: e.height) else { continue }
            } else if !includingNew { continue }
            do { try elements[i].regenerate(with: rt) }
            catch { problems.append("\(rt.manifest.name): \((error as? ExtensionError)?.description ?? "\(error)")") }
        }
        return problems
    }
}

extension Element {
    /// Replaces the path with a freshly generated one, keeping the frame and style.
    public mutating func apply(_ generated: GeneratedShape) {
        subpaths = generated.subpaths
        ports = generated.ports
        labelRect = generated.labelRect
    }

    /// Regenerates an extension shape from its stored parameters at its current frame. Returns false when the
    /// element isn't an extension shape. Throws when the extension fails; the element then keeps its last good path.
    @discardableResult
    public mutating func regenerate(with runtime: ExtensionRuntime) throws -> Bool {
        guard let ref = self.extension else { return false }
        let params = try runtime.migrated(ref)
        apply(try runtime.generate(shape: ref.shape, params: params, width: width, height: height))
        self.extension = ExtensionRef(id: ref.id, shape: ref.shape, version: runtime.manifest.version, params: params)
        return true
    }
}
