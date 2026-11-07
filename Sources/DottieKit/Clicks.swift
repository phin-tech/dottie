import Foundation

/// What a click on an element does in the web players, worked out against its page.
public enum ClickTarget: Equatable, Sendable {
    /// Jump to scene `n` (an index into the page's markers) and play on to the next.
    case scene(Int)
    /// Open a link in a new tab.
    case url(String)
}

extension DottieDocument {
    /// The page's clickable elements and what each click does. A scene named by no marker on the page, or a link
    /// that isn't allowed, makes nothing clickable. An element with no `click` opens its `url` when that is a web link.
    public var clickTargets: [UUID: ClickTarget] {
        let markers = timeline?.markers ?? []
        var out: [UUID: ClickTarget] = [:]
        for e in elements {
            // A click that only changes variables is played by dottie.js (DottieDocument.usesState), not here.
            if let name = e.click?.scene, !name.isEmpty, let i = Self.scene(named: name, in: markers) {
                out[e.id] = .scene(i)
            } else if let url = e.click?.url.flatMap(ClickAction.allowed) ?? e.outsideLink?.webAddress {
                out[e.id] = .url(url)
            }
        }
        return out
    }

    /// The marker called `name`: an exact match, else one that differs only in case.
    static func scene(named name: String, in markers: [Marker]) -> Int? {
        markers.firstIndex { $0.name == name }
            ?? markers.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Renames the scene marker at `t`, and every click on the page that plays it, so they keep playing it.
    /// Refuses a blank name, or one another scene has in any case (clicks find scenes by name). Returns whether
    /// the scene is now called `name`.
    @discardableResult
    public mutating func renameScene(at t: Double, to name: String) -> Bool {
        guard var tl = timeline, let markers = tl.markers, let i = markers.firstIndex(where: { abs($0.t - t) < 1e-6 }) else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !markers.indices.contains(where: { $0 != i && markers[$0].name.caseInsensitiveCompare(name) == .orderedSame })
        else { return false }
        guard name != markers[i].name else { return true }
        for e in elements.indices {
            if let s = elements[e].click?.scene, Self.scene(named: s, in: markers) == i { elements[e].click?.scene = name }
        }
        tl.markers![i].name = name
        timeline = tl
        return true
    }

    /// The time of the scene `ref` names: its name (any case), or the time it is at as a number ("2.5").
    public func sceneTime(_ ref: String) -> Double? {
        let markers = timeline?.markers ?? []
        if let i = Self.scene(named: ref, in: markers) { return markers[i].t }
        guard let t = Double(ref.trimmingCharacters(in: .whitespaces)) else { return nil }
        return markers.first { abs($0.t - t) < 1e-6 }?.t
    }

    /// `self` with `ids` drawn as they look hovered.
    func hovered(_ ids: Set<UUID>) -> DottieDocument {
        var copy = self
        for i in copy.elements.indices where ids.contains(copy.elements[i].id) {
            if let look = copy.elements[i].hover { copy.elements[i] = look.apply(to: copy.elements[i]) }
        }
        return copy
    }
}

extension DiagramOps {
    /// Renames, moves, loops or removes the scene `scene` names (see `sceneTime`), for scripts and the MCP tool. A
    /// rename keeps the clicks that play it; removing it leaves them pointing nowhere, as the timeline's Delete Scene
    /// does. `loop` makes it a looping scene (`Marker.loop`) or not. Returns what it did, for a reply.
    @discardableResult
    public static func editScene(_ doc: inout DottieDocument, scene: String, rename: String? = nil, moveTo: Double? = nil,
                                 loop: Bool? = nil, remove: Bool = false) throws -> String {
        guard let t = doc.sceneTime(scene), let name = doc.timeline?.markers?.first(where: { $0.t == t })?.name else {
            let names = (doc.timeline?.markers ?? []).map { "'\($0.name)'" }
            throw OpsError.notFound("No scene '\(scene)'" + (names.isEmpty ? " (the page has none)" : "; scenes: \(names.joined(separator: ", "))"))
        }
        if remove {
            doc.timeline!.removeMarker(at: t)
            return "Removed scene '\(name)'"
        }
        guard rename != nil || moveTo != nil || loop != nil else {
            throw OpsError.invalid("Give a new name, a new time, loop, or remove")
        }
        var next = doc
        var done: [String] = []
        if let rename {
            guard next.renameScene(at: t, to: rename) else {
                throw OpsError.invalid("Can't call scene '\(name)' '\(rename)': a name must not be blank or another scene's")
            }
            done.append("renamed '\(name)' to '\(rename.trimmingCharacters(in: .whitespacesAndNewlines))'")
        }
        if let moveTo {
            guard moveTo.isFinite, moveTo >= 0 else { throw OpsError.invalid("A scene's time must be 0 or more seconds") }
            guard next.timeline!.moveMarker(from: t, to: moveTo) else {
                throw OpsError.invalid("There's another scene at \(moveTo)s already")
            }
            done.append("moved to \(moveTo)s")
        }
        if let loop {
            let at = moveTo.map(Timeline.clampTime) ?? t
            if let i = next.timeline!.markers?.firstIndex(where: { abs($0.t - at) < 1e-6 }) {
                next.timeline!.markers![i].loop = loop ? true : nil
            }
            done.append(loop ? "loops" : "stops")
        }
        doc = next
        return "Scene " + done.joined(separator: ", ")
    }

