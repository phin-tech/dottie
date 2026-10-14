import Foundation
import CoreGraphics
import CoreText

/// A sticky note: a filled card whose text is Markdown, laid out top-left with CoreText.
/// The renderer and SVG export both lay out through `layout(_:in:fontSize:color:)`, so they wrap identically.
///
/// Supported: `#` to `######` headings, paragraphs, `-` / `*` / `+` and `1.` lists (nested by indent),
/// `- [ ]` / `- [x]` tasks, `>` quotes, fenced code, `---` rules, and inline bold, italic, `code`,
/// ~~strikethrough~~ and links. Text that does not fit is cut off at the note's edge.
public enum Note {
    /// Inset from the note's edge to its text, on every side.
    public static let padding: Double = 12
    /// Canary yellow; light enough that the ink stays dark on a dark canvas (see `Element.resolvingInk`).
    public static let defaultFill = RGBA(r: 1, g: 0.91, b: 0.52)

    /// `base` adjusted for a new note: the default fill if it has none, a thin outline and a smaller font.
    public static func style(from base: Style) -> Style {
        var s = base
        if s.fill.a == 0 { s.fill = defaultFill }
        s.fillStyle = .solid
        s.strokeWidth = 1
        s.dash = .solid
        s.fontSize = 16
        return s
    }

    /// Where the text goes inside a note's frame.
    public static func textRect(_ frame: CGRect) -> CGRect {
        frame.insetBy(dx: min(padding, frame.width / 2), dy: min(padding, frame.height / 2))
    }

    /// Offset of the soft shadow drawn under a filled note.
    static let shadowOffset = CGSize(width: 2, height: 3)

