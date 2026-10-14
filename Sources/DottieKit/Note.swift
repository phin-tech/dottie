import Foundation
import CoreGraphics
import CoreText
import Markdown

/// A sticky note: a filled card whose text is GitHub Flavored Markdown, laid out top-left with CoreText.
/// The renderer and SVG export both lay out through `layout(_:in:fontSize:color:)`, so they wrap identically.
///
/// Parsed by swift-markdown (cmark-gfm): headings, paragraphs, nested bullet, numbered and task lists,
/// quotes, fenced and indented code, rules, tables, and inline bold, italic, `code`, ~~strikethrough~~,
/// links and bare URLs. A single newline is a line break, as in GitHub comments. Text that does not fit is
/// cut off at the note's edge.
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

    /// Note colors offered as swatches, the default first. All light, so the ink stays dark on them.
    public static let colors: [(name: String, fill: RGBA)] = [
        ("Yellow", defaultFill),
        ("Orange", RGBA(r: 1, g: 0.8, b: 0.55)),
        ("Pink", RGBA(r: 1, g: 0.78, b: 0.85)),
        ("Purple", RGBA(r: 0.85, g: 0.8, b: 1)),
        ("Blue", RGBA(r: 0.73, g: 0.88, b: 1)),
        ("Green", RGBA(r: 0.78, g: 0.95, b: 0.7)),
    ]

    /// Offset of the soft shadow drawn under a filled note.
    static let shadowOffset = CGSize(width: 2, height: 3)

    // MARK: Attributes

    /// Marks a run to be struck through; CoreText has no strikethrough of its own.
    static let strikeAttribute = NSAttributedString.Key("DottieStrike")
    /// Marks the placeholder of a `---` rule, drawn as a line across the note from the value's x offset.
    static let ruleAttribute = NSAttributedString.Key("DottieRule")
    /// Marks quoted text, which gets a bar down its left side at the value's x offset.
    static let quoteAttribute = NSAttributedString.Key("DottieQuote")
    /// Marks a table's header row, ruled underneath from x offset `value[0]`, `value[1]` wide.
    static let tableRuleAttribute = NSAttributedString.Key("DottieTableRule")
    /// Marks a task item's checkbox; the value is the 1-based source line of its `[ ]` or `[x]`.
    static let checkboxAttribute = NSAttributedString.Key("DottieCheckbox")
    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    private static let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
    private static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
    /// Breaks a line without ending the paragraph, so spacing and list indents carry on.
    static let lineSeparator = "\u{2028}"

    static func font(_ size: Double, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> CTFont {
        let base = CTFontCreateWithName((mono ? "Menlo" : "Helvetica Neue") as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    private static func paragraphStyle(spacingBefore: Double, firstIndent: Double = 0, indent: Double = 0,
                                       tabs: [(CTTextAlignment, Double)] = []) -> CTParagraphStyle {
        var before = CGFloat(spacingBefore), first = CGFloat(firstIndent), head = CGFloat(indent)
        let hasTabs = !tabs.isEmpty
        var stops = tabs.map { CTTextTabCreate($0.0, $0.1, nil) } as CFArray
        return withUnsafeBytes(of: &before) { b in
            withUnsafeBytes(of: &first) { f in
                withUnsafeBytes(of: &head) { h in
                    withUnsafeBytes(of: &stops) { t in
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

    static func width(of s: NSAttributedString) -> Double {
        Double(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(s as CFAttributedString), nil, nil, nil))
    }

    // MARK: Markdown to attributed text

    /// How inline text is styled where it appears.
    private struct Inline {
        var size: Double
        var bold = false, italic = false, mono = false, strike = false, link = false
        var color: CGColor
    }

    /// Where a block sits: its indent, and the list marker its first paragraph carries.
    private struct Context {
        var indent: Double = 0
        var marker: (text: String, start: Double, hang: Double, line: Int?)?
        var quote: Double?
        var listDepth = 0
    }

    /// Builds the note as one attributed string, a CoreText paragraph per block.
    private struct Builder {
        let fontSize: Double
        let color: CGColor
        let faded: CGColor
        let width: Double
        var out = NSMutableAttributedString()
        var previous: CTParagraphStyle?
        /// Spacing before the next paragraph, when a list item asks for tight spacing.
        var nextSpacing: Double?

        var gap: Double { fontSize * 0.5 }

        mutating func paragraph(_ content: NSMutableAttributedString, _ style: CTParagraphStyle, quote: Double?) {
            if let quote { content.addAttribute(quoteAttribute, value: quote, range: NSRange(location: 0, length: content.length)) }
            // The newline that joins two blocks ends, and so belongs to, the earlier paragraph.
            if let previous {
                out.append(NSAttributedString(string: "\n", attributes: [fontKey: font(fontSize), colorKey: color, paragraphKey: previous]))
            }
            content.addAttribute(paragraphKey, value: style, range: NSRange(location: 0, length: content.length))
            out.append(content)
            previous = style
            nextSpacing = nil
        }

        func spacing(_ normal: Double) -> Double { out.length == 0 ? 0 : nextSpacing ?? normal }

        mutating func block(_ node: Markup, _ ctx: Context) {
            var ctx = ctx
            let base = Inline(size: fontSize, italic: ctx.quote != nil, color: ctx.quote != nil ? faded : color)
            switch node {
            case let h as Heading:
                let scale = [1.5, 1.3, 1.15, 1.05, 1, 1][min(max(h.level, 1), 6) - 1]
                var style = base; style.size *= scale; style.bold = true
                text(inline(h, style), ctx, spacing: spacing(gap * 1.4))
            case let p as Paragraph:
                text(inline(p, base), ctx, spacing: spacing(gap))
            case let list as ListItemContainer:
                let items = Array(list.listItems)
                let ordered = (list as? OrderedList).map { Int($0.startIndex) }
                let markers = items.enumerated().map { i, item -> String in
                    switch item.checkbox {
                    case .checked?: return "☑"
                    case .unchecked?: return "☐"
                    case nil: return ordered.map { "\($0 + i)." } ?? (ctx.listDepth % 2 == 0 ? "•" : "◦")
                    }
                }
                let widest = markers.map { Note.width(of: NSAttributedString(string: $0, attributes: [fontKey: font(fontSize)])) }.max() ?? 0
                let hang = ctx.indent + max(widest + fontSize * 0.45, fontSize * 1.2)
                for (i, item) in items.enumerated() {
                    if i > 0 || ctx.listDepth > 0 || ctx.marker != nil { nextSpacing = fontSize * 0.15 }
                    var inner = ctx
                    inner.marker = (markers[i], ctx.indent, hang, item.checkbox == nil ? nil : item.range?.lowerBound.line)
                    inner.indent = hang
                    inner.listDepth += 1
                    let children = Array(item.children)
                    if children.isEmpty { text(NSMutableAttributedString(), inner, spacing: spacing(gap)) }
                    for child in children {
                        block(child, inner)
                        inner.marker = nil
                        // Blocks after the first in an item follow it closely.
                        nextSpacing = fontSize * 0.3
                    }
                    nextSpacing = nil
                }
            case let q as BlockQuote:
                ctx.quote = ctx.indent + 3
                ctx.indent += fontSize
                for child in q.children { block(child, ctx) }
            case let code as CodeBlock:
                let body = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
                let s = NSMutableAttributedString(string: body.isEmpty ? " " : body.replacingOccurrences(of: "\n", with: lineSeparator),
                                                  attributes: [fontKey: font(fontSize * 0.85, mono: true), colorKey: base.color])
                ctx.indent += fontSize * 0.5
                text(s, ctx, spacing: spacing(gap))
            case is ThematicBreak:
                let s = NSMutableAttributedString(string: " ", attributes: [fontKey: font(fontSize * 0.6), colorKey: color,
                                                                           ruleAttribute: ctx.indent])
                text(s, ctx, spacing: spacing(gap))
            case let table as Table:
                self.table(table, ctx)
            case let html as HTMLBlock:
                let raw = html.rawHTML.trimmingCharacters(in: .newlines).replacingOccurrences(of: "\n", with: lineSeparator)
                text(NSMutableAttributedString(string: raw, attributes: [fontKey: font(fontSize), colorKey: base.color]), ctx, spacing: spacing(gap))
            default:
                for child in node.children { block(child, ctx) }
            }
        }

        /// A paragraph at the context's indent, led by its list marker if it is an item's first block.
        mutating func text(_ content: NSMutableAttributedString, _ ctx: Context, spacing: Double) {
            if let m = ctx.marker {
                let lead = NSMutableAttributedString(string: m.text + "\t", attributes: [fontKey: font(fontSize), colorKey: color])
                if let line = m.line {
                    lead.addAttribute(checkboxAttribute, value: line, range: NSRange(location: 0, length: (m.text as NSString).length))
                }
                lead.append(content)
                paragraph(lead, paragraphStyle(spacingBefore: spacing, firstIndent: m.start, indent: m.hang, tabs: [(.left, m.hang)]),
                          quote: ctx.quote)
            } else {
                paragraph(content, paragraphStyle(spacingBefore: spacing, firstIndent: ctx.indent, indent: ctx.indent), quote: ctx.quote)
            }
        }

        /// Rows as paragraphs with a tab stop per column, aligned as the table asks. A table wider than the
        /// note is set in a smaller font, so cells stay in their columns instead of wrapping.
        mutating func table(_ table: Table, _ ctx: Context) {
            let rows: [(cells: [Table.Cell], header: Bool)] = [(Array(table.head.cells), true)] + table.body.rows.map { (Array($0.cells), false) }
            let columns = max(table.maxColumnCount, 1)
            func cell(_ c: Table.Cell, header: Bool, size: Double) -> NSMutableAttributedString {
                let s = inline(c, Inline(size: size, bold: header, italic: ctx.quote != nil, color: ctx.quote != nil ? faded : color))
                s.mutableString.replaceOccurrences(of: lineSeparator, with: " ", range: NSRange(location: 0, length: s.length))
                return s
            }
            func widths(size: Double) -> [Double] {
                var w = [Double](repeating: 0, count: columns)
                for row in rows { for (i, c) in row.cells.enumerated() where i < columns { w[i] = max(w[i], Note.width(of: cell(c, header: row.header, size: size))) } }
                return w
            }
            let available = max(width - ctx.indent, 1)
            var size = fontSize
            var w = widths(size: size)
            var gutter = size * 1.2
            let natural = w.reduce(0, +) + gutter * Double(columns - 1)
            if natural > available {
                size = max(fontSize * available / natural, min(fontSize, 9))
                w = widths(size: size)
                gutter = size * 1.2
            }
            var starts: [Double] = []
            var x = ctx.indent
            for wi in w { starts.append(x); x += wi + gutter }
            let total = x - gutter - ctx.indent
            // Column 0 starts at the indent unless it is centered or right-aligned, which needs a tab to get there.
            var tabs: [(CTTextAlignment, Double)] = []
            var leadingTab = false
            for i in 0..<columns {
                let align = i < table.columnAlignments.count ? table.columnAlignments[i] : nil
                switch align {
                case .center?: tabs.append((.center, starts[i] + w[i] / 2))
                case .right?: tabs.append((.right, starts[i] + w[i]))
                default: if i > 0 { tabs.append((.left, starts[i])) }
                }
                if i == 0, align == .center || align == .right { leadingTab = true }
            }
            for (n, row) in rows.enumerated() {
                let line = NSMutableAttributedString()
                let plain: [NSAttributedString.Key: Any] = [fontKey: font(size), colorKey: color]
                if leadingTab { line.append(NSAttributedString(string: "\t", attributes: plain)) }
                for i in 0..<columns {
                    if i > 0 { line.append(NSAttributedString(string: "\t", attributes: plain)) }
                    if i < row.cells.count { line.append(cell(row.cells[i], header: row.header, size: size)) }
                }
                if line.length == 0 { line.append(NSAttributedString(string: " ", attributes: plain)) }
                if row.header {
                    line.addAttribute(tableRuleAttribute, value: [ctx.indent, total], range: NSRange(location: 0, length: line.length))
                }
                let before = n == 0 ? spacing(gap) : n == 1 ? size * 0.45 : size * 0.2
                paragraph(line, paragraphStyle(spacingBefore: before, firstIndent: ctx.indent, indent: ctx.indent, tabs: tabs),
                          quote: ctx.quote)
            }
        }

        func inline(_ node: Markup, _ style: Inline) -> NSMutableAttributedString {
            let out = NSMutableAttributedString()
            func plain(_ s: String, _ style: Inline) {
                var attrs: [NSAttributedString.Key: Any] = [
                    fontKey: font(style.mono ? style.size * 0.9 : style.size, bold: style.bold, italic: style.italic, mono: style.mono),
                    colorKey: style.color,
                ]
                if style.strike { attrs[strikeAttribute] = true }
                if style.link { attrs[underlineKey] = CTUnderlineStyle.single.rawValue }
                let piece = NSMutableAttributedString(string: s, attributes: attrs)
                // cmark-gfm's autolink extension is off in swift-markdown, so underline bare URLs here.
                if !style.link, !style.mono, s.contains("://") || s.contains("www."), let detector = linkDetector {
                    for m in detector.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
                        piece.addAttribute(underlineKey, value: CTUnderlineStyle.single.rawValue, range: m.range)
                    }
                }
                out.append(piece)
            }
            func walk(_ node: Markup, _ style: Inline) {
                var style = style
                switch node {
                case let t as Markdown.Text: plain(t.string, style)
                case let c as InlineCode: style.mono = true; plain(c.code, style)
                case is SoftBreak, is LineBreak: plain(lineSeparator, style)
                case let h as InlineHTML: plain(h.rawHTML, style)
                case let img as Markdown.Image: plain(img.plainText, style)
                default:
                    if node is Strong { style.bold = true }
                    if node is Emphasis { style.italic = true }
                    if node is Strikethrough { style.strike = true }
                    if node is Markdown.Link { style.link = true }
                    for child in node.children { walk(child, style) }
                }
            }
            for child in node.children { walk(child, style) }
            return out
        }
    }

    nonisolated(unsafe) private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The whole note as one attributed string, a paragraph per block, for text up to `width` wide.
    static func attributed(_ source: String, fontSize: Double, color: CGColor, width: Double = .greatestFiniteMagnitude) -> NSAttributedString {
        var b = Builder(fontSize: fontSize, color: color, faded: color.copy(alpha: color.alpha * 0.7) ?? color, width: width)
        b.block(Document(parsing: source), Context())
        return b.out
    }

    // MARK: Layout

    /// The laid-out text, in a CoreText frame whose path is `rect` (y-up), with the string it lays out.
    /// Use `lines(of:in:)` for top-left positions.
    static func layout(_ source: String, in rect: CGRect, fontSize: Double, color: CGColor) -> (text: NSAttributedString, frame: CTFrame) {
        // Parsing and typesetting cost far more than drawing, and a redraw (every drag event) repeats them
        // for every note on screen; everything the layout depends on is in the key.
        let key = LayoutKey(source: source, fontSize: fontSize, color: color.components ?? [], rect: rect)
        return cache.layout(key) {
            let text = attributed(source, fontSize: fontSize, color: color, width: rect.width)
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

    /// Strikethroughs, rules, quote bars and table header rules as line segments in top-left coordinates,
    /// drawn after the text.
    static func decorations(_ lines: [Line], in rect: CGRect) -> [(CGPoint, CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        for l in lines {
            let runs = CTLineGetGlyphRuns(l.line) as! [CTRun]
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(l.line, &ascent, &descent, nil)
            if let first = runs.first {
                let attrs = CTRunGetAttributes(first) as NSDictionary
                if let x = attrs[quoteAttribute] as? Double {
                    out.append((CGPoint(x: rect.minX + x, y: l.origin.y - ascent), CGPoint(x: rect.minX + x, y: l.origin.y + descent)))
                }
                if let x = attrs[ruleAttribute] as? Double {
                    out.append((CGPoint(x: rect.minX + x, y: l.origin.y - 3), CGPoint(x: rect.maxX, y: l.origin.y - 3)))
                }
                if let span = attrs[tableRuleAttribute] as? [Double], span.count == 2 {
                    let y = l.origin.y + descent + 2
                    out.append((CGPoint(x: rect.minX + span[0], y: y), CGPoint(x: min(rect.maxX, rect.minX + span[0] + span[1]), y: y)))
                }
            }
            for run in runs where (CTRunGetAttributes(run) as NSDictionary)[strikeAttribute] != nil {
                let range = CTRunGetStringRange(run)
                let start = CTLineGetOffsetForStringIndex(l.line, range.location, nil)
                let end = CTLineGetOffsetForStringIndex(l.line, range.location + range.length, nil)
                var runAscent: CGFloat = 0
                _ = CTRunGetTypographicBounds(run, CFRange(), &runAscent, nil, nil)
                let y = l.origin.y - runAscent * 0.32
                out.append((CGPoint(x: l.origin.x + start, y: y), CGPoint(x: l.origin.x + end, y: y)))
            }
        }
        return out
    }

    // MARK: Checkboxes

    /// The source line of the task checkbox drawn at `p` (in the note's own, unrotated frame), if any.
    public static func checkboxLine(at p: CGPoint, in e: Element) -> Int? {
        guard e.kind == .note, let source = e.text, source.contains("[") else { return nil }
        let rect = textRect(e.frame)
        guard rect.insetBy(dx: -4, dy: -4).contains(p) else { return nil }
        let (_, frame) = layout(source, in: rect, fontSize: e.style.fontSize, color: e.style.stroke.cgColor)
        let slop = 4.0
        for l in lines(of: frame, in: rect) {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(l.line, &ascent, &descent, nil)
            guard p.y >= l.origin.y - ascent - slop, p.y <= l.origin.y + descent + slop else { continue }
            for run in CTLineGetGlyphRuns(l.line) as! [CTRun] {
                guard let line = (CTRunGetAttributes(run) as NSDictionary)[checkboxAttribute] as? Int else { continue }
                let range = CTRunGetStringRange(run)
                let start = l.origin.x + CTLineGetOffsetForStringIndex(l.line, range.location, nil)
                let end = l.origin.x + CTLineGetOffsetForStringIndex(l.line, range.location + range.length, nil)
                if p.x >= start - slop, p.x <= end + slop { return line }
            }
        }
        return nil
    }

    /// `source` with the task checkbox on 1-based `line` ticked or unticked.
    public static func togglingCheckbox(line: Int, in source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(line - 1) else { return source }
        let text = lines[line - 1]
        // The list marker, maybe inside quotes, then the box.
        let pattern = #"^(\s*(?:>\s*)*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return source }
        let box = m.range(at: 2)
        let ticked = (text as NSString).substring(with: box) != " "
        lines[line - 1] = (text as NSString).replacingCharacters(in: box, with: ticked ? " " : "x")
        return lines.joined(separator: "\n")
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
