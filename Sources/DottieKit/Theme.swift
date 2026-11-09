import Foundation
import CoreGraphics

/// A named color in a theme's palette (ADR 0005): "accent", "muted", "danger" and so on.
public struct PaletteColor: Codable, Equatable, Sendable {
    public var name: String
    public var color: RGBA
    public init(name: String, color: RGBA) { self.name = name; self.color = color }
}

/// A page look: the canvas color, the color automatic ink takes on it, and a palette of named colors. Stored on a
/// drawing by id (a built-in) or whole (`CustomTheme`), so a file opens the same everywhere and exports match what
/// you drew on.
public struct Theme: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var background: RGBA
    /// What automatic ink (the default stroke) is drawn and exported as.
    public var ink: RGBA
    /// Colors elements can use by name (`Style.named`); editing one recolors everything that uses it.
    public var palette: [PaletteColor]

    public var isDark: Bool { background.luminance < 0.5 }

    /// The palette names every built-in theme has, in order.
    public static let paletteNames = ["accent", "muted", "danger", "warning", "success", "info"]

    private static func palette(_ hex: [String]) -> [PaletteColor] {
        zip(paletteNames, hex).map { PaletteColor(name: $0, color: RGBA(hex: $1)!) }
    }
    /// Light pages: strong colors that read on white and cream.
    static let lightPalette = palette(["#2563eb", "#6b7280", "#dc2626", "#d97706", "#16a34a", "#0891b2"])
    /// Dark pages: lighter versions, so they read on blue, green and black.
    static let darkPalette = palette(["#93c5fd", "#cbd5e1", "#fca5a5", "#fcd34d", "#86efac", "#67e8f9"])

    public static let paper = Theme(id: "paper", name: "Paper", background: RGBA(r: 0.984, g: 0.980, b: 0.965),
                                    ink: RGBA(r: 0.12, g: 0.12, b: 0.13), palette: lightPalette)
    public static let white = Theme(id: "white", name: "White", background: RGBA(r: 1, g: 1, b: 1), ink: .black, palette: lightPalette)
    public static let sepia = Theme(id: "sepia", name: "Sepia", background: RGBA(r: 0.953, g: 0.914, b: 0.824),
                                    ink: RGBA(r: 0.23, g: 0.18, b: 0.13),
                                    palette: palette(["#9a3412", "#78716c", "#b91c1c", "#b45309", "#4d7c0f", "#0e7490"]))
    public static let blueprint = Theme(id: "blueprint", name: "Blueprint", background: RGBA(r: 0.106, g: 0.227, b: 0.361),
                                        ink: RGBA(r: 0.91, g: 0.945, b: 0.984), palette: darkPalette)
    public static let chalkboard = Theme(id: "chalkboard", name: "Chalkboard", background: RGBA(r: 0.169, g: 0.227, b: 0.2),
                                         ink: RGBA(r: 0.945, g: 0.945, b: 0.918), palette: darkPalette)
    public static let midnight = Theme(id: "midnight", name: "Midnight", background: RGBA(r: 0.082, g: 0.086, b: 0.102),
                                       ink: RGBA(r: 0.925, g: 0.925, b: 0.94), palette: darkPalette)

    public static let all: [Theme] = [.paper, .white, .sepia, .blueprint, .chalkboard, .midnight]

    public static func named(_ id: String?) -> Theme? { all.first { $0.id == id } }
}

/// A theme made in the drawing: its own page color, ink and palette, started from a built-in (`base`) or not.
public struct CustomTheme: Codable, Equatable, Sendable {
    public var name: String
    public var background: RGBA
    public var ink: RGBA
    public var palette: [PaletteColor]
    /// The built-in it was made from, if any.
    public var base: String?
    public init(name: String, background: RGBA, ink: RGBA, palette: [PaletteColor], base: String? = nil) {
        self.name = name; self.background = background; self.ink = ink; self.palette = palette; self.base = base
    }
    /// A copy of `theme` to edit.
    public init(from theme: Theme, name: String? = nil) {
        self.init(name: name ?? theme.name, background: theme.background, ink: theme.ink, palette: theme.palette, base: theme.id)
    }
}