    // MARK: Blocks

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// `marker` is what is drawn before the item: a bullet, `3.`, or a checkbox.
        case item(depth: Int, marker: String, text: String)
        case quote(String)
        case code(String)
        case rule
    }

    /// Splits Markdown into blocks, one line-based pass. Consecutive plain lines join into one paragraph.
    static func blocks(_ source: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var fence: [String]?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var f = fence {
                if trimmed.hasPrefix("```") { out.append(.code(f.joined(separator: "\n"))); fence = nil }
                else { f.append(line); fence = f }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); fence = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if let h = heading(trimmed) { flush(); out.append(h); continue }
            if isRule(trimmed) { flush(); out.append(.rule); continue }
            if trimmed.hasPrefix(">") {
                flush()
                out.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let i = item(line) { flush(); out.append(i); continue }
            para.append(trimmed)
        }
        flush()
        if let f = fence { out.append(.code(f.joined(separator: "\n"))) } // unclosed fence runs to the end
        return out
    }

    private static func heading(_ s: String) -> Block? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ s: String) -> Bool {
        let chars = s.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func item(_ line: String) -> Block? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let s = line.drop { $0 == " " || $0 == "\t" }
        let depth = indent / 2
        var marker: String
        var rest: Substring
        if let c = s.first, "-*+".contains(c), s.dropFirst().first == " " {
            marker = depth % 2 == 0 ? "•" : "◦"
            rest = s.dropFirst(2)
        } else {
            let digits = s.prefix { $0.isNumber }
            let after = s.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 9, let p = after.first, p == "." || p == ")",
                  after.dropFirst().first == " " else { return nil }
            marker = "\(digits)."
            rest = after.dropFirst(2)
        }
        if rest.hasPrefix("[ ] ") || rest == "[ ]" { marker = "☐"; rest = rest.dropFirst(4) }
        else if rest.lowercased().hasPrefix("[x] ") || rest.lowercased() == "[x]" { marker = "☑"; rest = rest.dropFirst(4) }
        return .item(depth: depth, marker: marker, text: rest.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Attributed text

    /// Marks a run to be struck through; CoreText has no strikethrough of its own.
    static let strikeAttribute = NSAttributedString.Key("DottieStrike")
    /// Marks the placeholder of a `---` rule, drawn as a line across the note.
    static let ruleAttribute = NSAttributedString.Key("DottieRule")
    /// Marks quoted text, which gets a bar down its left side.
    static let quoteAttribute = NSAttributedString.Key("DottieQuote")
    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    private static let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
    private static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)

    static func font(_ size: Double, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> CTFont {
        let base = CTFontCreateWithName((mono ? "Menlo" : "Helvetica Neue") as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    private static func paragraphStyle(spacingBefore: Double, firstIndent: Double = 0, indent: Double = 0,
                                       tab: Double? = nil) -> CTParagraphStyle {
        var before = CGFloat(spacingBefore), first = CGFloat(firstIndent), head = CGFloat(indent)
        let hasTabs = tab != nil
        var tabs = tab.map { [CTTextTabCreate(.left, $0, nil)] as CFArray }
        return withUnsafeBytes(of: &before) { b in
            withUnsafeBytes(of: &first) { f in
                withUnsafeBytes(of: &head) { h in
                    withUnsafeBytes(of: &tabs) { t in
                        var settings = [
                            CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: MemoryLayout<CGFloat>.size, value: b.baseAddress!),
                            CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: f.baseAddress!),
                            CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: h.baseAddress!),
                        ]
                        if hasTabs {
                            settings.append(CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: t.baseAddress!))
                        }
                        return CTParagraphStyleCreate(settings, settings.count)
                    }
                }
            }
        }
    }

    /// Inline Markdown (`**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, links) styled on top of `size`.
    private static func inline(_ s: String, size: Double, bold: Bool = false, italic: Bool = false,
                               color: CGColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: s, options: options) else {
            out.append(NSAttributedString(string: s, attributes: [fontKey: font(size, bold: bold, italic: italic), colorKey: color]))
            return out
        }
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let mono = intent.contains(.code)
            var attrs: [NSAttributedString.Key: Any] = [
                fontKey: font(mono ? size * 0.9 : size, bold: bold || intent.contains(.stronglyEmphasized),
                              italic: italic || intent.contains(.emphasized), mono: mono),
                colorKey: color,
            ]
            if intent.contains(.strikethrough) { attrs[strikeAttribute] = true }
            if run.link != nil { attrs[underlineKey] = CTUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    /// The whole note as one attributed string, a paragraph per block.
    static func attributed(_ source: String, fontSize: Double, color: CGColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let gap = fontSize * 0.5
        let faded = color.copy(alpha: color.alpha * 0.7) ?? color
        let all = blocks(source)
        var previous: CTParagraphStyle?
        for (n, block) in all.enumerated() {
            let before = n == 0 ? 0 : gap
            var piece: NSMutableAttributedString
            var para: CTParagraphStyle
            switch block {
            case .heading(let level, let text):
                let scale = [1.5, 1.3, 1.15, 1.05, 1, 1][level - 1]
                piece = inline(text, size: fontSize * scale, bold: true, color: color)
                para = paragraphStyle(spacingBefore: n == 0 ? 0 : gap * 1.4)
            case .paragraph(let text):
                piece = inline(text, size: fontSize, color: color)
                para = paragraphStyle(spacingBefore: before)
            case .item(let depth, let marker, let text):
                // A list continues without a gap; the marker sits in a hanging indent.
                let continues: Bool = {
                    guard n > 0, case .item = all[n - 1] else { return false }
                    return true
                }()
                let start = Double(depth) * fontSize * 1.2
                let hang = start + fontSize * (marker.count > 2 ? 0.6 * Double(marker.count) + 0.4 : 1.2)
                piece = NSMutableAttributedString(string: marker + "\t", attributes: [fontKey: font(fontSize), colorKey: color])
                piece.append(inline(text, size: fontSize, color: color))
                para = paragraphStyle(spacingBefore: continues ? fontSize * 0.15 : before, firstIndent: start, indent: hang, tab: hang)
            case .quote(let text):
                piece = inline(text, size: fontSize, italic: true, color: faded)
                piece.addAttribute(quoteAttribute, value: true, range: NSRange(location: 0, length: piece.length))
                para = paragraphStyle(spacingBefore: before, firstIndent: fontSize, indent: fontSize)
            case .code(let text):
                piece = NSMutableAttributedString(string: text.isEmpty ? " " : text,
                                                  attributes: [fontKey: font(fontSize * 0.85, mono: true), colorKey: color])
                para = paragraphStyle(spacingBefore: before, firstIndent: fontSize * 0.5, indent: fontSize * 0.5)
            case .rule:
                piece = NSMutableAttributedString(string: " ", attributes: [fontKey: font(fontSize * 0.6), colorKey: color,
                                                                           ruleAttribute: true])
                para = paragraphStyle(spacingBefore: before)
            }
            // The newline that joins two blocks ends, and so belongs to, the earlier paragraph.
            if let previous {
                out.append(NSAttributedString(string: "\n", attributes: [fontKey: font(fontSize), colorKey: color, paragraphKey: previous]))
            }
            piece.addAttribute(paragraphKey, value: para, range: NSRange(location: 0, length: piece.length))
            out.append(piece)
            previous = para
        }
        return out
    }

    // MARK: Layout

    /// The laid-out text, in a CoreText frame whose path is `rect` (y-up), with the string it lays out.
    /// Use `lines(of:in:)` for top-left positions.
    static func layout(_ source: String, in rect: CGRect, fontSize: Double, color: CGColor) -> (text: NSAttributedString, frame: CTFrame) {
        // Parsing and typesetting cost far more than drawing, and a redraw (every drag event) repeats them
        // for every note on screen; everything the layout depends on is in the key.
        let key = LayoutKey(source: source, fontSize: fontSize, color: color.components ?? [], rect: rect)
        return cache.layout(key) {
            let text = attributed(source, fontSize: fontSize, color: color)
            let setter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
            return (text, CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil))
        }
    }

    struct LayoutKey: Hashable {
        var source: String
        var fontSize: Double
        var color: [CGFloat]
        var x, y, w, h: Double
        init(source: String, fontSize: Double, color: [CGFloat], rect: CGRect) {
            self.source = source; self.fontSize = fontSize; self.color = color
            x = rect.minX; y = rect.minY; w = rect.width; h = rect.height
        }
    }

    final class LayoutCache: @unchecked Sendable {
        private let lock = NSLock()
        private var layouts: [LayoutKey: (NSAttributedString, CTFrame)] = [:]
        private let limit = 500

        func layout(_ k: LayoutKey, _ make: () -> (NSAttributedString, CTFrame)) -> (text: NSAttributedString, frame: CTFrame) {
            lock.lock()
            if let l = layouts[k] { lock.unlock(); return l }
            lock.unlock()
            let l = make()
            lock.lock(); defer { lock.unlock() }
            if layouts.count >= limit { layouts.removeAll(keepingCapacity: true) }
            layouts[k] = l
            return l
        }
    }

    static let cache = LayoutCache()

    /// One laid-out line: its baseline origin in top-left (y-down) coordinates.
    struct Line {
        var line: CTLine
        var origin: CGPoint
    }

    /// The frame's lines with origins converted to the top-left space that `rect` is given in.
    static func lines(of frame: CTFrame, in rect: CGRect) -> [Line] {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        // CoreText's origins are relative to the path's box, y-up; the box flipped about its middle is itself.
        return zip(lines, origins).map { Line(line: $0, origin: CGPoint(x: rect.minX + $1.x, y: rect.maxY - $1.y)) }
    }

    /// Strikethroughs, rules and quote bars as line segments in top-left coordinates, drawn after the text.
    static func decorations(_ lines: [Line], in rect: CGRect) -> [(CGPoint, CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        for l in lines {
            for run in CTLineGetGlyphRuns(l.line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                if attrs[quoteAttribute] != nil, run == (CTLineGetGlyphRuns(l.line) as! [CTRun]).first {
                    var ascent: CGFloat = 0, descent: CGFloat = 0
                    _ = CTLineGetTypographicBounds(l.line, &ascent, &descent, nil)
                    let x = rect.minX + 3
                    out.append((CGPoint(x: x, y: l.origin.y - ascent), CGPoint(x: x, y: l.origin.y + descent)))
                }
                if attrs[ruleAttribute] != nil {
                    out.append((CGPoint(x: rect.minX, y: l.origin.y - 3), CGPoint(x: rect.maxX, y: l.origin.y - 3)))
                } else if attrs[strikeAttribute] != nil {
                    let range = CTRunGetStringRange(run)
                    var start: CGFloat = 0, end: CGFloat = 0
                    start = CTLineGetOffsetForStringIndex(l.line, range.location, nil)
                    end = CTLineGetOffsetForStringIndex(l.line, range.location + range.length, nil)
                    var ascent: CGFloat = 0
                    _ = CTRunGetTypographicBounds(run, CFRange(), &ascent, nil, nil)
                    let y = l.origin.y - ascent * 0.32
                    out.append((CGPoint(x: l.origin.x + start, y: y), CGPoint(x: l.origin.x + end, y: y)))
                }
            }
        }
        return out
    }

    /// Draws a note's text into `rect` of a top-left-origin context, clipped to it.
    static func draw(_ source: String, in rect: CGRect, fontSize: Double, color: CGColor, ctx: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        let f = layout(source, in: rect, fontSize: fontSize, color: color).frame
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        CTFrameDraw(f, ctx)
        ctx.restoreGState()
        let marks = decorations(lines(of: f, in: rect), in: rect)
        if !marks.isEmpty {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(max(1, fontSize / 14))
            ctx.setLineDash(phase: 0, lengths: [])
            for (a, b) in marks { ctx.move(to: a); ctx.addLine(to: b) }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
