import Foundation
import CoreGraphics

/// Controls (ADR 0003, "What sits on top"): buttons, choices, a reset button and a flow legend. Each is authoring
/// sugar: it writes ordinary shapes, clicks, variables and overrides, so every renderer plays it with nothing new.
public struct ButtonSpec: Equatable, Sendable {
    public var text: String
    public var x = 0.0, y = 0.0
    public var width: Double?, height: Double?
    /// The variable a click flips; its pressed look shows while the variable is true.
    public var toggles: String?
    /// Variables a click sets; its pressed look shows while they all have these values.
    public var sets: [String: ClickValue] = [:]
    /// The label while pressed.
    public var onText: String?
    /// The button's color: its outline and label, and its fill while pressed. Nil is blue.
    public var color: RGBA?

    public init(text: String) { self.text = text }
}

extension DiagramOps {
    public static let controlColor = RGBA(r: 0.18, g: 0.44, b: 0.87)

    /// A clean pill-shaped button whose click toggles or sets variables (added, starting false, if missing), with a
    /// pressed look (filled, and `onText` if given) while it is on. Returns the button.
    @discardableResult
    public static func addButton(_ doc: inout DottieDocument, _ spec: ButtonSpec) throws -> Element {
        guard spec.toggles != nil || !spec.sets.isEmpty else {
            throw OpsError.invalid("A button toggles a variable or sets some (toggles, sets)")
        }
        for name in [spec.toggles].compactMap({ $0 }) + spec.sets.keys.sorted() where doc.variables?[name] == nil {
            try doc.setVariable(name, to: false)
        }
        let color = spec.color ?? controlColor
        let fontSize = 16.0
        let label = [spec.text, spec.onText ?? ""].max { $0.count < $1.count } ?? spec.text
        let natural = defaultSize(for: .rectangle, text: label, fontSize: fontSize)
        let frame = CGRect(x: spec.x, y: spec.y, width: spec.width ?? max(natural.width, 100), height: spec.height ?? 40)
        var look = Look(strokeWidth: 2, fontSize: fontSize)
        look.textColor = .some(color)
        var e = try addShape(&doc, kind: .rectangle, frame: frame, at: frame.origin, text: spec.text,
                             fill: RGBA(r: 1, g: 1, b: 1), stroke: color, roughness: 0, look: look)
        var click = ClickAction()
        if let t = spec.toggles { click.toggle = [t] }
        if !spec.sets.isEmpty { click.set = spec.sets }
        let on: String
        if let t = spec.toggles {
            on = t
        } else {
            // Pressed while what it sets holds: a flag as set, a number equal; a computed value has no pressed look.
            on = spec.sets.keys.sorted().reduce(nil as String?) { c, k in
                switch spec.sets[k]! {
                case .value(.bool(let b)): return PageState.joining(c, b ? k : "!" + k)
                case .value(.number(let n)): return PageState.joining(c, "\(k) == \(Var.number(n).literal)")
                case .expression: return c
                }
            } ?? ""
        }
        var pressed = StateOverride(when: on, fill: color, textColor: RGBA(r: 1, g: 1, b: 1))
        pressed.text = spec.onText
        e.click = click
        e.overrides = [pressed]
        replace(&doc, e)
        return e
    }

