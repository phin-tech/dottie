import Foundation

/// Page state: named true-or-false variables (`DottieDocument.variables`) that clicks flip (`ClickAction.set`,
/// `ClickAction.toggle`) and elements follow (`Element.when`), so a looping diagram can change without its timeline
/// stopping or jumping. Exports and the editor's playback show the variables' starting values; the web players
/// change them on click.
public enum PageState {
    /// Longest name a variable can have.
    static let maxName = 64

    /// Whether `name` can name a variable: a letter or underscore, then letters, digits and underscores.
    public static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= maxName else { return false }
        func letter(_ c: Unicode.Scalar) -> Bool { c == "_" || ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
        return letter(first) && name.unicodeScalars.allSatisfy { letter($0) || ("0"..."9").contains($0) }
    }

    /// The variable names `condition` reads, or nil when it isn't one: names, each optionally after `!`, joined
    /// by `&&` (both) and `||` (either; `&&` binds tighter), as in `down`, `!down`, `east && !west || maint`.
    public static func names(in condition: String) -> [String]? {
        var out: [String] = []
        for any in condition.components(separatedBy: "||") {
            for all in any.components(separatedBy: "&&") {
                var term = all.trimmingCharacters(in: .whitespaces)
                if term.hasPrefix("!") { term = String(term.dropFirst()).trimmingCharacters(in: .whitespaces) }
                guard isName(term) else { return nil }
                out.append(term)
            }
        }
        return out
    }

    /// Whether `condition` holds with these values. A variable missing from `state` is false; a condition that
    /// can't be read never holds, so a damaged file hides the element rather than showing every state at once.
    public static func holds(_ condition: String, in state: [String: Bool]) -> Bool {
        guard names(in: condition) != nil else { return false }
        return condition.components(separatedBy: "||").contains { any in
            any.components(separatedBy: "&&").allSatisfy { all in
                var term = all.trimmingCharacters(in: .whitespaces)
                var negated = false
                if term.hasPrefix("!") { negated = true; term = String(term.dropFirst()).trimmingCharacters(in: .whitespaces) }
                return (state[term] ?? false) != negated
            }
        }
    }

    /// `condition` checked for a tool or script: trimmed, nil for "" (no condition), or an error naming the problem.
    public static func checked(_ condition: String) throws -> String? {
        let c = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { return nil }
        guard names(in: c) != nil else {
            throw OpsError.invalid("'when' must be variable names, each optionally after !, joined by && or ||, "
                                   + "like \"down\" or \"east && !west\"; got '\(condition)'")
        }
        return c
    }
}

/// Which elements a page shows, as far as its variables go.
public enum StateChoice: Sendable, Equatable {
    /// The variables' starting values: what exports, previews and playback in the editor show.
    case initial
    /// These values; a variable missing from them takes its starting value.
    case values([String: Bool])
    /// Every element, whatever its `when`: what the editor shows while posing, so each state stays editable.
    case all
}

extension DottieDocument {
    /// Whether anything on the page reads or sets a variable, so its web export needs a player that keeps state.
    public var usesState: Bool {
        !(variables ?? [:]).isEmpty || (flows ?? []).contains { $0.when != nil } || elements.contains { $0.when != nil || $0.overrides != nil || $0.click?.changesState == true }
    }

    /// The values `choice` gives each variable; nil for `.all`.
    public func stateValues(_ choice: StateChoice) -> [String: Bool]? {
        switch choice {
        case .all: return nil
        case .initial: return variables ?? [:]
        case .values(let v): return (variables ?? [:]).merging(v) { _, new in new }
        }
    }

    /// The elements whose `when` doesn't hold under `choice`.
    func stateHidden(_ choice: StateChoice) -> Set<UUID> {
        guard let values = stateValues(choice) else { return [] }
        return Set(elements.compactMap { e in e.when.map { PageState.holds($0, in: values) ? nil : e.id } ?? nil })
    }

    /// Sets a variable's starting value (adding it), or with nil removes it. Returns an error for a bad name.
    public mutating func setVariable(_ name: String, to value: Bool?) throws {
        guard PageState.isName(name) else {
            throw OpsError.invalid("A variable name is a letter or _, then letters, digits or _ (at most \(PageState.maxName)), got '\(name)'")
        }
        var v = variables ?? [:]
        v[name] = value
        variables = v.isEmpty ? nil : v
    }
}

extension ClickAction {
    /// Whether the click sets or flips a variable.
    public var changesState: Bool { !(set ?? [:]).isEmpty || !(toggle ?? []).isEmpty }

    /// `state` after the click: its `set` values, then each `toggle` flipped (a missing variable starts false).
    public func applied(to state: [String: Bool]) -> [String: Bool] {
        var out = state
        for (k, v) in set ?? [:] { out[k] = v }
        for k in toggle ?? [] { out[k] = !(out[k] ?? false) }
        return out
    }
}

