import Foundation
import CoreGraphics
import CoreText

/// Single drawing path shared by the canvas, PNG and PDF export.
public enum Renderer {
    // MARK: Path cache

    /// What an element's outline or hatch depends on. Everything in the key is a plain value, so a
    /// cached path can never go stale: change the geometry or look and the key changes with it.
    struct ShapeKey: Hashable {
        var tag: UInt8            // 0 outline, 1 hachure
        var kind: ElementKind
        var x, y, w, h: Double
        var seed: UInt32
        var roughness, bowing, strokeWidth: Double
        var fillStyle: FillStyle
        var cell: Double
        var pathHash: Int
    }

    struct ConnectorKey: Hashable {
        var seed: UInt32
        var roughness, bowing, strokeWidth: Double
        var routing: Routing
        var startHead, endHead: Arrowhead
        var startPort, endPort: Port?
        var ax, ay, bx, by: Double
    }

    final class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var shapes: [ShapeKey: CGPath] = [:]
        private var connectors: [ConnectorKey: (CGPath, CGPath)] = [:]
        private let limit = 6000
        private(set) var hits = 0
        private(set) var misses = 0

        func shape(_ k: ShapeKey, _ make: () -> CGPath) -> CGPath {
            lock.lock()
            if let p = shapes[k] { hits += 1; lock.unlock(); return p }
            lock.unlock()
            let p = make()
            lock.lock(); defer { lock.unlock() }
            misses += 1
            if shapes.count >= limit { shapes.removeAll(keepingCapacity: true) }
            shapes[k] = p
            return p
        }

        func connector(_ k: ConnectorKey, _ make: () -> (CGPath, CGPath)) -> (CGPath, CGPath) {
            lock.lock()
            if let p = connectors[k] { hits += 1; lock.unlock(); return p }
            lock.unlock()
            let p = make()
            lock.lock(); defer { lock.unlock() }
            misses += 1
            if connectors.count >= limit { connectors.removeAll(keepingCapacity: true) }
            connectors[k] = p
            return p
        }

