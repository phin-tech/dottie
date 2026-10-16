// Measures Helvetica Neue (and Menlo) with CoreText and writes web/src/metrics.ts: advance widths and kerning
// pairs per 1000 em, and line metrics. dottie.js measures label text with these, so its label boxes and
// wrapping land where Dottie's CoreText layout puts them.  Run: swift scripts/font-metrics.swift
import Foundation
import CoreText
import CoreGraphics

let chars = (32...126).map { String(UnicodeScalar($0)!) } + "•◦–—→←↑↓’‘“”…×·✓☐☑é".map { String($0) }
func font(_ name: String, bold: Bool = false, italic: Bool = false) -> CTFont {
    let f = CTFontCreateWithName(name as CFString, 1000, nil)
    var t: CTFontSymbolicTraits = []
    if bold { t.insert(.traitBold) }
    if italic { t.insert(.traitItalic) }
    return t.isEmpty ? f : CTFontCreateCopyWithSymbolicTraits(f, 1000, nil, t, t) ?? f
}
func width(_ s: String, _ f: CTFont) -> Double {
    let str = CFAttributedStringCreate(nil, s as CFString, [kCTFontAttributeName: f] as CFDictionary)!
    return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(str), nil, nil, nil)
}
func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
var fonts: [String: Any] = [:]
for (key, bold, italic) in [("regular", false, false), ("bold", true, false), ("italic", false, true), ("boldItalic", true, true)] {
    let f = font("Helvetica Neue", bold: bold, italic: italic)
    var w: [String: Double] = [:], k: [String: Double] = [:]
    for c in chars { w[c] = r(width(c, f)) }
    for a in chars where a.utf16.count == 1 {
        for b in chars where b.utf16.count == 1 {
            let d = width(a + b, f) - width(a, f) - width(b, f)
            if abs(d) > 0.01 { k[a + b] = r(d) }
        }
    }
    fonts[key] = ["w": w, "k": k]
}
// Characters Helvetica Neue lacks are drawn from a fallback font, whose ascent, descent and leading then set
// the line's height.
var fallback: [String: [Double]] = [:]
let base = font("Helvetica Neue")
for c in chars {
    var u = Array(c.utf16), g = [CGGlyph](repeating: 0, count: u.count)
    guard !CTFontGetGlyphsForCharacters(base, &u, &g, u.count) else { continue }
    let f = CTFontCreateForString(base, c as CFString, CFRange(location: 0, length: u.count))
    fallback[c] = [CTFontGetAscent(f) / 1000, CTFontGetDescent(f) / 1000, CTFontGetLeading(f) / 1000]
}
let regular = font("Helvetica Neue"), bold = font("Helvetica Neue", bold: true), mono = font("Menlo")
let italic = font("Helvetica Neue", italic: true), boldItalic = font("Helvetica Neue", bold: true, italic: true)
let json = String(decoding: try! JSONSerialization.data(withJSONObject: fonts, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
var ts = """
// Helvetica Neue advance widths and kerning (units per 1000 em), and line metrics, measured with CoreText on
// macOS by scripts/font-metrics.swift. Dottie lays out labels with CoreText; measuring with the same numbers
// puts dottie.js's label boxes and wrapping exactly where Dottie's are, whatever fonts the browser has.
// Characters not listed measure as "n". Generated: do not edit.

"""
ts += "export const ascent = \(CTFontGetAscent(regular) / 1000), descent = \(CTFontGetDescent(regular) / 1000), leading = \(CTFontGetLeading(regular) / 1000);\n"
ts += "export const boldAscent = \(CTFontGetAscent(bold) / 1000), boldDescent = \(CTFontGetDescent(bold) / 1000), boldLeading = \(CTFontGetLeading(bold) / 1000);\n"
ts += "export const italicAscent = \(CTFontGetAscent(italic) / 1000), italicDescent = \(CTFontGetDescent(italic) / 1000), italicLeading = \(CTFontGetLeading(italic) / 1000);\n"
ts += "export const boldItalicAscent = \(CTFontGetAscent(boldItalic) / 1000), boldItalicDescent = \(CTFontGetDescent(boldItalic) / 1000), boldItalicLeading = \(CTFontGetLeading(boldItalic) / 1000);\n"
ts += "export const monoAdvance = \(width("a", mono) / 1000), monoAscent = \(CTFontGetAscent(mono) / 1000), monoDescent = \(CTFontGetDescent(mono) / 1000);\n"
ts += "export const fonts: Record<\"regular\" | \"bold\" | \"italic\" | \"boldItalic\", { w: Record<string, number>; k: Record<string, number> }> = \(json);\n"
let fb = String(decoding: try! JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys]), as: UTF8.self)
ts += "/** Ascent, descent and leading per em of the fallback font for characters Helvetica Neue lacks. */\n"
ts += "export const fallbackMetrics: Record<string, [number, number, number]> = \(fb);\n"
let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("web/src/metrics.ts")
try! ts.write(to: out, atomically: true, encoding: .utf8)
print("wrote", out.path)
