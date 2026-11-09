import Foundation

/// A page variable's value (ADR 0007): true or false, or a number.
public enum Var: Codable, Equatable, Hashable, Sendable, CustomStringConvertible,
                 ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    case bool(Bool)
    case number(Double)

    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        let n = try c.decode(Double.self)
        self = .number(n)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        }
    }

    /// As a condition reads it: a number holds unless it is 0 (or not a number).
    public var truthy: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        }
    }

    /// As arithmetic reads it: true is 1, false 0.
    public var number: Double {
        switch self {
        case .bool(let b): return b ? 1 : 0
        case .number(let n): return n
        }
    }

    public var isNumber: Bool { if case .number = self { true } else { false } }

    /// As JSON writes it, for scripts and tool results.
    public var json: Any {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n
        }
    }

    /// As an expression writes it, read back exactly: `true`, `3`, `0.25`.
    public var literal: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return "\(n)"
        }
    }

    public var description: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return DottieDocument.number(n, places: 2)
        }
    }
}

/// A condition or a computed value, parsed (ADR 0007): numbers and true/false, variable names, metrics
/// (`load(workers)`, or `load` for the element's own), parentheses, `!` and `-`, `* / %`, `+ -`, comparisons,
/// `&&` and `||`, and the functions `min`, `max`, `abs`, `floor`, `ceil`, `round` and `clamp`. web/src/expression.ts is
/// the same, operation for operation, so both players agree.
public indirect enum Expr: Equatable, Sendable {
    case literal(Var)
    case name(String)
    /// A metric of the element or flow named by `target` (an anchor or id); "" is the element's own.
    case metric(metric: String, target: String)
    case not(Expr)
    case negate(Expr)
    case binary(String, Expr, Expr)
    case call(String, [Expr])

    /// The functions an expression can call, and how many arguments each takes (nil: one or more).
    static let functions: [String: Int?] = ["min": nil, "max": nil, "abs": 1, "floor": 1, "ceil": 1, "round": 1, "clamp": 3]

    /// `text` parsed, or nil when it isn't an expression.
    public static func parse(_ text: String) -> Expr? {
        var p = ExprParser(Array(text.unicodeScalars))
        guard let e = p.or(), p.atEnd else { return nil }
        return e
    }

    /// The value with these variables (a missing one is false) and `metric` giving a metric's value (nil: not
    /// known, so every comparison with it fails).
    public func value(_ state: [String: Var], metric: ((PageState.MetricTerm) -> Double?)? = nil) -> Var {
        switch self {
        case .literal(let v): return v
        case .name(let n): return state[n] ?? .bool(false)
        case .metric(let m, let t):
            return .number(metric?(PageState.MetricTerm(metric: m, target: t, op: "", value: 0)) ?? .nan)
        case .not(let e): return .bool(!e.value(state, metric: metric).truthy)
        case .negate(let e): return .number(-e.value(state, metric: metric).number)
        case .call(let f, let args):
            let xs = args.map { $0.value(state, metric: metric).number }
            func fold(_ better: (Double, Double) -> Bool) -> Double {
                if xs.contains(where: \.isNaN) { return .nan }
                var out = xs[0]
                for x in xs.dropFirst() where better(x, out) { out = x }
                return out
            }
            switch f {
            case "min": return .number(fold(<))
            case "max": return .number(fold(>))
            case "abs": return .number(abs(xs[0]))
            case "floor": return .number(Foundation.floor(xs[0]))
            case "ceil": return .number(Foundation.ceil(xs[0]))
            case "round": return .number(Foundation.floor(xs[0] + 0.5))
            default: // clamp
                if xs.contains(where: \.isNaN) { return .number(.nan) }
                return .number(xs[0] < xs[1] ? xs[1] : xs[0] > xs[2] ? xs[2] : xs[0])
            }
        case .binary(let op, let l, let r):
            switch op {
            case "&&": return .bool(l.value(state, metric: metric).truthy && r.value(state, metric: metric).truthy)
            case "||": return .bool(l.value(state, metric: metric).truthy || r.value(state, metric: metric).truthy)
            default: break
            }
            let a = l.value(state, metric: metric), b = r.value(state, metric: metric)
            let x = a.number, y = b.number
            switch op {
            case "+": return .number(x + y)
            case "-": return .number(x - y)
            case "*": return .number(x * y)
            case "/": return .number(x / y)
            case "%": return .number(x.truncatingRemainder(dividingBy: y))
            default: break
            }
            // A comparison with something unknown fails, whichever way round.
            if x.isNaN || y.isNaN { return .bool(false) }
            switch op {
            case "<": return .bool(x < y)
            case "<=": return .bool(x <= y)
            case ">": return .bool(x > y)
            case ">=": return .bool(x >= y)
            case "==": if case .bool(let p) = a, case .bool(let q) = b { return .bool(p == q) }; return .bool(x == y)
            default: if case .bool(let p) = a, case .bool(let q) = b { return .bool(p != q) }; return .bool(x != y)
            }
        }
    }

    /// The variable names it reads, in order, each once.
    public var names: [String] {
        var out: [String] = []
        func walk(_ e: Expr) {
            switch e {
            case .name(let n): if !out.contains(n) { out.append(n) }
            case .not(let x), .negate(let x): walk(x)
            case .binary(_, let a, let b): walk(a); walk(b)
            case .call(_, let args): args.forEach(walk)
            case .literal, .metric: break
            }
        }
        walk(self)
        return out
    }

    /// The metrics it reads, as (metric, target).
    public var metrics: [(metric: String, target: String)] {
        var out: [(String, String)] = []
        func walk(_ e: Expr) {
            switch e {
            case .metric(let m, let t): out.append((m, t))
            case .not(let x), .negate(let x): walk(x)
            case .binary(_, let a, let b): walk(a); walk(b)
            case .call(_, let args): args.forEach(walk)
            case .literal, .name: break
            }
        }
        walk(self)
        return out
    }
}