    /// One button per option, side by side (`row`) or stacked: exactly one option is on at a time. Each option is a
    /// variable (`<name>_<option>`, cleaned into a variable name), clicking one sets it true and the others false;
    /// `initial` (or the first) starts true. Returns the buttons and the variables, in option order.
    @discardableResult
    public static func addChoice(_ doc: inout DottieDocument, name: String, options: [String], x: Double, y: Double,
                                 row: Bool = true, initial: String? = nil, color: RGBA? = nil) throws -> [(button: Element, variable: String)] {
        guard !options.isEmpty else { throw OpsError.invalid("A choice needs at least one option") }
        if let initial, !options.contains(initial) { throw OpsError.invalid("'\(initial)' isn't one of the options") }
        var names: [String] = []
        for option in options {
            let n = variableName(name + "_" + option)
            guard !names.contains(n) else { throw OpsError.invalid("Two options make the same variable, \(n)") }
            names.append(n)
        }
        let start = options.firstIndex(of: initial ?? options[0]) ?? 0
        for (i, n) in names.enumerated() { try doc.setVariable(n, to: .bool(i == start)) }
        let fontSize = 16.0
        let width = options.map { max(defaultSize(for: .rectangle, text: $0, fontSize: fontSize).width, 100) }.max() ?? 100
        var out: [(Element, String)] = []
        for (i, option) in options.enumerated() {
            var spec = ButtonSpec(text: option)
            spec.x = row ? x + Double(i) * (width + 10) : x
            spec.y = row ? y : y + Double(i) * 50
            spec.width = width
            spec.color = color
            spec.sets = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, ClickValue.value(.bool($0.offset == i))) })
            var b = try addButton(&doc, spec)
            // Pressed while its own option is on; the others being off is implied.
            b.overrides = b.overrides?.map { o in var o = o; o.when = names[i]; return o }
            replace(&doc, b)
            out.append((b, names[i]))
        }
        return out
    }

    /// A button that sets every variable on the page back to its starting value. Variables added later aren't
    /// covered: run it again with `replacing` (the button) to bring it up to date. Returns the button.
    @discardableResult
    public static func addReset(_ doc: inout DottieDocument, x: Double, y: Double, text: String = "Reset",
                                replacing: UUID? = nil, color: RGBA? = nil) throws -> Element {
        guard let vars = doc.variables, !vars.isEmpty, vars.count > 0 else { throw OpsError.invalid("The page has no variables to reset") }
        if let replacing {
            guard let i = doc.elements.firstIndex(where: { $0.id == replacing }) else { throw OpsError.notFound("No element \(replacing.uuidString)") }
            var c = doc.elements[i].click ?? ClickAction()
            c.set = nil; c.toggle = nil; c.reset = true
            doc.elements[i].click = c
            return doc.elements[i]
        }
        let color = color ?? RGBA(r: 0.35, g: 0.35, b: 0.35)
        let fontSize = 16.0
        let natural = defaultSize(for: .rectangle, text: text, fontSize: fontSize)
        let frame = CGRect(x: x, y: y, width: max(natural.width, 100), height: 40)
        var look = Look(dash: .dashed, strokeWidth: 2, fontSize: fontSize)
        look.textColor = .some(color)
        var e = try addShape(&doc, kind: .rectangle, frame: frame, at: frame.origin, text: text,
                             fill: RGBA(r: 1, g: 1, b: 1), stroke: color, roughness: 0, look: look)
        e.click = ClickAction(reset: true)
        replace(&doc, e)
        return e
    }

    /// One row per flow: a swatch in its color and a label (`labels[flow id]`, else "from → to"). Clicking either
    /// flips a variable (`show_<n>`, starting true) joined onto that flow's `when`, so the flow can be hidden; both
    /// fade while it is off. Running it again reuses the variables. Returns each row's swatch and label.
    @discardableResult
    public static func addLegend(_ doc: inout DottieDocument, x: Double, y: Double,
                                 labels: [UUID: String] = [:]) throws -> [(swatch: Element, label: Element)] {
        guard let flows = doc.flows, !flows.isEmpty else { throw OpsError.invalid("The page has no flows for a legend") }
        let names = Dictionary(doc.elements.map { ($0.id, $0.text ?? "?") }, uniquingKeysWith: { a, _ in a })
        var out: [(Element, Element)] = []
        for (i, flow) in flows.enumerated() {
            let v = "show_\(i + 1)"
            if doc.variables?[v] == nil { try doc.setVariable(v, to: true) }
            doc.flows![i].when = PageState.joining(flow.when, v)
            let color = flow.color ?? Flow.defaultColor
            let rowY = y + Double(i) * 30
            var swatch = try addShape(&doc, kind: .ellipse, frame: CGRect(x: x, y: rowY + 2, width: 16, height: 16),
                                      at: CGPoint(x: x, y: rowY), text: nil, fill: color, stroke: color, roughness: 0)
            let text = labels[flow.id] ?? ((names[flow.from] ?? "?") + " → " + flow.to.map { names[$0] ?? "?" }.joined(separator: " / "))
            let labelLook = Look(fontSize: 15)
            let size = defaultSize(for: .text, text: text, fontSize: 15)
            var label = try addShape(&doc, kind: .text, frame: CGRect(x: x + 24, y: rowY, width: size.width, height: 20),
                                     at: CGPoint(x: x + 24, y: rowY), text: text, fill: nil,
                                     stroke: RGBA(r: 0.2, g: 0.2, b: 0.2), roughness: 0, look: labelLook)
            let off = StateOverride(when: "!" + v, opacity: 0.3)
            for j in [0, 1] {
                var e = j == 0 ? swatch : label
                e.click = ClickAction(toggle: [v])
                e.overrides = [off]
                replace(&doc, e)
                if j == 0 { swatch = e } else { label = e }
            }
            out.append((swatch, label))
        }
        return out
    }

    /// `text` made into a variable name: letters, digits and _, not starting with a digit, at most 64 characters.
    static func variableName(_ text: String) -> String {
        var s = String(text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" })
        if s.first.map({ $0.isNumber }) ?? true { s = "_" + s }
        return String(s.prefix(PageState.maxName))
    }

    private static func replace(_ doc: inout DottieDocument, _ e: Element) {
        if let i = doc.elements.firstIndex(where: { $0.id == e.id }) { doc.elements[i] = e }
    }
}

