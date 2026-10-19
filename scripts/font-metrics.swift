// Measures the fonts Dottie sets text in with CoreText and writes web/src/metrics.ts: for Helvetica Neue and each
// bundled handwriting font (web/fonts, from scripts/update-fonts.py), advance widths and kerning pairs per 1000 em
// and line metrics of every face it has, and Menlo's. dottie.js measures text with these, so its label boxes and
// wrapping land where Dottie's CoreText layout puts them.  Run: swift scripts/font-metrics.swift
import Foundation
import CoreText
import CoreGraphics

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let chars = (32...126).map { String(UnicodeScalar($0)!) } + "•◦–—→←↑↓’‘“”…×·✓☐☑é".map { String($0) }
let faces = [("regular", false, false), ("bold", true, false), ("italic", false, true), ("boldItalic", true, true)]

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

/// A face's widths, kerning and line metrics.
func measure(_ f: CTFont) -> [String: Any] {
    var w: [String: Double] = [:], k: [String: Double] = [:]
    for c in chars { w[c] = r(width(c, f)) }
    for a in chars where a.utf16.count == 1 {
        for b in chars where b.utf16.count == 1 {
            let d = width(a + b, f) - width(a, f) - width(b, f)
            if abs(d) > 0.01 { k[a + b] = r(d) }
        }
    }
    return ["ascent": CTFontGetAscent(f) / 1000, "descent": CTFontGetDescent(f) / 1000, "leading": CTFontGetLeading(f) / 1000,
            "w": w, "k": k]
}

/// Characters `base` lacks are drawn from a fallback font, whose ascent, descent and leading then set the line's
/// height.
func fallback(_ base: CTFont) -> [String: [Double]] {
    var out: [String: [Double]] = [:]
    for c in chars {
        var u = Array(c.utf16), g = [CGGlyph](repeating: 0, count: u.count)
        guard !CTFontGetGlyphsForCharacters(base, &u, &g, u.count) else { continue }
        let f = CTFontCreateForString(base, c as CFString, CFRange(location: 0, length: u.count))
        out[c] = [CTFontGetAscent(f) / 1000, CTFontGetDescent(f) / 1000, CTFontGetLeading(f) / 1000]
    }
    return out
}

var families: [String: Any] = [:]
var helvetica: [String: Any] = [:]
for (key, bold, italic) in faces { helvetica[key] = measure(font("Helvetica Neue", bold: bold, italic: italic)) }
families["Helvetica Neue"] = ["faces": helvetica, "fallback": fallback(font("Helvetica Neue"))]

// The bundled fonts, loaded from their files as DottieKit loads them (Fonts.swift): only the faces they have.
var bundled: [String: [String: CTFont]] = [:]
let dir = root.appendingPathComponent("web/fonts")
for file in try! FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where file.hasSuffix(".woff2") {
    let data = try! Data(contentsOf: dir.appendingPathComponent(file)) as CFData
    let f = CTFontCreateWithFontDescriptor(CTFontManagerCreateFontDescriptorFromData(data)!, 1000, nil)
    let face = String(file.dropLast(".woff2".count).split(separator: "-").last!)
    bundled[CTFontCopyFamilyName(f) as String, default: [:]][face] = f
}
for (family, fs) in bundled {
    families[family] = ["faces": fs.mapValues(measure), "fallback": fallback(fs["regular"]!)]
}

let mono = font("Menlo")
let json = String(decoding: try! JSONSerialization.data(withJSONObject: families, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
var ts = """
// Advance widths and kerning (units per 1000 em) and line metrics of Helvetica Neue and the bundled handwriting
// fonts, measured with CoreText on macOS by scripts/font-metrics.swift. Dottie lays out text with CoreText;
// measuring with the same numbers puts dottie.js's label boxes and wrapping exactly where Dottie's are, whatever
// fonts the browser has. Characters not listed measure as "n". Generated: do not edit.

export type Face = "regular" | "bold" | "italic" | "boldItalic";
export interface FaceMetrics { ascent: number; descent: number; leading: number; w: Record<string, number>; k: Record<string, number> }
export interface FamilyMetrics {
  /** The faces the font has; text in a face it lacks is set in its regular face. */
  faces: { regular: FaceMetrics } & Partial<Record<Face, FaceMetrics>>;
  /** Ascent, descent and leading per em of the fallback font for characters the font lacks. */
  fallback: Record<string, [number, number, number]>;
}

export const monoAdvance = \(width("a", mono) / 1000), monoAscent = \(CTFontGetAscent(mono) / 1000), monoDescent = \(CTFontGetDescent(mono) / 1000);
export const families: Record<string, FamilyMetrics> = \(json);

"""
let out = root.appendingPathComponent("web/src/metrics.ts")
try! ts.write(to: out, atomically: true, encoding: .utf8)
print("wrote", out.path)
