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
    /// that isn't allowed, makes nothing clickable.
    public var clickTargets: [UUID: ClickTarget] {
        let markers = timeline?.markers ?? []
        var out: [UUID: ClickTarget] = [:]
        for e in elements {
            guard let click = e.click else { continue }
            if let name = click.scene, !name.isEmpty, let i = Self.scene(named: name, in: markers) {
                out[e.id] = .scene(i)
            } else if let url = click.url.flatMap(ClickAction.allowed) {
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
    /// A click from tool or script arguments: a scene name or a link, "" for neither (which removes it).
    public static func click(scene: String?, url: String?) throws -> ClickAction? {
        if let scene, !scene.isEmpty { return ClickAction(scene: scene) }
        guard let url, !url.isEmpty else { return nil }
        guard let ok = ClickAction.allowed(url) else {
            throw OpsError.invalid("A click link must start with http://, https:// or mailto:, got '\(url)'")
        }
        return ClickAction(url: ok)
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
    /// else its kind.
    var buttonLabel: String {
        if let t = text?.split(separator: "\n").first.map(String.init), !t.isEmpty { return t }
        if let a = anchor, !a.isEmpty { return a }
        return kind.rawValue
    }
}

extension String {
    /// Safe inside a double-quoted XML or HTML attribute.
    var attributeEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
