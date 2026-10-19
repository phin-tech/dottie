import CoreText
import Foundation

/// The typefaces text is set in. `Style.font` names one: nil is Helvetica Neue, a name in `bundled` is one of the
/// handwriting fonts Dottie carries (and embeds in what it exports), and any other name is a font installed on the
/// Mac, drawn when it is there and never embedded, so elsewhere it falls back to Helvetica Neue.
public enum Fonts {
    public static let defaultFamily = "Helvetica Neue"
    /// The bundled handwriting fonts, in the order menus list them.
    public static let bundled = ["Caveat", "Patrick Hand", "Architects Daughter"]
    /// What follows a font's name in SVG, so a viewer without it draws Helvetica Neue's stand-ins.
    static let cssFallback = "Helvetica Neue, Helvetica, Arial, sans-serif"

    public enum Face: String, CaseIterable, Sendable {
        case regular, bold, italic, boldItalic
        init(bold: Bool, italic: Bool) {
            self = bold ? (italic ? .boldItalic : .bold) : (italic ? .italic : .regular)
        }
    }

    /// The bundled family `name` refers to, matched without regard to case.
    public static func bundledFamily(_ name: String?) -> String? {
        guard let name else { return nil }
        return bundled.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The faces of the bundled fonts, loaded once from their embedded WOFF2 files.
    /// CoreText descriptors are immutable, so sharing them across threads is safe.
    nonisolated(unsafe) private static let descriptors: [String: [Face: CTFontDescriptor]] = {
        var out: [String: [Face: CTFontDescriptor]] = [:]
        for (family, faces) in BundledFonts.faces {
            for (key, base64) in faces {
                guard let face = Face(rawValue: key), let data = Data(base64Encoded: base64),
                      let d = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { continue }
                out[family, default: [:]][face] = d
            }
        }
        return out
    }()

    /// The faces `family` has: all four for an installed font (CoreText finds the nearest), only those
    /// bundled for a bundled one.
    public static func faces(of family: String) -> [Face] {
        guard let b = bundledFamily(family) else { return Face.allCases }
        return Face.allCases.filter { descriptors[b]?[$0] != nil }
    }

    /// `family` (nil for Helvetica Neue) at `size`. A bundled font without the face asked for uses its regular
    /// face, as CoreText does for an installed font; a font that isn't installed is Helvetica Neue.
    public static func font(_ family: String?, size: Double, bold: Bool = false, italic: Bool = false) -> CTFont {
        if let b = bundledFamily(family), let faces = descriptors[b] {
            let d = faces[Face(bold: bold, italic: italic)] ?? faces[.regular]!
            return CTFontCreateWithFontDescriptor(d, size, nil)
        }
        let name = family.flatMap { isInstalled($0) ? $0 : nil } ?? defaultFamily
        let base = CTFontCreateWithName(name as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    nonisolated(unsafe) private static var installed: [String: Bool] = [:]
    private static let lock = NSLock()

    /// Whether a font family (or a font's PostScript or full name) called `name` is on this Mac.
    public static func isInstalled(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let known = installed[name] { return known }
        let f = CTFontCreateWithName(name as CFString, 12, nil)
        let names = [CTFontCopyFamilyName(f), CTFontCopyPostScriptName(f), CTFontCopyFullName(f)] as [String]
        let found = names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        installed[name] = found
        return found
    }

    /// The families installed on this Mac, for picking a font of one's own.
    public static func installedFamilies() -> [String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The SVG `font-family` for text in `family`: its name, then the fallbacks.
    static func cssFamily(_ family: String?) -> String {
        guard let family, !family.isEmpty else { return cssFallback }
        // Quoted unless it is plain words; nothing that could end the quote, the attribute or the rule.
        let name = (bundledFamily(family) ?? family).filter { !"\"'<>&;{}\\".contains($0) }
        let quoted = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " } ? name : "'\(name)'"
        return name.isEmpty ? cssFallback : "\(quoted), \(cssFallback)"
    }

    /// The bundled families text on `doc`'s page (and in its symbols) is set in.
    public static func bundledFamilies(in doc: DottieDocument) -> [String] {
        var used = Set<String>()
        for e in doc.elements + (doc.symbols ?? []).flatMap(\.elements) {
            if let b = bundledFamily(e.style.font) { used.insert(b) }
        }
        return bundled.filter(used.contains)
    }

    /// `@font-face` rules embedding `families` (bundled ones; others are skipped) as data URLs.
    public static func fontFaceCSS(_ families: [String]) -> String {
        var css = ""
        for family in families {
            guard let b = bundledFamily(family), let faces = BundledFonts.faces[b] else { continue }
            for face in Face.allCases {
                guard let data = faces[face.rawValue] else { continue }
                let weight = face == .bold || face == .boldItalic ? "bold" : "normal"
                let style = face == .italic || face == .boldItalic ? "italic" : "normal"
                css += "@font-face{font-family:'\(b)';font-weight:\(weight);font-style:\(style);src:url(data:font/woff2;base64,\(data)) format('woff2');}"
            }
        }
        return css
    }
}
