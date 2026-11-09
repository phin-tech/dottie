import Foundation

extension DottieDocument {
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
            guard let c = RGBA.parse(s, in: DiagramOps.colorContext)?.color else {
                throw OpsError.invalid("'\(name)' must be \(RGBA.expected(in: DiagramOps.colorContext)), got '\(s)'")
            }
            return c
        }
        if let stroke { look.stroke = try color(stroke, "hover stroke") }
        if let fill { look.fill = try color(fill, "hover fill") }
        if let opacity { look.opacity = opacity < 0 || !opacity.isFinite ? nil : min(opacity, 1) }
        return look.isEmpty ? nil : look
    }
}