        func reset() { lock.lock(); shapes = [:]; connectors = [:]; hits = 0; misses = 0; lock.unlock() }
        var stats: (hits: Int, misses: Int) { lock.lock(); defer { lock.unlock() }; return (hits, misses) }
    }

    static let cache = PathCache()
    /// Cache hit and miss counts since the last `resetPathCache()`; for tests and tuning.
    public static var pathCacheStats: (hits: Int, misses: Int) { cache.stats }
    public static func resetPathCache() { cache.reset() }

    private static func shapeKey(_ e: Element, tag: UInt8) -> ShapeKey {
        ShapeKey(tag: tag, kind: e.kind, x: e.x, y: e.y, w: e.width, h: e.height, seed: e.seed,
                 roughness: e.style.roughness, bowing: e.style.bowing, strokeWidth: e.style.strokeWidth,
                 fillStyle: e.style.fillStyle, cell: e.style.fillStyle == .grid ? e.style.cellSize : 0, pathHash: e.path?.hashValue ?? e.subpaths?.hashValue ?? 0)
    }

    /// Outline path for an element. roughness == 0 gives exact geometry.
    public static func outline(for e: Element) -> CGPath {
        // A stroke still being drawn changes every event; caching it would only churn the cache.
        if e.kind == .freehand, e.path == nil { return computeOutline(for: e) }
        return cache.shape(shapeKey(e, tag: 0)) { computeOutline(for: e) }
    }

    private static func computeOutline(for e: Element) -> CGPath {
        let r = e.frame
        var rng = SeededRNG(seed: e.seed)
        let rough = e.style.roughness
        switch e.kind {
        case .rectangle, .note, .image:
            if rough <= 0 { return CGPath(rect: r, transform: nil) }
            return Rough.polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                  CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)],
                                 rng: &rng, roughness: rough, bowing: e.style.bowing)
        case .diamond:
            let pts = [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                       CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
            if rough <= 0 {
                let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
            }
            return Rough.polygon(pts, rng: &rng, roughness: rough, bowing: e.style.bowing)
        case .ellipse:
            if rough <= 0 { return CGPath(ellipseIn: r, transform: nil) }
            return Rough.ellipse(in: r, rng: &rng, roughness: rough)
        case .text, .connector:
            return CGPath(rect: r, transform: nil)
        case .freehand:
            return freehandPath(for: e)
        case .path:
            return rough <= 0 ? e.shapePath : sketchyShape(e, rng: &rng)
        }
    }

    /// A `.path` drawn by hand: straight segments get the doubled rough.js line, curves are retraced
    /// twice with their control points nudged. End points stay put so contours remain joined.
    private static func sketchyShape(_ e: Element, rng: inout SeededRNG) -> CGPath {
        let rough = e.style.roughness
        let out = CGMutablePath()
        for sub in e.shapeContours {
            let p = sub.points
            for k in 0..<((p.count - 1) / 3) {
                let a = p[3 * k], c1 = p[3 * k + 1], c2 = p[3 * k + 2], b = p[3 * k + 3]
                if c1 == a && c2 == b {
                    Rough.line(a, b, rng: &rng, roughness: rough, bowing: e.style.bowing, preserveEnds: true, into: out)
                    continue
                }
                let hull = hypot(c1.x - a.x, c1.y - a.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(b.x - c2.x, b.y - c2.y)
                let wobble = min(2.5, hull / 30) * rough
                for pass in 0..<2 {
                    let spread = pass == 0 ? 1.0 : 0.5
                    func j() -> CGFloat { CGFloat(rng.signed() * wobble * spread) }
                    out.move(to: a)
                    out.addCurve(to: b, control1: CGPoint(x: c1.x + j(), y: c1.y + j()),
                                 control2: CGPoint(x: c2.x + j(), y: c2.y + j()))
                }
            }
        }
        return out
    }

    /// A committed stroke is its fitted Bézier chain; one still being drawn (or from an older file)
    /// is smoothed through its raw points.
    static func freehandPath(for e: Element) -> CGPath {
        let r = e.frame
        if let flat = e.path, flat.count >= 8, (flat.count - 2) % 6 == 0 {
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: r.minX + flat[2 * i] * r.width, y: r.minY + flat[2 * i + 1] * r.height)
            }
            let path = CGMutablePath()
            path.move(to: pt(0))
            for s in 0..<((flat.count / 2 - 1) / 3) {
                path.addCurve(to: pt(3 * s + 3), control1: pt(3 * s + 1), control2: pt(3 * s + 2))
            }
            return path
        }
        let pts = (e.points ?? []).map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 { path.addLine(to: first); return path }
        if pts.count == 2 { path.addLine(to: pts[1]); return path }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// Connector geometry split into the stroked line (with open arrowheads) and the closed shapes
    /// (triangle and dot heads) that are also filled with the stroke color. Sketchy when roughness > 0.
    public static func connectorParts(for e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> (line: CGPath, filled: CGPath) {
        guard let c = e.connector else { return (CGMutablePath(), CGMutablePath()) }
        // The route depends on the document only through the two resolved endpoints.
        let (a, b) = Connector.endpoints(of: e, in: doc, index: index)
        let key = ConnectorKey(seed: e.seed, roughness: e.style.roughness, bowing: e.style.bowing,
                               strokeWidth: e.style.strokeWidth, routing: c.routing, startHead: c.startHead,
                               endHead: c.endHead, startPort: c.start.port, endPort: c.end.port,
                               ax: a.x, ay: a.y, bx: b.x, by: b.y)
        let parts = cache.connector(key) { computeConnector(for: e, in: doc, index: index) }
        return (parts.0, parts.1)
    }

    private static func computeConnector(for e: Element, in doc: DottieDocument, index: [UUID: Element]?) -> (CGPath, CGPath) {
        guard let c = e.connector else { return (CGMutablePath(), CGMutablePath()) }
        var rng = SeededRNG(seed: e.seed)
        let rough = e.style.roughness
        let bow = e.style.bowing
        let path = CGMutablePath()
        let solid = CGMutablePath()
        let route = Connector.route(of: e, in: doc, index: index)

        switch route {
        case .polyline(let pts):
            for i in 0..<max(pts.count - 1, 0) {
                if rough <= 0 { path.move(to: pts[i]); path.addLine(to: pts[i + 1]) }
                else { Rough.line(pts[i], pts[i + 1], rng: &rng, roughness: rough, bowing: bow, preserveEnds: true, into: path) }
            }
        case .cubic(let a, let b, let c2, let d):
            path.move(to: a)
            let w = rough * 3
            func j() -> CGFloat { CGFloat(rng.signed() * w) }
            path.addCurve(to: d, control1: CGPoint(x: b.x + j(), y: b.y + j()), control2: CGPoint(x: c2.x + j(), y: c2.y + j()))
        }

        let pts = route.points
        let size = max(10, e.style.strokeWidth * 5)
        func line(_ a: CGPoint, _ b: CGPoint) {
            if rough <= 0 { path.move(to: a); path.addLine(to: b) }
            else { Rough.line(a, b, rng: &rng, roughness: rough * 0.5, bowing: 0, preserveEnds: true, into: path) }
        }
        func head(_ kind: Arrowhead, tip: CGPoint, from: CGPoint) {
            let (w1, w2) = Connector.arrowhead(tip: tip, from: from, size: size)
            switch kind {
            case .none: break
            case .arrow:
                line(w1, tip); line(w2, tip)
            case .triangle:
                line(w1, tip); line(w2, tip); line(w1, w2)
                solid.move(to: tip); solid.addLine(to: w1); solid.addLine(to: w2); solid.closeSubpath()
            case .dot:
                let r = size * 0.32
                let ang = atan2(tip.y - from.y, tip.x - from.x)
                let ctr = CGPoint(x: tip.x - r * cos(ang), y: tip.y - r * sin(ang))
                solid.addEllipse(in: CGRect(x: ctr.x - r, y: ctr.y - r, width: 2 * r, height: 2 * r))
            case .bar:
                let ang = atan2(tip.y - from.y, tip.x - from.x) + .pi / 2
                let h = size * 0.5
                line(CGPoint(x: tip.x - h * cos(ang), y: tip.y - h * sin(ang)),
                     CGPoint(x: tip.x + h * cos(ang), y: tip.y + h * sin(ang)))
            }
        }
        if pts.count > 1 {
            head(c.endHead, tip: pts[pts.count - 1], from: pts[pts.count - 2])
            head(c.startHead, tip: pts[0], from: pts[1])
        }
        return (path, solid)
    }

    /// Everything a connector paints, as one path (selection halo, bounds, hit areas).
    public static func connectorPath(for e: Element, in doc: DottieDocument) -> CGPath {
        let (line, filled) = connectorParts(for: e, in: doc)
        let all = CGMutablePath()
        all.addPath(line); all.addPath(filled)
        return all
    }

    // MARK: Connector labels

    /// Point halfway along the connector's route.
    public static func midpoint(of e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> CGPoint {
        let pts = Connector.route(of: e, in: doc, index: index).points
        guard pts.count > 1 else { return pts.first ?? .zero }
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for i in 0..<(pts.count - 1) {
            let l = hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y)
            lengths.append(l); total += l
        }
        var remaining = total / 2
        for (i, l) in lengths.enumerated() {
            if remaining <= l || i == lengths.count - 1 {
                let t = l == 0 ? 0 : remaining / l
                return CGPoint(x: pts[i].x + (pts[i + 1].x - pts[i].x) * t, y: pts[i].y + (pts[i + 1].y - pts[i].y) * t)
            }
            remaining -= l
        }
        return pts[0]
    }

    /// Where a connector's label sits (and where its in-place editor goes).
    public static func labelRect(for e: Element, in doc: DottieDocument, index: [UUID: Element]? = nil) -> CGRect {
        let m = midpoint(of: e, in: doc, index: index)
        let text = e.text ?? ""
        let size = textSize(text.isEmpty ? "Label" : text, fontSize: e.style.fontSize, maxWidth: 200)
        let w = max(size.width + 12, 44), h = size.height + 6
        return CGRect(x: m.x - w / 2, y: m.y - h / 2, width: w, height: h)
    }

    static func textSize(_ s: String, fontSize: Double, maxWidth: Double) -> CGSize {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
        let str = CFAttributedStringCreate(nil, s as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let setter = CTFramesetterCreateWithAttributedString(str)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: Fills

    /// Straight-edged outline of a filled shape; an ellipse is approximated closely enough to hatch.
    /// Every contour of the filled shape as a polygon; only a `.path` has more than one.
    static func fillPolygons(for e: Element) -> [[CGPoint]] {
        guard e.kind == .path else { return [fillPolygon(for: e)] }
        return e.shapeContours.map { Element.flatten($0.points, maxStep: 3) }
    }

    static func fillPolygon(for e: Element) -> [CGPoint] {
        let r = e.frame
        switch e.kind {
        case .ellipse:
            return (0..<48).map { i in
                let t = 2 * Double.pi * Double(i) / 48
                return CGPoint(x: r.midX + r.width / 2 * cos(t), y: r.midY + r.height / 2 * sin(t))
            }
        case .diamond:
            return [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                    CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
        default:
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        }
    }

    /// Pen-shaded fill for `fillStyle` hachure / crossHatch, or the cell lines of a grid fill; empty for solid fills.
    public static func hachurePath(for e: Element) -> CGPath {
        guard e.style.fillStyle != .solid, e.kind != .freehand, e.kind != .connector, e.kind != .text, e.kind != .image else {
            return CGMutablePath()
        }
        return cache.shape(shapeKey(e, tag: 1)) { computeHachure(for: e) }
    }

    private static func computeHachure(for e: Element) -> CGPath {
        let path = CGMutablePath()
        let polys = fillPolygons(for: e)
        if e.style.fillStyle == .grid {
            let path = CGMutablePath()
            var rng = SeededRNG(seed: e.seed ^ 0x5bd1e995)
            for (a, b) in DungeonGrid.lines(in: polys, cell: e.style.cellSize) {
                if e.style.roughness <= 0 { path.move(to: a); path.addLine(to: b) }
                else { Rough.line(a, b, rng: &rng, roughness: e.style.roughness * 0.3, bowing: 0.3, into: path) }
            }
            return path
        }
        let gap = max(4, e.style.strokeWidth * 4)
        var angles = [Hachure.angle]
        if e.style.fillStyle == .crossHatch { angles.append(Hachure.angle + .pi / 2) }
        var rng = SeededRNG(seed: e.seed ^ 0x5bd1e995)
        for angle in angles {
            for (a, b) in Hachure.lines(in: polys, angle: angle, gap: gap) {
                if e.style.roughness <= 0 { path.move(to: a); path.addLine(to: b) }
                else { Rough.line(a, b, rng: &rng, roughness: e.style.roughness * 0.6, bowing: 0.5, into: path) }
            }
        }
        return path
    }

    /// Dash lengths for a stroke width; nil for a solid line.
    public static func dashPattern(_ dash: DashStyle, width: Double) -> [Double]? {
        switch dash {
        case .solid: return nil
        case .dashed: return [max(8, width * 4), max(6, width * 3)]
        case .dotted: return [0.01, max(5, width * 2.6)]
        }
    }

    /// Precise shape used for fills and hit areas.
    static func fillPath(for e: Element) -> CGPath {
        let r = e.frame
        switch e.kind {
        case .ellipse: return CGPath(ellipseIn: r, transform: nil)
        case .path: return e.shapePath
        case .diamond:
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                                 CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)])
            p.closeSubpath(); return p
        default: return CGPath(rect: r, transform: nil)
        }
    }

    // MARK: Drawing

    /// Draws with a top-left origin (y down). Callers must flip the context if needed.
    /// `background` is painted behind connector labels so the line doesn't strike through the text.
    /// How much detail is worth drawing at a view zoom (screen points per model unit). Far out,
    /// thousands of hairline hatches are noise: they fall back to a flat tint, and unreadable labels go.
    public struct DetailLevel: Sendable {
        public var zoom: Double
        public init(zoom: Double) { self.zoom = zoom }
        var hatch: Bool { zoom >= 0.25 }
        var dashes: Bool { zoom >= 0.2 }
        var sketchy: Bool { zoom >= 0.12 }
        func showsText(fontSize: Double) -> Bool { fontSize * zoom >= 4 }
        func isVisible(_ box: CGRect) -> Bool { max(box.width, box.height) * zoom >= 0.75 }
    }

    /// `clip` (model units) skips elements entirely outside it, so a zoomed-in view of a big drawing
    /// only pays for what is on screen. Pass a `spatial` index built from `doc` to find those elements
    /// without visiting the rest. `zoom` enables level of detail; `ink` resolves automatic ink per drawn
    /// element instead of copying the whole document.
    public static func draw(_ doc: DottieDocument, in ctx: CGContext, background: CGColor? = nil, clip: CGRect? = nil,
                            zoom: Double? = nil, ink: RGBA? = nil, spatial: SpatialIndex? = nil) {
        let visible = Set(doc.layers.filter(\.visible).map(\.id))
        let lod = zoom.map(DetailLevel.init)
        let index = spatial?.byID ?? doc.elementIndex

        func paint(_ e: Element) {
            guard visible.contains(e.layerID) else { return }
            if let lod, e.kind != .connector, !lod.isVisible(e.rotatedBounds) { return }
            draw(ink.map { e.resolvingInk(to: $0) } ?? e, in: ctx, document: doc, background: background, index: index, lod: lod)
        }

        if lod?.hatch ?? true { drawRock(doc, visible: visible, ink: ink, in: ctx) }

        if let spatial, let clip {
            for pos in spatial.candidates(in: clip) { paint(spatial.ordered[pos]) }
            return
        }
        for e in doc.orderedElements {
            if let clip {
                let box = e.kind == .connector ? Connector.bounds(of: e, in: doc, index: index) : e.rotatedBounds
                // Pad for stroke width, arrowheads and connector labels.
                if !box.insetBy(dx: -(e.style.strokeWidth + 60), dy: -(e.style.strokeWidth + 60)).intersects(clip) { continue }
            }
            paint(e)
        }
    }

    /// Dyson hatching in the rock around every grid-filled floor, drawn under all elements so each floor
    /// covers the strokes that run beneath its edge.
    static func drawRock(_ doc: DottieDocument, visible: Set<UUID>, ink: RGBA?, in ctx: CGContext) {
        let floors = doc.orderedElements.filter { visible.contains($0.layerID) && DungeonGrid.isFloor($0) }
        guard !floors.isEmpty else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        for rock in DungeonGrid.rock(for: floors.map { e in ink.map { e.resolvingInk(to: $0) } ?? e }) {
            ctx.addPath(rock.path)
            ctx.setStrokeColor(rock.ink.cgColor)
            ctx.setLineWidth(rock.width)
            ctx.strokePath()
        }
    }

    public static func draw(_ e: Element, in ctx: CGContext, document: DottieDocument? = nil, background: CGColor? = nil,
                            index: [UUID: Element]? = nil, lod: DetailLevel? = nil) {
        var e = e
        if let lod, !lod.sketchy, e.style.roughness > 0 { e.style.roughness = 0 } // clean geometry is cheaper and unseen far out
        let alpha = min(max(e.style.opacity ?? 1, 0), 1)
        if alpha <= 0 { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        // A translucent element fades as a whole: overlapping stroke, fill and label don't add up.
        if alpha < 1 { ctx.setAlpha(alpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        defer { if alpha < 1 { ctx.endTransparencyLayer() } }
        func applyStroke() {
            ctx.setStrokeColor(e.style.stroke.cgColor)
            ctx.setLineWidth(e.style.strokeWidth)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            if lod?.dashes ?? true, let d = dashPattern(e.style.dash, width: e.style.strokeWidth) {
                ctx.setLineDash(phase: 0, lengths: d.map { CGFloat($0) })
            }
        }
        if let r = e.revealProgress, e.kind == .text { e.text = e.typed(e.text ?? "", r) }
        if e.kind == .connector {
            guard let document else { return }
            let (line, filled) = connectorParts(for: e, in: document, index: index)
            if let r = e.revealProgress { // drawing on: the line, then its arrowheads; the label waits
                ctx.addPath(line.trimmed(to: r))
                applyStroke()
                ctx.strokePath()
                return
            }
            ctx.addPath(line); ctx.addPath(filled)
            applyStroke()
            ctx.strokePath()
            if !filled.isEmpty {
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.addPath(filled)
                ctx.setFillColor(e.style.stroke.cgColor)
                ctx.fillPath()
            }
            if let t = e.text, !t.isEmpty, lod?.showsText(fontSize: e.style.fontSize) ?? true {
                let r = labelRect(for: e, in: document, index: index)
                if let background { ctx.setFillColor(background); ctx.fill(r) }
                drawText(t, in: r, fontSize: e.style.fontSize, color: e.style.stroke.cgColor, ctx: ctx, centered: true)
            }
            return
        }
        if e.angle != 0 { // rotate the whole shape (fill, outline, label) about its center
            ctx.translateBy(x: e.frame.midX, y: e.frame.midY)
            ctx.rotate(by: e.angle)
            ctx.translateBy(x: -e.frame.midX, y: -e.frame.midY)
        }
        if let r = e.revealProgress, e.kind != .text { // drawing on: the outline only, fill and label once it closes
            ctx.addPath(outline(for: e).trimmed(to: r))
            applyStroke()
            ctx.strokePath()
            return
        }
        if e.kind == .text {
            if lod?.showsText(fontSize: e.style.fontSize) ?? true {
                drawText(e.text ?? "", in: e.frame, fontSize: e.style.fontSize, color: e.style.stroke.cgColor, ctx: ctx)
            }
            return
        }
        if e.kind == .image {
            drawImage(e, in: ctx)
            return
        }
        if e.kind == .note, e.style.fill.a > 0 { // a soft drop shadow lifts the note off the page
            ctx.addPath(fillPath(for: e).copy(using: [CGAffineTransform(translationX: Note.shadowOffset.width, y: Note.shadowOffset.height)])!)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.14 * e.style.fill.a))
            ctx.fillPath()
        }
        if e.style.fill.a > 0, e.kind != .freehand {
            if e.style.fillStyle == .solid || !(lod?.hatch ?? true) {
                ctx.addPath(fillPath(for: e))
                var tint = e.style.fill
                if e.style.fillStyle == .hachure || e.style.fillStyle == .crossHatch { tint.a *= 0.55 } // hatching read from afar is a lighter wash
                ctx.setFillColor(tint.cgColor)
                ctx.fillPath(using: e.evenOdd == true ? .evenOdd : .winding)
            } else {
                let grid = e.style.fillStyle == .grid
                if grid {
                    ctx.addPath(fillPath(for: e))
                    ctx.setFillColor(e.style.fill.cgColor)
                    ctx.fillPath(using: e.evenOdd == true ? .evenOdd : .winding)
                }
                ctx.saveGState()
                ctx.addPath(hachurePath(for: e))
                ctx.setStrokeColor(grid ? DungeonGrid.lineColor(for: e.style.fill).cgColor : e.style.fill.cgColor)
                ctx.setLineWidth(grid ? 1 : max(1, e.style.strokeWidth / 2))
                ctx.setLineCap(.round)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        ctx.addPath(outline(for: e))
        applyStroke()
        ctx.strokePath()
        if e.kind == .note {
            if let t = e.text, !t.isEmpty, lod?.showsText(fontSize: e.style.fontSize) ?? true {
                Note.draw(t, in: Note.textRect(e.frame), fontSize: e.style.fontSize, color: e.style.stroke.cgColor, ctx: ctx)
            }
            return
        }
        if let t = e.text, !t.isEmpty, lod?.showsText(fontSize: e.style.fontSize) ?? true {
            drawText(t, in: e.frame.insetBy(dx: 6, dy: 6), fontSize: e.style.fontSize, color: e.style.stroke.cgColor, ctx: ctx, centered: true)
        }
    }

    /// A picture fills its frame (stretched if the frame was resized out of proportion); a visible stroke
    /// draws a border over it, sketchy like any other outline. A picture that cannot be decoded shows as a
    /// crossed-out box so it is not silently invisible.
    private static func drawImage(_ e: Element, in ctx: CGContext) {
        let r = e.frame
        if let img = e.image?.cgImage {
            // CGContext draws images y-up; flip locally within the top-left-origin context.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: r.minY + r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: r)
            ctx.restoreGState()
        } else {
            ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
            ctx.setLineWidth(1)
            ctx.stroke(r)
            ctx.move(to: CGPoint(x: r.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            ctx.move(to: CGPoint(x: r.maxX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            ctx.strokePath()
        }
        guard e.style.stroke.a > 0, e.style.strokeWidth > 0 else { return }
        ctx.addPath(outline(for: e))
        ctx.setStrokeColor(e.style.stroke.cgColor)
        ctx.setLineWidth(e.style.strokeWidth)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        if let d = dashPattern(e.style.dash, width: e.style.strokeWidth) { ctx.setLineDash(phase: 0, lengths: d.map { CGFloat($0) }) }
        ctx.strokePath()
    }

    static func drawText(_ s: String, in rect: CGRect, fontSize: Double, color: CGColor, ctx: CGContext, centered: Bool = false) {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
        var align: CTTextAlignment = centered ? .center : .left
        let para = withUnsafeBytes(of: &align) { buf -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: buf.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color, kCTParagraphStyleAttributeName: para]
        let str = CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary)!
        let setter = CTFramesetterCreateWithAttributedString(str)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        let y = centered ? rect.midY - size.height / 2 : rect.minY
        let box = CGRect(x: rect.minX, y: y, width: rect.width, height: size.height)
        // CoreText draws y-up; flip locally within the top-left-origin context.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: box.minY + box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: box, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