/// Recursive descent over the grammar in `Expr`, loosest first.
private struct ExprParser {
    let s: [Unicode.Scalar]
    var i = 0
    init(_ s: [Unicode.Scalar]) { self.s = s }

    var atEnd: Bool { mutating get { skip(); return i == s.count } }

    mutating func skip() { while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r" { i += 1 } }

    mutating func eat(_ token: String) -> Bool {
        skip()
        let t = Array(token.unicodeScalars)
        guard i + t.count <= s.count, Array(s[i..<(i + t.count)]) == t else { return false }
        // `<` isn't `<=`, `!` isn't `!=`, `&&` and `||` are whole.
        if t.count == 1, i + 1 < s.count, s[i + 1] == "=", "<>!=".unicodeScalars.contains(t[0]) { return false }
        i += t.count
        return true
    }

    mutating func or() -> Expr? {
        guard var l = and() else { return nil }
        while eat("||") { guard let r = and() else { return nil }; l = .binary("||", l, r) }
        return l
    }

    mutating func and() -> Expr? {
        guard var l = compare() else { return nil }
        while eat("&&") { guard let r = compare() else { return nil }; l = .binary("&&", l, r) }
        return l
    }

    mutating func compare() -> Expr? {
        guard let l = sum() else { return nil }
        for op in ["<=", ">=", "==", "!=", "<", ">"] where eat(op) {
            guard let r = sum() else { return nil }
            return .binary(op, l, r)
        }
        return l
    }

    mutating func sum() -> Expr? {
        guard var l = product() else { return nil }
        while true {
            if eat("+") { guard let r = product() else { return nil }; l = .binary("+", l, r) }
            else if eat("-") { guard let r = product() else { return nil }; l = .binary("-", l, r) }
            else { return l }
        }
    }

    mutating func product() -> Expr? {
        guard var l = unary() else { return nil }
        while true {
            var op: String?
            for o in ["*", "/", "%"] where eat(o) { op = o; break }
            guard let op else { return l }
            guard let r = unary() else { return nil }
            l = .binary(op, l, r)
        }
    }

    mutating func unary() -> Expr? {
        if eat("!") { return unary().map(Expr.not) }
        if eat("-") { return unary().map(Expr.negate) }
        return primary()
    }

    mutating func primary() -> Expr? {
        skip()
        guard i < s.count else { return nil }
        if eat("(") {
            guard let e = or(), eat(")") else { return nil }
            return e
        }
        let c = s[i]
        if ("0"..."9").contains(c) {
            let start = i
            while i < s.count, ("0"..."9").contains(s[i]) { i += 1 }
            if i + 1 < s.count, s[i] == ".", ("0"..."9").contains(s[i + 1]) {
                i += 1
                while i < s.count, ("0"..."9").contains(s[i]) { i += 1 }
            }
            return Double(String(String.UnicodeScalarView(s[start..<i]))).map { .literal(.number($0)) }
        }
        guard c == "_" || ("a"..."z").contains(c) || ("A"..."Z").contains(c) else { return nil }
        let start = i
        while i < s.count, s[i] == "_" || ("a"..."z").contains(s[i]) || ("A"..."Z").contains(s[i]) || ("0"..."9").contains(s[i]) { i += 1 }
        let name = String(String.UnicodeScalarView(s[start..<i]))
        guard name.unicodeScalars.count <= PageState.maxName else { return nil }
        let called = { () -> Bool in var j = i; while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }; return j < s.count && s[j] == "(" }()
        if PageState.metricNames.contains(name) {
            guard called else { return .metric(metric: name, target: "") }
            _ = eat("(")
            // The target is everything up to the closing parenthesis: an anchor or an id.
            let from = i
            while i < s.count, s[i] != ")", s[i] != "(" { i += 1 }
            guard i < s.count, s[i] == ")" else { return nil }
            let target = String(String.UnicodeScalarView(s[from..<i])).trimmingCharacters(in: .whitespaces)
            i += 1
            return .metric(metric: name, target: target)
        }
        if let arity = Expr.functions[name] {
            guard called, eat("(") else { return nil }
            var args: [Expr] = []
            if !eat(")") {
                repeat { guard let a = or() else { return nil }; args.append(a) } while eat(",")
                guard eat(")") else { return nil }
            }
            if let n = arity { guard args.count == n else { return nil } } else { guard !args.isEmpty else { return nil } }
            return .call(name, args)
        }
        if called { return nil }
        if name == "true" { return .literal(.bool(true)) }
        if name == "false" { return .literal(.bool(false)) }
        return .name(name)
    }
}