    /// A click from tool or script arguments: a scene name or a link, and variables to set and flip; nil for none of
    /// them ("" for a scene or link is none), which removes it.
    public static func click(scene: String?, url: String?, set: [String: Bool]? = nil, toggle: [String]? = nil) throws -> ClickAction? {
        for name in Array((set ?? [:]).keys) + (toggle ?? []) where !PageState.isName(name) {
            throw OpsError.invalid("A variable name is a letter or _, then letters, digits or _, got '\(name)'")
        }
        let set = (set ?? [:]).isEmpty ? nil : set, toggle = (toggle ?? []).isEmpty ? nil : toggle
        if let scene, !scene.isEmpty { return ClickAction(scene: scene, set: set, toggle: toggle) }
        if let url, !url.isEmpty {
            guard let ok = ClickAction.allowed(url) else {
                throw OpsError.invalid("A click link must start with http://, https:// or mailto:, got '\(url)'")
            }
            return ClickAction(url: ok, set: set, toggle: toggle)
        }
        return set == nil && toggle == nil ? nil : ClickAction(set: set, toggle: toggle)
    }

    /// Gives element `id` the condition `when` (see `PageState`); nil or "" removes it.
    public static func setWhen(_ doc: inout DottieDocument, id: UUID, _ when: String?) throws {
        guard let i = doc.elements.firstIndex(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
        doc.elements[i].when = try when.flatMap { try PageState.checked($0) }
    }

    /// `base` with the hover colors and opacity given; "" for a color (or a negative opacity) clears it.
    public static func hover(_ base: HoverLook?, stroke: String?, fill: String?, opacity: Double?) throws -> HoverLook? {
        var look = base ?? HoverLook()
        func color(_ s: String, _ name: String) throws -> RGBA? {
            if s.isEmpty { return nil }
            guard let c = RGBA(hex: s) else { throw OpsError.invalid("'\(name)' must be a hex color like #ffcc00, got '\(s)'") }
            return c
        }
        if let stroke { look.stroke = try color(stroke, "hover stroke") }
        if let fill { look.fill = try color(fill, "hover fill") }
        if let opacity { look.opacity = opacity < 0 || !opacity.isFinite ? nil : min(opacity, 1) }
        return look.isEmpty ? nil : look
    }
}

extension Element {
    /// What a screen reader calls the element when it is a button: the first line of its text, else its anchor,
    /// else, for a symbol's copy, the symbol's name (`symbolName`), else its kind.
    func buttonLabel(symbolName: String? = nil) -> String {
        if let t = text?.split(separator: "\n").first.map(String.init), !t.isEmpty { return t }
        if let a = anchor, !a.isEmpty { return a }
        if let n = symbolName, !n.isEmpty { return n }
        return kind.rawValue
    }
}

extension DottieDocument {
    /// For each of `instances` (copies of symbols on this page), the ids of every element it can expand to, mapped
    /// to it: how the web players gather a clickable copy's drawing into one button.
    func parts(of instances: Set<UUID>) -> [String: UUID] {
        var out: [String: UUID] = [:]
        for e in elements where instances.contains(e.id) && e.kind == .symbol {
            var alone = DottieDocument(id: id, layers: [Layer(id: e.layerID, name: "")], elements: [e])
            alone.symbols = symbols
            for part in alone.expandingSymbols(at: 0, posing: false).elements { out[part.id.uuidString] = e.id }
        }
        return out
    }

    /// The moment of each button state for the button copies among `ids`; empty when none is a button.
    func buttonTimes(_ state: Symbol.ButtonState, of ids: Set<UUID>) -> [UUID: Double] {
        let table = symbolIndex
        var out: [UUID: Double] = [:]
        for e in elements where ids.contains(e.id) {
            if let s = e.symbol.flatMap({ table[$0] }), s.isButton, let t = s.buttonTime(state) { out[e.id] = t }
        }
        return out
    }
}

extension String {
    /// Safe inside a double-quoted XML or HTML attribute.
    var attributeEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
