import Foundation
import JavaScriptCore

/// Runs a page's click logic (ADR 0007) with dottie.js's engine (web/src/logic.ts, bundled as `PlayerScript.logic`):
/// QuickJS compiled to WebAssembly, in JavaScriptCore here and in the browser there, so a handler gives the same
/// answer in `simulate` as on the web. One context, used by one caller at a time, loaded the first time it's needed.
final class LogicEngine: @unchecked Sendable {
    static let shared = LogicEngine()

    /// What a handler did: new variable values, or why there are none.
    enum Outcome: Equatable { case set([String: Var]), failed(String) }

    private let lock = NSLock()
    private var context: JSContext?
    private var api: JSValue?

    private init() {}

    /// The engine, loaded (waiting up to a few seconds for its WebAssembly to compile); nil if it can't be.
    private func load() -> JSValue? {
        if let api, api.invokeMethod("ready", withArguments: [])?.toBool() == true { return api }
        guard let c = JSContext() else { return nil }
        c.evaluateScript(PlayerScript.logic)
        guard c.exception == nil, let a = c.objectForKeyedSubscript("DottieLogic"), !a.isUndefined else { return nil }
        a.invokeMethod("load", withArguments: [])
        let start = Date()
        while a.invokeMethod("ready", withArguments: [])?.toBool() != true {
            guard Date().timeIntervalSince(start) < 10 else { return nil }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        context = c; api = a
        return a
    }

    private struct Request: Encodable {
        var source: String, handler: String, state: [String: Var], event: Event
        struct Event: Encodable { var id: String; var anchor: String?; var text: String?; var time: Double; var scene: String? }
    }

    /// Why `source` can't be loaded (a syntax error, or code at its top that throws or never ends), or nil.
    func check(_ source: String) -> String? {
        let probe = Element(kind: .rectangle, frame: .zero, layerID: UUID())
        switch run(source, handler: "__dottieCheck__", state: [:], element: probe, time: 0, scene: nil) {
        case .failed(let why) where why.contains("No handler called __dottieCheck__"): return nil
        case .failed(let why): return why
        case .set: return nil
        }
    }

    /// The handlers `source` defines at its top: `function name(` and `const name = (` / `=> `.
    static func handlers(in source: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"(?m)^\s*(?:function\s+([A-Za-z_][A-Za-z0-9_]*)|(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:function|\())"#)
        let ns = source as NSString
        return re.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for g in 1...2 where m.range(at: g).location != NSNotFound { return ns.substring(with: m.range(at: g)) }
            return nil
        }
    }

    /// Runs `handler` from `source` for a click on `element` at `time` during `scene`.
    func run(_ source: String, handler: String, state: [String: Var], element: Element, time: Double, scene: String?) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        guard let api = load() else { return .failed("The logic engine couldn't start") }
        let event = Request.Event(id: element.id.uuidString, anchor: element.anchor,
                                  text: element.text?.components(separatedBy: "\n").first, time: time, scene: scene)
        guard let data = try? JSONEncoder().encode(Request(source: source, handler: handler, state: state, event: event)),
              let out = api.invokeMethod("run", withArguments: [String(decoding: data, as: UTF8.self)])?.toString(),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else {
            return .failed("The logic engine gave no answer")
        }
        guard json["ok"] as? Bool == true else { return .failed(json["error"] as? String ?? "The handler failed") }
        var set: [String: Var] = [:]
        for (k, v) in json["set"] as? [String: Any] ?? [:] {
            if let n = v as? NSNumber { set[k] = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue) }
        }
        return .set(set)
    }
}

extension DottieDocument {
    /// `state` after clicking `element` (ADR 0007): with `logic` allowed and a handler to `run`, the starting values
    /// back first if it resets, then the handler's values; a handler that fails leaves the state as it was. Otherwise
    /// the click's own `set` and `toggle`. Also says what went wrong, if a handler did.
    public func clicked(_ element: Element, state: [String: Var], time: Double = 0, scene: String? = nil,
                        allowLogic: Bool = true) -> (state: [String: Var], problem: String?) {
        guard let c = element.click else { return (state, nil) }
        guard allowLogic, let handler = c.run, let source = logic, !source.isEmpty else {
            return (c.applied(to: state, initial: variables ?? [:]), nil)
        }
        var start = state
        if c.reset == true { start = state.mapValues { _ in .bool(false) }.merging(variables ?? [:]) { _, s in s } }
        switch LogicEngine.shared.run(source, handler: handler, state: start, element: element, time: time, scene: scene) {
        case .set(let values): return (start.merging(values) { _, new in new }, nil)
        case .failed(let why): return (state, why)
        }
    }
}