/// A change to an element while `when` holds: what an element looks like in one state of the page, so one element
/// can dim, recolor or relabel itself instead of a second copy standing in for it. Each field it leaves nil keeps
/// the element's own.
public struct StateOverride: Codable, Equatable, Sendable {
    /// The condition (`PageState`) under which this applies.
    public var when: String
    public var stroke, fill, textColor: RGBA?
    /// Multiplies the element's opacity (keyed fades still play), 0...1.
    public var opacity: Double?
    public var strokeWidth: Double?
    public var dash: DashStyle?
    /// Replaces the element's text or label.
    public var text: String?
    /// For an element that follows connectors (a packet): connector ids to the connectors it takes instead, so the
    /// same dot reroutes when a path goes down. Keys are uppercase UUID strings.
    public var reroute: [String: UUID]?
    /// Still drawn, but carries no traffic: flows (`Flow`) route round it, as round a region that is down.
    public var offline: Bool?
    /// For a connector: what flow traffic pays to take it meanwhile (`ConnectorData.cost`), so a degraded link loses
    /// traffic to a healthy one.
    public var cost: Double?

    public init(when: String, stroke: RGBA? = nil, fill: RGBA? = nil, textColor: RGBA? = nil, opacity: Double? = nil,
                strokeWidth: Double? = nil, dash: DashStyle? = nil, text: String? = nil, reroute: [UUID: UUID]? = nil,
                offline: Bool? = nil, cost: Double? = nil) {
        self.cost = cost
        self.when = when; self.stroke = stroke; self.fill = fill; self.textColor = textColor; self.opacity = opacity
        self.strokeWidth = strokeWidth; self.dash = dash; self.text = text; self.offline = offline == true ? true : nil
        self.reroute = reroute.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.uuidString, $0.value) }) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        when = try c.decodeIfPresent(String.self, forKey: .when) ?? ""
        stroke = try c.decodeIfPresent(RGBA.self, forKey: .stroke)
        fill = try c.decodeIfPresent(RGBA.self, forKey: .fill)
        textColor = try c.decodeIfPresent(RGBA.self, forKey: .textColor)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity).flatMap { $0.isFinite ? $0 : nil }
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth).flatMap { $0.isFinite ? $0 : nil }
        dash = try? c.decodeIfPresent(DashStyle.self, forKey: .dash)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        offline = ((try? c.decodeIfPresent(Bool.self, forKey: .offline)) ?? nil) == true ? true : nil
        cost = ((try? c.decodeIfPresent(Double.self, forKey: .cost)) ?? nil).flatMap { $0.isFinite ? $0 : nil }
        // Keys that aren't ids are dropped, and keys are matched without regard to case.
        let raw = (try? c.decodeIfPresent([String: UUID].self, forKey: .reroute)) ?? nil
        let ids = raw?.reduce(into: [String: UUID]()) { out, kv in
            if let k = UUID(uuidString: kv.key) { out[k.uuidString] = kv.value }
        }
        reroute = (ids?.isEmpty ?? true) ? nil : ids
    }

    /// One line for a listing: "down: opacity 0.3, text "east (down)", reroutes 1".
    public var summary: String {
        var parts: [String] = []
        func hex(_ c: RGBA) -> String { String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }
        if let c = stroke { parts.append("stroke \(hex(c))") }
        if let c = fill { parts.append("fill \(hex(c))") }
        if let c = textColor { parts.append("text color \(hex(c))") }
        if let v = opacity { parts.append("opacity \(v)") }
        if let v = strokeWidth { parts.append("width \(v)") }
        if let v = dash { parts.append(v.rawValue) }
        if let v = text { parts.append("text \"\(v)\"") }
        if let r = reroute { parts.append("reroutes \(r.count)") }
        if offline == true { parts.append("offline") }
        if let v = cost { parts.append("cost \(v)") }
        return when + ": " + (parts.isEmpty ? "no change" : parts.joined(separator: ", "))
    }

    /// The connector `path` is rerouted to, or `path`.
    func route(_ path: UUID) -> UUID { reroute?[path.uuidString] ?? path }

    /// `e` with this applied.
    func apply(to e: Element) -> Element {
        var e = e
        if let stroke { e.style.stroke = stroke }
        if let fill { e.style.fill = fill }
        if let textColor { e.style.textColor = textColor }
        if let strokeWidth { e.style.strokeWidth = max(0, strokeWidth) }
        if let dash { e.style.dash = dash }
        if let text { e.text = text }
        if let cost, cost.isFinite, e.connector != nil { e.connector?.cost = min(max(cost, 0), 1_000_000) }
        if let opacity {
            let o = min(max(opacity, 0), 1) * (e.style.opacity ?? 1)
            e.style.opacity = o >= 1 ? nil : o
        }
        return e
    }
}

extension Element {
    /// Points its overrides' reroutes at the copies in `ids` (old id to new), keeping ids that aren't in it.
    mutating func remapOverrides(_ ids: [UUID: UUID]) {
        overrides = overrides?.map { o in
            var o = o
            o.reroute = o.reroute.map { r in
                Dictionary(r.map { kv in (UUID(uuidString: kv.key).flatMap { ids[$0] }?.uuidString ?? kv.key, ids[kv.value] ?? kv.value) },
                           uniquingKeysWith: { a, _ in a })
            }
            return o
        }
    }

    /// The overrides whose condition holds under `values`, in order; none for nil (`.all`, the editor).
    func activeOverrides(_ values: [String: Bool]?) -> [StateOverride] {
        guard let values, let overrides else { return [] }
        return overrides.filter { PageState.holds($0.when, in: values) }
    }
}