/// What a click gives a variable (`ClickAction.set`, ADR 0007): a value, or an expression over the state before the
/// click, like `"count + 1"`.
public enum ClickValue: Codable, Equatable, Sendable, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                        ExpressibleByFloatLiteral, ExpressibleByStringLiteral {
    case value(Var)
    case expression(String)

    public init(booleanLiteral value: Bool) { self = .value(.bool(value)) }
    public init(integerLiteral value: Int) { self = .value(.number(Double(value))) }
    public init(floatLiteral value: Double) { self = .value(.number(value)) }
    public init(stringLiteral value: String) { self = .expression(value) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .expression(s); return }
        self = .value(try c.decode(Var.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .value(let v): try c.encode(v)
        case .expression(let s): try c.encode(s)
        }
    }

    /// Its value given the state before the click; an expression that can't be read leaves `current`.
    public func value(in state: [String: Var], current: Var?) -> Var {
        switch self {
        case .value(let v): return v
        case .expression(let s): return Expr.parse(s).map { $0.value(state) } ?? current ?? .bool(false)
        }
    }

    /// As JSON writes it.
    public var json: Any {
        switch self {
        case .value(let v): return v.json
        case .expression(let s): return s
        }
    }

    /// Whether this needs ADR 0007's version 3 to read: a number or an expression.
    var isNew: Bool { if case .value(.bool) = self { false } else { true } }
}

extension DottieScript {
    /// A JavaScript value (through JSON) as a click's value: true or false, a finite number, or an expression.
    static func clickValue(_ x: Any, _ what: String) throws -> ClickValue {
        if let n = x as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .value(.bool(n.boolValue)) }
            guard n.doubleValue.isFinite else { throw OpsError.invalid("'\(what)' must be a finite number") }
            return .value(.number(n.doubleValue))
        }
        if let s = x as? String { return .expression(try PageState.checkedValue(s)) }
        throw OpsError.invalid("'\(what)' must be true, false, a number or an expression like \"count + 1\"")
    }
}

extension PageState {
    /// `text` with each `{expression}` that reads only the page's variables replaced by its value (ADR 0007):
    /// "Clicked {count} times", "{count * 2} left". Braces holding anything else, or nothing a variable names, stay.
    public static func filling(_ text: String, _ values: [String: Var]) -> String {
        guard text.contains("{") else { return text }
        var out = "", rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let inner = String(rest[rest.index(after: open)..<close])
            if !inner.contains("{"), let e = Expr.parse(inner), e.metrics.isEmpty, !e.names.isEmpty,
               e.names.allSatisfy({ values[$0] != nil }) {
                out += e.value(values).description
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// Whether any element's text could show a variable's value.
    static func fills(_ elements: [Element]) -> Bool {
        elements.contains { $0.text?.contains("{") == true || $0.overrides?.contains { $0.text?.contains("{") == true } == true }
    }
}