/// Which palette color each of an element's colors is (ADR 0005); nil fields are plain colors.
public struct ColorNames: Codable, Equatable, Sendable {
    public var fill: String?
    public var stroke: String?
    public var textColor: String?
    public init(fill: String? = nil, stroke: String? = nil, textColor: String? = nil) {
        self.fill = fill; self.stroke = stroke; self.textColor = textColor
    }
    public var isEmpty: Bool { fill == nil && stroke == nil && textColor == nil }
}

extension DottieDocument {
    /// The theme this page is drawn in: its custom theme, or the built-in it names, or nil to follow the system
    /// appearance.
    public var resolvedTheme: Theme? {
        if let c = customTheme {
            return Theme(id: "custom", name: c.name, background: c.background, ink: c.ink, palette: c.palette)
        }
        return Theme.named(theme)
    }

    /// The palette names resolve in: the theme's, or a light page's when there is no theme.
    public var palette: [PaletteColor] { resolvedTheme?.palette ?? Theme.lightPalette }

    /// The palette color `name` names, ignoring case.
    public func paletteColor(_ name: String) -> RGBA? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return palette.first { $0.name.lowercased() == n }?.color
    }

    /// The page with every named color (`Style.named`) set from its palette. A name the palette doesn't have keeps
    /// the color it had. Done when a drawing is read and whenever its theme or palette changes, so every renderer
    /// draws plain colors.
    public func resolvingPalette() -> DottieDocument {
        guard elements.contains(where: { $0.style.named != nil })
                || symbols?.contains(where: { $0.elements.contains { $0.style.named != nil } }) == true else { return self }
        var copy = self
        func resolve(_ e: inout Element) {
            guard let n = e.style.named else { return }
            if let f = n.fill, let c = paletteColor(f) { e.style.fill = c }
            if let s = n.stroke, let c = paletteColor(s) { e.style.stroke = c }
            if let t = n.textColor, let c = paletteColor(t) { e.style.textColor = c }
        }
        for i in copy.elements.indices { resolve(&copy.elements[i]) }
        if copy.symbols != nil {
            for s in copy.symbols!.indices { for i in copy.symbols![s].elements.indices { resolve(&copy.symbols![s].elements[i]) } }
        }
        return copy
    }

    /// This page after an edit from `old`: a color changed by hand stops being the palette color it was named
    /// after (so the next theme change leaves it alone), and if the theme or palette changed, named colors follow it.
    public func reconcilingColorNames(from old: DottieDocument?) -> DottieDocument {
        var copy = self
        if let old {
            let before = old.elementIndex
            for i in copy.elements.indices {
                guard var n = copy.elements[i].style.named, let was = before[copy.elements[i].id] else { continue }
                let now = copy.elements[i].style, then = was.style
                // A name given in this edit stays; one kept from before goes when its color was changed by hand.
                if then.named == n {
                    if let f = n.fill, now.fill != then.fill, now.fill != paletteColor(f) { n.fill = nil }
                    if let s = n.stroke, now.stroke != then.stroke, now.stroke != paletteColor(s) { n.stroke = nil }
                    if let t = n.textColor, now.textColor != then.textColor, now.textColor != paletteColor(t) { n.textColor = nil }
                }
                copy.elements[i].style.named = n.isEmpty ? nil : n
            }
        }
        return copy.resolvingPalette()
    }
}

extension DottieFile {
    /// Every page with its named colors set from its palette.
    public func resolvingPalette() -> DottieFile {
        var copy = self
        copy.pages = pages.map { $0.resolvingPalette() }
        return copy
    }

    /// `DottieDocument.reconcilingColorNames(from:)` for each page, against the page with its id in `old`.
    public func reconcilingColorNames(from old: DottieFile?) -> DottieFile {
        var copy = self
        copy.pages = pages.map { p in p.reconcilingColorNames(from: old?.pages.first { $0.id == p.id }) }
        return copy
    }
}

// MARK: Editing