// MARK: Layout helpers

extension DiagramOps {
    /// Where a control goes when the caller gives no position: right after `after` (12 points on, its top
    /// aligned), or, with nothing to follow, above the top left of the page's content.
    public static func controlOrigin(_ doc: DottieDocument, after: UUID?) throws -> CGPoint {
        if let after {
            guard let e = doc.elements.first(where: { $0.id == after }) else { throw OpsError.notFound("No element \(after.uuidString) to follow") }
            return CGPoint(x: e.frame.maxX + 12, y: e.frame.minY)
        }
        let shapes = doc.elements.filter { $0.kind != .connector }
        guard let first = shapes.first else { return CGPoint(x: 0, y: 0) }
        let box = shapes.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        return CGPoint(x: box.minX, y: box.minY - 60)
    }

    /// A frame of `size` beside `target` on `side` (right, left, above, below), 16 points off, moved along that
    /// side until it overlaps no gauge already there. A flow's gauge goes beside the flow's source.
    public static func gaugeFrame(_ doc: DottieDocument, near target: UUID, side: String, size: CGSize) throws -> CGRect {
        let id = doc.elements.contains { $0.id == target } ? target : (doc.flows ?? []).first { $0.id == target }?.from
        guard let id, let t = doc.elements.first(where: { $0.id == id }) else { throw OpsError.notFound("No element or flow \(target.uuidString)") }
        let f = t.kind == .connector ? Connector.bounds(of: t, in: doc) : t.frame
        let gap = 16.0
        var r: CGRect
        switch side {
        case "left": r = CGRect(x: f.minX - gap - size.width, y: f.midY - size.height / 2, width: size.width, height: size.height)
        case "above": r = CGRect(x: f.midX - size.width / 2, y: f.minY - gap - size.height, width: size.width, height: size.height)
        case "below": r = CGRect(x: f.midX - size.width / 2, y: f.maxY + gap, width: size.width, height: size.height)
        case "right": r = CGRect(x: f.maxX + gap, y: f.midY - size.height / 2, width: size.width, height: size.height)
        default: throw OpsError.invalid("'near' is right, left, above or below, got '\(side)'")
        }
        let taken = doc.elements.filter { $0.gauge != nil }.map(\.frame)
        for _ in 0..<12 where taken.contains(where: { $0.intersects(r) }) {
            if side == "left" || side == "right" { r.origin.y += size.height + 8 } else { r.origin.x += size.width + 8 }
        }
        return r
    }

    /// A labelled frame behind `ids`, `padding` points round them: a region, an account, a VPC. Returns the frame
    /// and its label.
    @discardableResult
    public static func addGroup(_ doc: inout DottieDocument, ids: [UUID], label: String, padding: Double = 24,
                                color: RGBA = RGBA(r: 0.6, g: 0.65, b: 0.72)) throws -> (frame: Element, label: Element) {
        let members = doc.elements.filter { ids.contains($0.id) }
        guard let first = members.first, members.count == Set(ids).count else { throw OpsError.notFound("Every id must name an element on the page") }
        let box = members.dropFirst().reduce(first.kind == .connector ? Connector.bounds(of: first, in: doc) : first.frame) {
            $0.union($1.kind == .connector ? Connector.bounds(of: $1, in: doc) : $1.frame)
        }.insetBy(dx: -padding, dy: -padding)
        let top = box.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: -22)
        let layer = first.layerID
        var s = Style()
        s.roughness = 0; s.stroke = color; s.dash = .dashed; s.strokeWidth = 1.5
        s.fill = RGBA(r: color.r, g: color.g, b: color.b, a: 0.08); s.fillStyle = .solid
        let frame = Element(kind: .rectangle, frame: CGRect(x: top.minX, y: top.minY, width: top.width, height: top.height + 22),
                            style: s, layerID: layer)
        var ls = Style()
        ls.roughness = 0; ls.stroke = color; ls.fontSize = 15
        let text = Element(kind: .text, frame: CGRect(x: top.minX + 10, y: top.minY + 4, width: max(80, min(top.width - 20, 260)), height: 20),
                           style: ls, layerID: layer, text: label)
        // Behind the first member, so the members stay on top.
        let at = doc.elements.firstIndex { ids.contains($0.id) } ?? 0
        doc.elements.insert(contentsOf: [frame, text], at: at)
        return (frame, text)
    }
}
