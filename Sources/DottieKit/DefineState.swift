import Foundation

/// One variable described all at once: what changes while it is true and which buttons change it. `defineState`
/// writes the `when` conditions, overrides and clicks this means, element by element.
public struct StateSpec: Equatable, Sendable {
    /// The variable (`PageState.isName`).
    public var name: String
    /// Its starting value.
    public var initial = false
    /// Drawn only while it is false (a region that goes down), connectors attached to them with them.
    public var hide: [UUID] = []
    /// Drawn only while it is true (a warning, a standby that takes over).
    public var show: [UUID] = []
    /// Faded to `dimOpacity` while it is true, still drawn.
    public var dim: [UUID] = []
    /// Down while it is true: dimmed like `dim`, and carrying no traffic, so flows go round them.
    public var down: [UUID] = []
    public var dimOpacity = 0.3
    /// Other changes while it is true, per element. The override's own `when` is ignored.
    public var restyle: [UUID: StateOverride] = [:]
    /// Connector to connector: everything that follows the first follows the second while it is true, so packets
    /// keep flowing along a detour.
    public var reroute: [UUID: UUID] = [:]
    /// Clicking these flips it, turns it on, turns it off (on the web; see `ClickAction`).
    public var toggledBy: [UUID] = []
    public var turnedOnBy: [UUID] = []
    public var turnedOffBy: [UUID] = []

    public init(name: String) { self.name = name }
}

extension DiagramOps {
    /// Writes `spec` into the page: the variable and its starting value; `!name` and `name` joined onto the
    /// conditions of what it hides and shows; an override for `name` on what it dims, restyles and reroutes (merged
    /// into one already there); and the clicks. Running it again with the same spec changes nothing more. Returns a
    /// one-line summary.
    @discardableResult
    public static func defineState(_ doc: inout DottieDocument, _ spec: StateSpec) throws -> String {
        let name = spec.name
        try doc.setVariable(name, to: spec.initial)
        let ids = Set(doc.elements.map(\.id))
        func check(_ list: [UUID], _ what: String) throws {
            if let bad = list.first(where: { !ids.contains($0) }) { throw OpsError.notFound("No element \(bad.uuidString) to \(what)") }
        }
        try check(spec.hide, "hide"); try check(spec.show, "show"); try check(spec.dim, "dim"); try check(spec.down, "take down")
        try check(Array(spec.restyle.keys), "restyle")
        try check(Array(spec.reroute.keys) + Array(spec.reroute.values), "reroute")
        try check(spec.toggledBy + spec.turnedOnBy + spec.turnedOffBy, "click")
        if let both = Set(spec.hide).intersection(spec.show).first {
            throw OpsError.invalid("\(both.uuidString) can't be both hidden and shown by \(name)")
        }
        let kinds = Dictionary(doc.elements.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        for (from, to) in spec.reroute where kinds[to] != .connector || kinds[from] != .connector {
            throw OpsError.invalid("reroute goes from a connector to a connector")
        }

        func edit(_ id: UUID, _ change: (inout Element) -> Void) {
            if let i = doc.elements.firstIndex(where: { $0.id == id }) { change(&doc.elements[i]) }
        }
        for id in spec.hide { edit(id) { $0.when = PageState.joining($0.when, "!" + name) } }
        for id in spec.show { edit(id) { $0.when = PageState.joining($0.when, name) } }

        func override(_ id: UUID, _ change: (inout StateOverride) -> Void) {
            edit(id) { e in
                var list = e.overrides ?? []
                let k = list.firstIndex { $0.when == name } ?? { list.append(StateOverride(when: name)); return list.count - 1 }()
                change(&list[k])
                e.overrides = list
            }
        }
        let fade = min(max(spec.dimOpacity.isFinite ? spec.dimOpacity : 0.3, 0), 1)
        for id in spec.dim { override(id) { $0.opacity = fade } }
        for id in spec.down { override(id) { $0.opacity = fade; $0.offline = true } }
        for (id, look) in spec.restyle {
            override(id) { o in
                if let v = look.stroke { o.stroke = v }
                if let v = look.fill { o.fill = v }
                if let v = look.textColor { o.textColor = v }
                if let v = look.opacity { o.opacity = v }
                if let v = look.strokeWidth { o.strokeWidth = v }
                if let v = look.dash { o.dash = v }
                if let v = look.text { o.text = v }
            }
        }
        // Everything with a follow along a rerouted connector: packets, mostly.
        var rerouted = 0
        if !spec.reroute.isEmpty, let tracks = doc.timeline?.tracks {
            for track in tracks {
                let paths = Set(track.follow?.map(\.path) ?? [])
                let mine = spec.reroute.filter { paths.contains($0.key) }
                guard !mine.isEmpty else { continue }
                rerouted += 1
                override(track.element) { o in
                    var r = o.reroute ?? [:]
                    for (from, to) in mine { r[from.uuidString] = to }
                    o.reroute = r
                }
            }
        }

        func click(_ id: UUID, _ change: (inout ClickAction) -> Void) {
            edit(id) { e in
                var c = e.click ?? ClickAction()
                change(&c)
                e.click = c.isEmpty ? nil : c
            }
        }
        for id in spec.toggledBy {
            click(id) { c in
                c.set?[name] = nil
                if c.set?.isEmpty == true { c.set = nil }
                if !(c.toggle ?? []).contains(name) { c.toggle = (c.toggle ?? []) + [name] }
            }
        }
        for (list, value) in [(spec.turnedOnBy, true), (spec.turnedOffBy, false)] {
            for id in list {
                click(id) { c in
                    c.toggle?.removeAll { $0 == name }
                    if c.toggle?.isEmpty == true { c.toggle = nil }
                    c.set = (c.set ?? [:]).merging([name: value]) { _, new in new }
                }
            }
        }

        var parts: [String] = []
        func count(_ n: Int, _ verb: String) { if n > 0 { parts.append("\(verb) \(n)") } }
        count(spec.hide.count, "hides"); count(spec.show.count, "shows"); count(spec.dim.count, "dims")
        count(spec.down.count, "takes down")
        count(spec.restyle.count, "restyles"); count(rerouted, "reroutes")
        let buttons = spec.toggledBy.count + spec.turnedOnBy.count + spec.turnedOffBy.count
        if buttons > 0 { parts.append("changed by \(buttons) click\(buttons == 1 ? "" : "s")") }
        if !spec.reroute.isEmpty && rerouted == 0 { parts.append("nothing follows the rerouted connectors yet") }
        return "\(name) (starts \(spec.initial))" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", "))
    }
}

extension PageState {
    /// `condition && term`, kept a valid condition: `term` joins every `||` branch, since conditions have no
    /// parentheses. A branch that already has it is left alone.
    static func joining(_ condition: String?, _ term: String) -> String {
        guard let c = condition?.trimmingCharacters(in: .whitespaces), !c.isEmpty, names(in: c) != nil else { return term }
        return c.components(separatedBy: "||").map { any -> String in
            let terms = any.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "") }
            let branch = terms.joined(separator: " && ")
            return terms.contains(term) ? branch : branch + " && " + term
        }.joined(separator: " || ")
    }
}