extension RGBA {
    /// `s` as a color: hex (#rgb, #rrggbb, #rrggbbaa), or the name of a color in `doc`'s palette, which comes back
    /// too (as the palette spells it).
    public static func parse(_ s: String, in doc: DottieDocument?) -> (color: RGBA, name: String?)? {
        if let c = RGBA(hex: s) { return (c, nil) }
        let palette = doc?.palette ?? Theme.lightPalette
        let n = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard let p = palette.first(where: { $0.name.lowercased() == n }) else { return nil }
        return (p.color, p.name)
    }

    /// What a bad color argument is told: hex, or one of the palette's names.
    public static func expected(in doc: DottieDocument?) -> String {
        "a hex color like #ffcc00 or a palette color (" + (doc?.palette ?? Theme.lightPalette).map(\.name).joined(separator: ", ") + ")"
    }
}

extension DiagramOps {
    /// The page colors are named against while a tool or script runs (palette names in color arguments).
    public static var colorContext: DottieDocument? {
        get { ColorContext.shared.get() }
        set { ColorContext.shared.set(newValue) }
    }

    /// Sets the page's theme: a built-in by id (nil or "" for none, following the system), or a theme of its own.
    /// Named colors follow it.
    public static func setTheme(_ doc: inout DottieDocument, id: String?, custom: CustomTheme? = nil) throws {
        if let custom {
            doc.customTheme = custom
            doc.theme = custom.base
        } else {
            let id = id.flatMap { $0.isEmpty ? nil : $0 }
            if let id, Theme.named(id) == nil {
                throw OpsError.invalid("No theme '\(id)'; the built-ins are " + Theme.all.map(\.id).joined(separator: ", "))
            }
            doc.customTheme = nil
            doc.theme = id
        }
        doc = doc.resolvingPalette()
    }

    /// Sets (or adds) one palette color, making the page's theme its own first if it is a built-in. Everything
    /// named after it is recolored.
    public static func setPaletteColor(_ doc: inout DottieDocument, name: String, color: RGBA) throws {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, RGBA(hex: n) == nil else { throw OpsError.invalid("A palette color needs a name that isn't a hex color") }
        var custom = doc.customTheme ?? CustomTheme(from: doc.resolvedTheme ?? .white, name: (doc.resolvedTheme?.name ?? "White") + " (custom)")
        if let i = custom.palette.firstIndex(where: { $0.name.lowercased() == n.lowercased() }) { custom.palette[i].color = color }
        else { custom.palette.append(PaletteColor(name: n, color: color)) }
        doc.customTheme = custom
        doc = doc.resolvingPalette()
    }

    /// Records which of element `id`'s colors were given as palette names: `fill`, `stroke` and `textColor` are the
    /// arguments as given (a name, a hex color, "" or nil for not given). A name sets the color from the palette;
    /// a hex color or "" drops the name.
    public static func nameColors(_ doc: inout DottieDocument, id: UUID, fill: String?, stroke: String?, textColor: String?) throws {
        guard let i = doc.elements.firstIndex(where: { $0.id == id }) else { return }
        var n = doc.elements[i].style.named ?? ColorNames()
        func name(_ raw: String?, _ field: WritableKeyPath<ColorNames, String?>) throws {
            guard let raw else { return }
            if raw.isEmpty || RGBA(hex: raw) != nil { n[keyPath: field] = nil; return }
            guard let p = RGBA.parse(raw, in: doc), let named = p.name else {
                throw OpsError.invalid("'\(raw)' must be " + RGBA.expected(in: doc))
            }
            n[keyPath: field] = named
        }
        try name(fill, \.fill)
        try name(stroke, \.stroke)
        // Setting the stroke recolors a label that follows it, so its name goes too, unless one is given.
        if stroke != nil, textColor == nil, doc.elements[i].style.textColor == nil { n.textColor = nil }
        try name(textColor, \.textColor)
        doc.elements[i].style.named = n.isEmpty ? nil : n
        doc = doc.resolvingPalette()
    }
}

/// `DiagramOps.colorContext`, behind a lock.
final class ColorContext: @unchecked Sendable {
    static let shared = ColorContext()
    private let lock = NSLock()
    private var doc: DottieDocument?
    func get() -> DottieDocument? { lock.lock(); defer { lock.unlock() }; return doc }
    func set(_ d: DottieDocument?) { lock.lock(); doc = d; lock.unlock() }
}
