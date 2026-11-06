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
        !(variables ?? [:]).isEmpty || elements.contains { $0.when != nil || $0.click?.changesState == true }
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
