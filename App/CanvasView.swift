import AppKit
import UniformTypeIdentifiers
import SwiftUI
import DottieKit

/// A stencil item dragged out of the library panel.
struct DraggedStencil: Codable {
    static let typeIdentifier = "tech.phin.dottie.stencil"
    var item: StencilItem
    var keepOriginalColors: Bool
}

/// Asks the canvas to put a stencil item at the middle of the view (or at `at`, in model coordinates).
struct PlaceRequest: Equatable {
    var id = UUID()
    var item: StencilItem
    var keepOriginalColors: Bool
}

enum Tool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, diamond, text, note, connector, pencil, eraser
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .diamond: "diamond"
        case .text: "textformat"
        case .note: "note.text"
        case .connector: "arrow.up.right"
        case .pencil: "pencil.tip"
        case .eraser: "eraser"
        }
    }
    var label: String {
        switch self {
        case .select: "Select"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .diamond: "Diamond"
        case .text: "Text"
        case .note: "Note"
        case .connector: "Connector"
        case .pencil: "Pencil"
        case .eraser: "Eraser"
        }
    }
    /// Single-key tool switch, Photoshop-style.
    var shortcut: Character {
        switch self {
        case .select: "v"
        case .rectangle: "r"
        case .ellipse: "o"
        case .diamond: "d"
        case .text: "t"
        case .note: "n"
        case .connector: "c"
        case .pencil: "p"
        case .eraser: "e"
        }
    }
    var kind: ElementKind? {
        switch self {
        case .select: nil
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .diamond: .diamond
        case .text: .text
        case .note: .note
        case .connector: nil
        case .pencil: .freehand
        case .eraser: nil
        }
    }
}

/// Asks the canvas to follow a link to `target`, as clicking its badge would.
struct JumpRequest: Equatable {
    var id = UUID()
    var target: UUID
}

/// Which edge(s) a resize handle moves: -1 = min side, 1 = max side, 0 = unchanged.
private struct Handle: Equatable {
    var hx: Int, hy: Int
    static let all: [Handle] = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)].map { Handle(hx: $0.0, hy: $0.1) }

    func point(in r: CGRect) -> CGPoint {
        CGPoint(x: hx < 0 ? r.minX : hx > 0 ? r.maxX : r.midX,
                y: hy < 0 ? r.minY : hy > 0 ? r.maxY : r.midY)
    }

    func resized(_ r: CGRect, by d: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if hx < 0 { minX += d.x } else if hx > 0 { maxX += d.x }
        if hy < 0 { minY += d.y } else if hy > 0 { maxY += d.y }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }
}

private enum Gesture {
    case creating(Element)
    case moving
    case resizing(id: UUID, handle: Handle, original: CGRect)
    case marquee
    case connecting(id: UUID)
    case endpoint(id: UUID, isStart: Bool)
    case panning
    case drawing(id: UUID)
    case erasing
    case editingPoint(id: UUID, index: Int)
    case rotating(id: UUID)
    case rotatingGroup(center: CGPoint, start: Double)
    /// Dragging a ruler guide; `vertical` guides live in `guidesX`.
    case guide(vertical: Bool, index: Int)
}

/// Core Graphics canvas. Model coordinates are top-left origin, so the view is flipped.
final class CanvasNSView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    var model = DottieDocument() {
        willSet { if newValue.id != model.id { leavePage() } }
        didSet {
            needsDisplay = true; spatialStale = true; badgeCache = nil
            if model.id != oldValue.id { enterPage() }
        }
    }
    /// Built lazily for the current `model`. Panning and zooming reuse it; an edit marks it stale and
    /// the next use folds the changed elements in (or rebuilds when the structure changed).
    private var spatialCache: SpatialIndex?
    private var spatialStale = true
    private var spatial: SpatialIndex {
        if var s = spatialCache {
            if !spatialStale { return s }
            spatialCache = nil // drop our reference so the update mutates in place instead of copying
            if s.update(to: model) { spatialCache = s; spatialStale = false; return s }
        }
        let s = SpatialIndex(model)
        spatialCache = s
        spatialStale = false
        return s
    }
    var showRulers = false { didSet { needsDisplay = true } }
    private let rulerSize: CGFloat = 20
    var tool: Tool = .select
    var onToolChange: ((Tool) -> Void)?
    var selection: Set<UUID> = [] { didSet { needsDisplay = true; onSelectionChange?(selection) } }
    var style = Style()
    var routing: Routing = .straight
    /// New elements go here when it is visible and unlocked; otherwise the first layer that is.
    var activeLayerID: UUID?

    var onPreview: ((DottieDocument) -> Void)?
    var onCommit: ((DottieDocument, String) -> Void)?
    var onSelectionChange: ((Set<UUID>) -> Void)?
    /// Shows another page; `model` is that page when it returns.
    var onShowPage: ((UUID) -> Void)?
    /// The page holding a followable shape (on a visible layer), searching the whole file.
    var findPage: ((UUID) -> UUID?)?
    /// Whether an element exists anywhere in the file, so a paste keeps links to other pages.
    var elementExists: ((UUID) -> Bool)?
    /// Links shapes on page `page` (not the one on screen) to `target`, as one undo step.
    var onLinkOtherPage: ((_ sources: Set<UUID>, _ page: UUID, _ target: UUID) -> Bool)?

    /// Viewport offset in view points; model coordinates are unchanged by panning.
    private var pan: CGPoint = .zero { didSet { viewportChanged() } }
    /// view = model * zoom + pan
    private var zoom: CGFloat = 1 { didSet { viewportChanged() } }
    private let zoomRange: ClosedRange<CGFloat> = 0.1...8
    private var spaceDown = false { didSet { window?.invalidateCursorRects(for: self) } }
    private var panAnchor: (raw: CGPoint, pan: CGPoint) = (.zero, .zero)
    private var gesture: Gesture?
    private var dragStart: CGPoint = .zero
    private var baseline: DottieDocument?
    private var marqueeRect: CGRect?
    private var guides: [Snap.Guide] = []
    private var spacingGuides: [Snap.SpacingGuide] = []
    private var strokePoints: [CGPoint] = []
    private var pasteStep = 0
    private var lastPasteChangeCount = -1
    static let pasteboardType = NSPasteboard.PasteboardType("tech.phin.dottie.elements")
    private var hoverShapeID: UUID? { didSet { if oldValue != hoverShapeID { needsDisplay = true } } }
    private var editor: NSTextField?
    private var editingID: UUID?
    private var editBase: DottieDocument? // set for new text so undo removes the box entirely

    /// Where the view was before each jump, for Back and Forward.
    private var backStack: [Viewport] = []
    private var forwardStack: [Viewport] = []
    private var jumpTimer: Timer?
    /// The elements a jump just landed on, outlined briefly so the eye finds them.
    private var flashIDs: Set<UUID> = [] { didSet { needsDisplay = true } }
    private var flashToken = 0
    private var badgeCache: [LinkBadge]?
    /// The link of the shape under a ⌘-press, followed on release if the press did not turn into a drag.
    private var pressedLink: UUID?
    /// While set, the next click on a shape links these elements to it (Link to Element… in the context menu).
    /// It survives a page switch, so the target can be on another page.
    private var linkSources: Set<UUID>? {
        didSet { needsDisplay = true; window?.invalidateCursorRects(for: self); if linkSources == nil { linkSourcePage = nil } }
    }
    /// The page `linkSources` are on.
    private var linkSourcePage: UUID?
    /// Pan and zoom of the pages not on screen, restored when they come back.
    private var pageViewports: [UUID: Viewport] = [:]
    /// The last `JumpRequest` acted on, so a repeated SwiftUI update does not jump twice.
    var handledJump: UUID?
    /// The last `PlaceRequest` acted on, so a stencil is placed once however many update passes see it.
    var handledPlace: UUID?
    /// The document revision the link badges were last checked against.
    var fileRevision = -1

    private let handleSize: CGFloat = 8
    /// Handle size in model units so handles stay the same size on screen at any zoom.
    private var hs: CGFloat { handleSize / zoom }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        canvasBackground.setFill(); dirtyRect.fill()
        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)
        // Only what the dirty rectangle shows, in model units, found through the spatial index.
        let visible = CGRect(x: (dirtyRect.minX - pan.x) / zoom, y: (dirtyRect.minY - pan.y) / zoom,
                             width: dirtyRect.width / zoom, height: dirtyRect.height / zoom)
        // The label being edited is drawn by the editor instead, so the old text does not show through.
        var drawn = model
        if let id = editingID, let i = drawn.elements.firstIndex(where: { $0.id == id }) { drawn.elements[i].text = nil }
        Renderer.draw(drawn, in: ctx, background: canvasBackground.cgColor, clip: visible,
                      zoom: Double(zoom), ink: canvasInk, spatial: spatial)

        // Ruler guides sit over the drawing and under the selection.
        if showRulers {
            ctx.setStrokeColor(NSColor.systemTeal.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1 / zoom)
            for x in model.guidesX ?? [] {
                ctx.move(to: CGPoint(x: x, y: visible.minY)); ctx.addLine(to: CGPoint(x: x, y: visible.maxY))
            }
            for y in model.guidesY ?? [] {
                ctx.move(to: CGPoint(x: visible.minX, y: y)); ctx.addLine(to: CGPoint(x: visible.maxX, y: y))
            }
            ctx.strokePath()
        }

        let accent = NSColor.controlAccentColor
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5 / zoom)
        for e in model.elements where selection.contains(e.id) {
            if e.kind == .connector {
                ctx.addPath(Renderer.connectorPath(for: e, in: model))
                ctx.setLineWidth(e.style.strokeWidth + 4)
                ctx.setStrokeColor(accent.withAlphaComponent(0.3).cgColor)
                ctx.strokePath()
                ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(1.5 / zoom)
            } else {
                ctx.saveGState()
                ctx.translateBy(x: e.frame.midX, y: e.frame.midY); ctx.rotate(by: e.angle)
                ctx.translateBy(x: -e.frame.midX, y: -e.frame.midY)
                ctx.stroke(e.frame.insetBy(dx: -4, dy: -4))
                ctx.restoreGState()
            }
        }
        if let id = hoverShapeID, let e = model.elements.first(where: { $0.id == id }) {
            ctx.setLineWidth(2.5 / zoom)
            ctx.stroke(e.frame.insetBy(dx: -6, dy: -6))
            ctx.setFillColor(accent.cgColor)
            for port in Port.allCases {
                let p = Connector.portPoint(e, port)
                ctx.fillEllipse(in: CGRect(x: p.x - 3 / zoom, y: p.y - 3 / zoom, width: 6 / zoom, height: 6 / zoom))
            }
            ctx.setLineWidth(1.5 / zoom)
        }
        if let id = singleSelectionID, let c = model.elements.first(where: { $0.id == id }), c.kind == .connector {
            ctx.setFillColor(NSColor.white.cgColor)
            let (a, b) = Connector.endpoints(of: c, in: model)
            for p in [a, b] {
                let r = CGRect(x: p.x - 5 / zoom, y: p.y - 5 / zoom, width: 10 / zoom, height: 10 / zoom)
                ctx.fillEllipse(in: r); ctx.strokeEllipse(in: r)
            }
        } else if let id = singleSelectionID, let e = model.elements.first(where: { $0.id == id }) {
            ctx.setFillColor(NSColor.white.cgColor)
            for h in Handle.all {
                let p = e.rotated(h.point(in: e.frame.insetBy(dx: -4, dy: -4)))
                let r = CGRect(x: p.x - hs / 2, y: p.y - hs / 2, width: hs, height: hs)
                ctx.fill(r); ctx.stroke(r)
            }
            // Rotation knob on a stem above the top edge.
            let stemTop = e.rotated(CGPoint(x: e.frame.midX, y: e.frame.minY - 4))
            let knob = rotationKnob(for: e)
            ctx.move(to: stemTop); ctx.addLine(to: knob); ctx.strokePath()
            let kr = CGRect(x: knob.x - hs / 2, y: knob.y - hs / 2, width: hs, height: hs)
            ctx.fillEllipse(in: kr); ctx.strokeEllipse(in: kr)
        }
        if let (box, knob) = groupRotationKnob() {
            ctx.setLineWidth(1 / zoom)
            ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
            ctx.stroke(box)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.move(to: CGPoint(x: box.midX, y: box.minY)); ctx.addLine(to: knob); ctx.strokePath()
            let kr = CGRect(x: knob.x - hs / 2, y: knob.y - hs / 2, width: hs, height: hs)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: kr); ctx.strokeEllipse(in: kr)
        }
        if tool == .select, let id = singleSelectionID, let e = model.elements.first(where: { $0.id == id }),
           let cp = e.strokeControlPoints {
            ctx.setLineWidth(1 / zoom)
            ctx.setStrokeColor(accent.withAlphaComponent(0.6).cgColor)
            for s in 0..<((cp.count - 1) / 3) {
                ctx.move(to: cp[3 * s]); ctx.addLine(to: cp[3 * s + 1])
                ctx.move(to: cp[3 * s + 3]); ctx.addLine(to: cp[3 * s + 2])
            }
            ctx.strokePath()
            ctx.setStrokeColor(accent.cgColor)
            for (i, p) in cp.enumerated() {
                let r = CGRect(x: p.x - 4 / zoom, y: p.y - 4 / zoom, width: 8 / zoom, height: 8 / zoom)
                if i % 3 == 0 { ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r); ctx.stroke(r) }
                else { ctx.setFillColor(accent.cgColor); ctx.fillEllipse(in: r.insetBy(dx: 1 / zoom, dy: 1 / zoom)) }
            }
        }
        if !spacingGuides.isEmpty {
            ctx.setStrokeColor(NSColor.systemPink.cgColor)
            ctx.setLineWidth(1 / zoom)
            let tick = 4 / zoom
            for g in spacingGuides {
                for span in g.spans {
                    switch g.axis {
                    case .horizontal:
                        ctx.move(to: CGPoint(x: span.lowerBound, y: g.cross)); ctx.addLine(to: CGPoint(x: span.upperBound, y: g.cross))
                        for x in [span.lowerBound, span.upperBound] {
                            ctx.move(to: CGPoint(x: x, y: g.cross - tick)); ctx.addLine(to: CGPoint(x: x, y: g.cross + tick))
                        }
                    case .vertical:
                        ctx.move(to: CGPoint(x: g.cross, y: span.lowerBound)); ctx.addLine(to: CGPoint(x: g.cross, y: span.upperBound))
                        for y in [span.lowerBound, span.upperBound] {
                            ctx.move(to: CGPoint(x: g.cross - tick, y: y)); ctx.addLine(to: CGPoint(x: g.cross + tick, y: y))
                        }
                    }
                }
            }
            ctx.strokePath()
            ctx.setStrokeColor(accent.cgColor)
        }
        if !guides.isEmpty {
            ctx.setStrokeColor(NSColor.systemPink.cgColor)
            ctx.setLineWidth(1 / zoom)
            for g in guides {
                switch g.axis {
                case .vertical: ctx.move(to: CGPoint(x: g.position, y: g.from)); ctx.addLine(to: CGPoint(x: g.position, y: g.to))
                case .horizontal: ctx.move(to: CGPoint(x: g.from, y: g.position)); ctx.addLine(to: CGPoint(x: g.to, y: g.position))
                }
            }
            ctx.strokePath()
            ctx.setStrokeColor(accent.cgColor)
        }
        if !flashIDs.isEmpty {
            ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(3 / zoom)
            for e in model.elements where flashIDs.contains(e.id) && e.kind != .connector {
                ctx.saveGState()
                ctx.translateBy(x: e.frame.midX, y: e.frame.midY); ctx.rotate(by: e.angle)
                ctx.translateBy(x: -e.frame.midX, y: -e.frame.midY)
                let r = e.frame.insetBy(dx: -6, dy: -6)
                ctx.fill(r); ctx.stroke(r)
                ctx.restoreGState()
            }
        }
        drawLinkBadges(ctx, accent: accent)
        if let m = marqueeRect {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(m)
            ctx.setLineWidth(1 / zoom); ctx.stroke(m)
        }
        ctx.restoreGState()

        if showRulers { drawRulers(ctx) }
        if linkSources != nil { drawHint("Click the shape to link to (on any page)   ·   Esc to cancel") }

        if zoom != 1 {
            let label = "\(Int((zoom * 100).rounded()))%" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: bounds.maxX - size.width - 12, y: bounds.maxY - size.height - 8), withAttributes: attrs)
        }
    }

    /// A pill of text at the top middle of the view.
    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let label = text as NSString
        let size = label.size(withAttributes: attrs)
        let pill = CGRect(x: canvasArea.midX - size.width / 2 - 12, y: canvasArea.minY + 12, width: size.width + 24, height: size.height + 10)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: CGPoint(x: pill.minX + 12, y: pill.minY + 5), withAttributes: attrs)
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: Theme

    private func nsColor(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
    /// The page color: the drawing's theme, or the system's text background.
    private var canvasBackground: NSColor { model.resolvedTheme.map { nsColor($0.background) } ?? .textBackgroundColor }
    /// What automatic ink is shown as on this page.
    private var canvasInk: RGBA { model.resolvedTheme?.ink ?? (isDark ? .inkOnDark : .black) }

    // MARK: Rulers

    private func rulerStep() -> Double {
        let steps: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000, 10_000, 20_000, 50_000, 100_000]
        return steps.first { $0 * Double(zoom) >= 60 } ?? 100_000
    }

    private func drawRulers(_ ctx: CGContext) {
        let t = rulerSize
        let ink = nsColor(canvasInk)
        let bg = canvasBackground.blended(withFraction: 0.08, of: ink) ?? canvasBackground
        ctx.saveGState()
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: t))
        ctx.fill(CGRect(x: 0, y: 0, width: t, height: bounds.height))
        ctx.setStrokeColor(ink.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: t - 0.5)); ctx.addLine(to: CGPoint(x: bounds.width, y: t - 0.5))
        ctx.move(to: CGPoint(x: t - 0.5, y: 0)); ctx.addLine(to: CGPoint(x: t - 0.5, y: bounds.height))
        ctx.strokePath()

        let step = rulerStep()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                    .foregroundColor: ink.withAlphaComponent(0.7)]
        ctx.setStrokeColor(ink.withAlphaComponent(0.5).cgColor)
        func ticks(origin: CGFloat, length: CGFloat, horizontal: Bool) {
            var v = floor(-origin / zoom / step) * step
            let end = (length - origin) / zoom
            while v <= end {
                let at = CGFloat(v) * zoom + origin
                if at >= t {
                    if horizontal { ctx.move(to: CGPoint(x: at, y: t - 9)); ctx.addLine(to: CGPoint(x: at, y: t)) }
                    else { ctx.move(to: CGPoint(x: t - 9, y: at)); ctx.addLine(to: CGPoint(x: t, y: at)) }
                    ctx.strokePath()
                    let label = "\(Int(v.rounded()))" as NSString
                    if horizontal {
                        label.draw(at: CGPoint(x: at + 2, y: 2), withAttributes: attrs)
                    } else {
                        ctx.saveGState()
                        ctx.translateBy(x: 2, y: at - 2)
                        ctx.rotate(by: -.pi / 2)
                        label.draw(at: .zero, withAttributes: attrs)
                        ctx.restoreGState()
                    }
                }
                for k in 1..<5 {
                    let m = CGFloat(v + step * Double(k) / 5) * zoom + origin
                    guard m >= t else { continue }
                    if horizontal { ctx.move(to: CGPoint(x: m, y: t - 4)); ctx.addLine(to: CGPoint(x: m, y: t)) }
                    else { ctx.move(to: CGPoint(x: t - 4, y: m)); ctx.addLine(to: CGPoint(x: t, y: m)) }
                }
                ctx.strokePath()
                v += step
            }
        }
        ticks(origin: pan.x, length: bounds.width, horizontal: true)
        ticks(origin: pan.y, length: bounds.height, horizontal: false)
        ctx.restoreGState()
    }

    /// The guide under a model-space point (within a few screen pixels), if any.
    private func guideHit(_ p: CGPoint) -> (vertical: Bool, index: Int)? {
        guard model.guidesLocked != true else { return nil }
        let tol = 4 / zoom
        if let i = (model.guidesX ?? []).firstIndex(where: { abs($0 - p.x) <= tol }) { return (true, i) }
        if let i = (model.guidesY ?? []).firstIndex(where: { abs($0 - p.y) <= tol }) { return (false, i) }
        return nil
    }

    private func setGuide(_ doc: inout DottieDocument, vertical: Bool, index: Int, to value: Double) {
        if vertical, doc.guidesX?.indices.contains(index) == true { doc.guidesX?[index] = value }
        if !vertical, doc.guidesY?.indices.contains(index) == true { doc.guidesY?[index] = value }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    // MARK: Links

    private struct Viewport { var page: UUID? = nil; var pan: CGPoint; var zoom: CGFloat }

    /// Called while `model` still holds the page being left.
    private func leavePage() {
        if editor != nil { endEditing(deferCommit: true) }
        stopJumpAnimation()
        pageViewports[model.id] = Viewport(pan: pan, zoom: zoom)
    }

    /// Called once `model` holds the new page.
    private func enterPage() {
        gesture = nil; baseline = nil; marqueeRect = nil; hoverShapeID = nil; pressedLink = nil
        guides = []; spacingGuides = []; strokePoints = []; flashIDs = []
        if !selection.isEmpty { selection = [] }
        let v = pageViewports[model.id] ?? Viewport(pan: .zero, zoom: 1)
        zoom = v.zoom; pan = v.pan
    }

    private var here: Viewport { Viewport(page: model.id, pan: pan, zoom: zoom) }

    /// Must be called when another page's shapes or layers may have changed, since badges point across pages.
    func linksElsewhereChanged() { badgeCache = nil; needsDisplay = true }

    /// A link badge: `corner` is the top-right of the linked element (or of its group, which shares one badge).
    private struct LinkBadge { var corner: CGPoint; var target: UUID; var broken: Bool }

    private var linkBadges: [LinkBadge] {
        if let cached = badgeCache { return cached }
        var out: [LinkBadge] = []
        if model.elements.contains(where: { $0.link != nil }) {
            let visible = Set(model.layers.filter(\.visible).map(\.id))
            var groupBounds: [UUID: CGRect] = [:]
            for e in model.elements where e.kind != .connector {
                if let g = e.groupID { groupBounds[g] = (groupBounds[g] ?? .null).union(e.rotatedBounds) }
            }
            // A target is reachable when it exists on a visible layer (what `linkBounds(to:)` checks), found in one pass.
            let reachable = Set(model.elements.filter { visible.contains($0.layerID) && $0.kind != .connector }.map(\.id))
            var seen = Set<[UUID]>()
            for e in model.orderedElements {
                guard let target = e.link, visible.contains(e.layerID) else { continue }
                let b: CGRect
                if let g = e.groupID, let box = groupBounds[g] {
                    guard seen.insert([g, target]).inserted else { continue }
                    b = box
                } else {
                    b = e.kind == .connector ? Connector.bounds(of: e, in: model) : e.rotatedBounds
                }
                out.append(LinkBadge(corner: CGPoint(x: b.maxX, y: b.minY), target: target,
                                     broken: !reachable.contains(target) && findPage?(target) == nil))
            }
        }
        badgeCache = out
        return out
    }

    /// Beside the top-right corner, clear of the resize handles; the same size on screen at any zoom.
    private func badgeCenter(_ badge: LinkBadge) -> CGPoint {
        CGPoint(x: badge.corner.x + 4 + 18 / zoom, y: badge.corner.y + 6 / zoom)
    }

    /// The target of the link badge under `p`, front-most first.
    private func badgeHit(_ p: CGPoint) -> UUID? {
        linkBadges.last { b in
            let c = badgeCenter(b)
            return hypot(p.x - c.x, p.y - c.y) <= 10 / zoom
        }?.target
    }

    private func drawLinkBadges(_ ctx: CGContext, accent: NSColor) {
        let badges = linkBadges
        guard !badges.isEmpty else { return }
        let r = 8 / zoom, a = 3 / zoom
        ctx.setLineWidth(1.5 / zoom)
        ctx.setStrokeColor(NSColor.white.cgColor)
        for badge in badges {
            let c = badgeCenter(badge)
            ctx.setFillColor((badge.broken ? NSColor.systemGray : accent).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if badge.broken { // a cross: the target is gone or hidden
                ctx.move(to: CGPoint(x: c.x - a, y: c.y - a)); ctx.addLine(to: CGPoint(x: c.x + a, y: c.y + a))
                ctx.move(to: CGPoint(x: c.x - a, y: c.y + a)); ctx.addLine(to: CGPoint(x: c.x + a, y: c.y - a))
            } else { // an arrow pointing up and right
                ctx.move(to: CGPoint(x: c.x - a, y: c.y + a)); ctx.addLine(to: CGPoint(x: c.x + a, y: c.y - a))
                ctx.move(to: CGPoint(x: c.x - a / 3, y: c.y - a)); ctx.addLine(to: CGPoint(x: c.x + a, y: c.y - a))
                ctx.addLine(to: CGPoint(x: c.x + a, y: c.y + a / 3))
            }
            ctx.strokePath()
        }
        ctx.setStrokeColor(accent.cgColor)
    }

    /// The in-place text editor while one is open, readable by tests.
    var textEditor: NSTextField? { editor }

    /// Pan and zoom, readable by tests.
    var viewport: (pan: CGPoint, zoom: CGFloat) { (pan, zoom) }

    /// The part of the view the drawing shows through (the rulers cover the top and left edges).
    private var canvasArea: CGRect {
        let inset = showRulers ? rulerSize : 0
        return CGRect(x: inset, y: inset, width: bounds.width - inset, height: bounds.height - inset)
    }

    /// Follows a link: brings `target` (with its group) to the middle of the view, zooming out if it does not
    /// fit and in to at most 100% when the view was further out. A target on another page switches to that
    /// page first. Beeps and stays put on a broken link.
    @discardableResult
    func jump(to target: UUID, animated: Bool = true) -> Bool {
        let from = here
        if model.linkBounds(to: target) == nil, let page = findPage?(target), page != model.id {
            onShowPage?(page)
        }
        guard let b = model.linkBounds(to: target) else { NSSound.beep(); return false }
        stopJumpAnimation()
        backStack.append(from)
        if backStack.count > 50 { backStack.removeFirst() }
        forwardStack = []
        let area = canvasArea, margin: CGFloat = 60
        let fit = min((area.width - 2 * margin) / max(b.width, 1), (area.height - 2 * margin) / max(b.height, 1))
        let z = min(max(min(fit, max(zoom, 1)), zoomRange.lowerBound), zoomRange.upperBound)
        show(Viewport(pan: CGPoint(x: area.midX - b.midX * z, y: area.midY - b.midY * z), zoom: z), animated: animated)
        flashIDs = model.expandingGroups([target])
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.flashToken == token { self?.flashIDs = [] }
        }
        return true
    }

    private func stopJumpAnimation() { jumpTimer?.invalidate(); jumpTimer = nil }

    private func show(_ dest: Viewport, animated: Bool) {
        stopJumpAnimation()
        guard animated, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            zoom = dest.zoom; pan = dest.pan
            return
        }
        // Glide the model point at the middle of the view, and the zoom by a constant ratio per step.
        let mid = CGPoint(x: canvasArea.midX, y: canvasArea.midY)
        let from = Viewport(pan: pan, zoom: zoom)
        func center(_ v: Viewport) -> CGPoint { CGPoint(x: (mid.x - v.pan.x) / v.zoom, y: (mid.y - v.pan.y) / v.zoom) }
        let c0 = center(from), c1 = center(dest)
        let began = Date()
        jumpTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return } // the canvas went away mid-glide
            MainActor.assumeIsolated {
                let t = min(Date().timeIntervalSince(began) / 0.3, 1)
                let k = t * t * (3 - 2 * t)
                let z = from.zoom * pow(dest.zoom / from.zoom, k)
                self.zoom = z
                self.pan = CGPoint(x: mid.x - (c0.x + (c1.x - c0.x) * k) * z, y: mid.y - (c0.y + (c1.y - c0.y) * k) * z)
                if t >= 1 { self.zoom = dest.zoom; self.pan = dest.pan; self.stopJumpAnimation() }
            }
        }
    }

    // Menu commands (View ▸ Follow Link, Back, Forward) arrive through the responder chain.

    @objc func followLink(_ sender: Any?) {
        guard let target = model.elements.first(where: { selection.contains($0.id) && $0.link != nil })?.link else { NSSound.beep(); return }
        jump(to: target)
    }

    @objc func jumpBack(_ sender: Any?) { step(from: &backStack, to: &forwardStack, animated: true) }
    @objc func jumpForward(_ sender: Any?) { step(from: &forwardStack, to: &backStack, animated: true) }

    @discardableResult
    func jumpBack(animated: Bool) -> Bool { step(from: &backStack, to: &forwardStack, animated: animated) }
    @discardableResult
    func jumpForward(animated: Bool) -> Bool { step(from: &forwardStack, to: &backStack, animated: animated) }

    @discardableResult
    private func step(from: inout [Viewport], to: inout [Viewport], animated: Bool) -> Bool {
        guard let dest = from.popLast() else { NSSound.beep(); return false }
        to.append(here)
        flashIDs = []
        var animated = animated
        if let page = dest.page, page != model.id {
            onShowPage?(page)
            guard model.id == page else { NSSound.beep(); return false } // the page was deleted
            animated = false
        }
        show(dest, animated: animated)
        return true
    }

    private var singleSelectionID: UUID? { selection.count == 1 ? selection.first : nil }

    private func handle(at p: CGPoint) -> (UUID, Handle, CGRect)? {
        guard let id = singleSelectionID, let e = model.elements.first(where: { $0.id == id }), e.kind != .connector else { return nil }
        let box = e.frame.insetBy(dx: -4, dy: -4)
        let local = e.unrotated(p)
        for h in Handle.all {
            let c = h.point(in: box)
            if abs(local.x - c.x) <= hs, abs(local.y - c.y) <= hs { return (id, h, e.frame) }
        }
        return nil
    }

    /// Canvas position of the rotation knob: above the top edge, in the element's rotated frame.
    private func rotationKnob(for e: Element) -> CGPoint {
        e.rotated(CGPoint(x: e.frame.midX, y: e.frame.minY - 4 - 24 / zoom))
    }

    /// For a multi-selection: its bounds (padded) and the rotation knob above them.
    private func groupRotationKnob() -> (CGRect, CGPoint)? {
        guard tool == .select || tool == .rectangle || tool == .ellipse || tool == .diamond || tool == .text || tool == .note,
              selection.count >= 2 else { return nil }
        let b = model.selectionBounds(selection)
        guard !b.isNull else { return nil }
        let box = b.insetBy(dx: -6, dy: -6)
        return (box, CGPoint(x: box.midX, y: box.minY - 24 / zoom))
    }

    private func rotationHit(_ p: CGPoint) -> UUID? {
        guard let id = singleSelectionID, let e = model.elements.first(where: { $0.id == id }), e.kind != .connector else { return nil }
        let k = rotationKnob(for: e)
        return hypot(p.x - k.x, p.y - k.y) <= hs ? id : nil
    }

    /// Eraser reach in model units; constant on screen at any zoom.
    private var eraserRadius: CGFloat { 9 / zoom }

    /// Control point of the single selected pen stroke under `p`.
    private func strokePointHit(_ p: CGPoint) -> (UUID, Int)? {
        guard let id = singleSelectionID, let e = model.elements.first(where: { $0.id == id }),
              let cp = e.strokeControlPoints else { return nil }
        // Anchors win over handles when they overlap.
        let order = cp.indices.sorted { ($0 % 3 == 0 ? 0 : 1) < ($1 % 3 == 0 ? 0 : 1) }
        for i in order where hypot(p.x - cp[i].x, p.y - cp[i].y) <= 7 / zoom { return (id, i) }
        return nil
    }

    // MARK: Viewport

    private func point(_ event: NSEvent) -> CGPoint {
        let raw = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (raw.x - pan.x) / zoom, y: (raw.y - pan.y) / zoom)
    }

    private func viewportChanged() {
        needsDisplay = true
        layoutEditor()
    }

    /// Where an element's text is edited, matching where the renderer draws it: a connector's label at the
    /// middle of its route, a shape's label inside a 6pt inset, a text box's text across its frame, a note's
    /// Markdown source inside its padding.
    private func editFrame(for e: Element) -> CGRect {
        switch e.kind {
        case .connector: Renderer.labelRect(for: e, in: model)
        case .text: e.frame
        case .note: Note.textRect(e.frame)
        default: e.frame.insetBy(dx: 6, dy: 6)
        }
    }

    /// Sizes the text editor to its text and, except in a text box or note, centers it vertically in the edit
    /// frame, so typing happens where the label will be drawn.
    private func layoutEditor() {
        guard let field = editor, let id = editingID, let e = model.elements.first(where: { $0.id == id }) else { return }
        field.font = NSFont(name: "Helvetica Neue", size: e.style.fontSize * zoom)
        let box = viewFrame(editFrame(for: e))
        guard e.kind != .text, e.kind != .note, let cell = field.cell else { field.frame = box; return }
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: box.width, height: .greatestFiniteMagnitude)).height
        field.frame = NSRect(x: box.minX, y: box.midY - height / 2, width: box.width, height: height)
    }

    func controlTextDidChange(_ obj: Notification) { layoutEditor() }

    private func viewFrame(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom + pan.x, y: r.minY * zoom + pan.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// Zooms keeping the model point under `anchor` (view coords) fixed.
    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        stopJumpAnimation()
        let new = min(max(zoom * factor, zoomRange.lowerBound), zoomRange.upperBound)
        let m = CGPoint(x: (anchor.x - pan.x) / zoom, y: (anchor.y - pan.y) / zoom)
        zoom = new
        pan = CGPoint(x: anchor.x - m.x * new, y: anchor.y - m.y * new)
    }

    /// Selects everything on visible, unlocked layers. Also reachable from Edit ▸ Select All.
    @objc override func selectAll(_ sender: Any?) {
        let editable = Set(model.layers.filter { $0.visible && !$0.locked }.map(\.id))
        selection = Set(model.elements.filter { editable.contains($0.layerID) }.map(\.id))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), window?.firstResponder === self,
              let ch = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        switch ch {
        case "a" where !event.modifierFlags.contains(.shift): selectAll(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // Menu commands (View ▸ Zoom, Edit ▸ Delete) arrive through the responder chain.

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1.25, at: CGPoint(x: bounds.midX, y: bounds.midY)) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: 0.8, at: CGPoint(x: bounds.midX, y: bounds.midY)) }
    @objc func zoomActualSize(_ sender: Any?) { stopJumpAnimation(); zoom = 1; pan = .zero }

    @objc func delete(_ sender: Any?) { deleteSelection() }

    @objc func copy(_ sender: Any?) {
        guard let data = model.clipboardData(for: selection) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        pasteStep = 0
        lastPasteChangeCount = pb.changeCount
    }

    @objc func cut(_ sender: Any?) { copy(sender); deleteSelection(actionName: "Cut") }

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: Self.pasteboardType) else { return }
        // Repeated pastes of the same clipboard step diagonally instead of stacking.
        pasteStep = pb.changeCount == lastPasteChangeCount ? pasteStep + 1 : 1
        lastPasteChangeCount = pb.changeCount
        let step = Double(pasteStep) * 16
        var next = model
        let added = next.paste(data, offset: CGPoint(x: step, y: step), keepsLink: { [elementExists] in elementExists?($0) ?? false })
        guard !added.isEmpty else { return }
        selection = added
        onCommit?(next, "Paste")
    }

    // MARK: Importing SVG

    /// Readable size for an import: small icons grow, huge exports shrink, anything else is untouched.
    private func importScale(for size: CGSize) -> Double {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return 1 }
        if longest < 64 { return 96 / longest }
        if longest > 480 { return 480 / longest }
        return 1
    }

    /// Places each SVG, in a row starting at `center`, as one undo step. Returns false if none could be read.
    @discardableResult
    func importSVGs(_ files: [Data], at center: CGPoint, keepOriginalColors: Bool) -> Bool {
        let usable = model.layers.filter { !$0.locked && $0.visible }
        guard let layer = usable.first(where: { $0.id == activeLayerID }) ?? usable.first else { return false }
        var next = model
        var added = Set<UUID>()
        var x = center.x
        for data in files {
            var options = SVGImporter.Options()
            options.keepOriginalColors = keepOriginalColors
            guard let probe = try? SVGImporter.importElements(from: data, layerID: layer.id, options: options) else { continue }
            options.scale = importScale(for: probe.size)
            guard let art = try? SVGImporter.importElements(from: data, layerID: layer.id, options: options) else { continue }
            let at = CGPoint(x: x + art.size.width / 2, y: center.y)
            added.formUnion(next.insert(art.elements, size: art.size, center: at, layerID: layer.id))
            x += art.size.width + 24
        }
        guard !added.isEmpty else { NSSound.beep(); return false }
        selection = added
        tool = .select
        onToolChange?(.select)
        onCommit?(next, "Import SVG")
        return true
    }

    /// Model coordinates of the middle of what is on screen.
    private var viewportCenter: CGPoint {
        CGPoint(x: (bounds.midX - pan.x) / zoom, y: (bounds.midY - pan.y) / zoom)
    }

    @objc func importSVG(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.allowsMultipleSelection = true
        panel.message = "Choose SVG files to place on the canvas"
        let keep = NSButton(checkboxWithTitle: "Keep original colors", target: nil, action: nil)
        keep.state = .off
        panel.accessoryView = keep
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK else { return }
        let files = panel.urls.compactMap { try? Data(contentsOf: $0) }
        let half = files.count > 1 ? CGFloat(files.count - 1) * 120 : 0
        importSVGs(files, at: CGPoint(x: viewportCenter.x - half, y: viewportCenter.y), keepOriginalColors: keep.state == .on)
    }

    /// Places a whole imported scene at its own size (no readable-icon scaling), as one undo step.
    @discardableResult
    private func placeScene(_ item: StencilItem, keepOriginalColors: Bool, actionName: String, at center: CGPoint) -> Bool {
        let usable = model.layers.filter { !$0.locked && $0.visible }
        guard let layer = usable.first(where: { $0.id == activeLayerID }) ?? usable.first else { return false }
        var next = model
        let added = next.insert(item.placed(keepOriginalColors: keepOriginalColors), size: item.size, center: center, layerID: layer.id)
        guard !added.isEmpty else { NSSound.beep(); return false }
        selection = added
        tool = .select
        onToolChange?(.select)
        onCommit?(next, actionName)
        return true
    }

    /// Places an Excalidraw scene as authored.
    @discardableResult
    func importExcalidraw(_ data: Data, at center: CGPoint) -> Bool {
        guard let first = try? ExcalidrawImporter.importItems(from: data, layerID: UUID()).first else { NSSound.beep(); return false }
        let item = StencilItem(name: "Excalidraw", width: first.size.width, height: first.size.height,
                               elements: first.elements, imported: false)
        return placeScene(item, keepOriginalColors: true, actionName: "Import Excalidraw", at: center)
    }

    /// Places the first page of a draw.io file, restyled to this drawing's look unless `keepOriginalColors`.
    @discardableResult
    func importDrawio(_ data: Data, at center: CGPoint, keepOriginalColors: Bool) -> Bool {
        guard let first = try? DrawioImporter.importItems(from: data, layerID: UUID()).first else { NSSound.beep(); return false }
        let item = StencilItem(name: first.name, width: first.size.width, height: first.size.height,
                               elements: first.elements, imported: true)
        return placeScene(item, keepOriginalColors: keepOriginalColors, actionName: "Import draw.io", at: center)
    }

    @objc func importDrawioFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["drawio", "xml"].compactMap { UTType(filenameExtension: $0) } + [.xml]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a draw.io diagram (.drawio)"
        let keep = NSButton(checkboxWithTitle: "Keep original colors and clean lines", target: nil, action: nil)
        keep.state = .off
        panel.accessoryView = keep
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        importDrawio(data, at: viewportCenter, keepOriginalColors: keep.state == .on)
    }

    @objc func importExcalidrawScene(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "excalidraw") ?? .json, .json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Excalidraw scene (.excalidraw)"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        importExcalidraw(data, at: viewportCenter)
    }

    // Dropping .svg files from Finder places them under the cursor; hold ⌥ to keep original colors.

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType(DraggedStencil.typeIdentifier)])
    }

    private func draggedStencil(_ info: NSDraggingInfo) -> DraggedStencil? {
        guard let data = info.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(DraggedStencil.typeIdentifier))
        else { return nil }
        return try? JSONDecoder().decode(DraggedStencil.self, from: data)
    }

    /// Puts a stencil on the canvas centered at `center` (the view's middle by default), as one undo step.
    @discardableResult
    func placeStencil(_ item: StencilItem, keepOriginalColors: Bool, at center: CGPoint? = nil) -> Bool {
        let usable = model.layers.filter { !$0.locked && $0.visible }
        guard let layer = usable.first(where: { $0.id == activeLayerID }) ?? usable.first else { return false }
        var next = model
        let added = next.place(item, center: center ?? viewportCenter, layerID: layer.id, keepOriginalColors: keepOriginalColors)
        guard !added.isEmpty else { return false }
        selection = added
        tool = .select
        onToolChange?(.select)
        onCommit?(next, "Place \(item.name)")
        return true
    }

    private func droppedFiles(_ info: NSDraggingInfo, ext: String) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == ext }
    }

    private func droppedSVGs(_ info: NSDraggingInfo) -> [URL] { droppedFiles(info, ext: "svg") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedStencil(sender) != nil || !droppedSVGs(sender).isEmpty || !droppedFiles(sender, ext: "excalidraw").isEmpty
            || !droppedFiles(sender, ext: "drawio").isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let dragged = draggedStencil(sender) {
            let raw = convert(sender.draggingLocation, from: nil)
            let at = CGPoint(x: (raw.x - pan.x) / zoom, y: (raw.y - pan.y) / zoom)
            return placeStencil(dragged.item, keepOriginalColors: dragged.keepOriginalColors, at: at)
        }
        if let scene = droppedFiles(sender, ext: "excalidraw").first, let data = try? Data(contentsOf: scene) {
            let raw = convert(sender.draggingLocation, from: nil)
            return importExcalidraw(data, at: CGPoint(x: (raw.x - pan.x) / zoom, y: (raw.y - pan.y) / zoom))
        }
        if let scene = droppedFiles(sender, ext: "drawio").first, let data = try? Data(contentsOf: scene) {
            let raw = convert(sender.draggingLocation, from: nil)
            return importDrawio(data, at: CGPoint(x: (raw.x - pan.x) / zoom, y: (raw.y - pan.y) / zoom),
                                keepOriginalColors: NSEvent.modifierFlags.contains(.option))
        }
        let files = droppedSVGs(sender).compactMap { try? Data(contentsOf: $0) }
        guard !files.isEmpty else { return false }
        let raw = convert(sender.draggingLocation, from: nil)
        let at = CGPoint(x: (raw.x - pan.x) / zoom, y: (raw.y - pan.y) / zoom)
        return importSVGs(files, at: at, keepOriginalColors: NSEvent.modifierFlags.contains(.option))
    }

    @objc func duplicate(_ sender: Any?) {
        guard editor == nil, !selection.isEmpty else { return } // ⌘D while typing a label must not clone the shape
        var next = model
        let added = next.duplicate(selection)
        selection = added
        onCommit?(next, "Duplicate")
    }

    // MARK: Context menu

    /// Right-clicking a shape selects it (with its group) unless it is already selected; empty canvas clears the selection.
    override func menu(for event: NSEvent) -> NSMenu? {
        endEditing()
        linkSources = nil
        if let hit = spatial.element(at: point(event), in: model) {
            if !selection.contains(hit.id) { selection = model.expandingGroups([hit.id]) }
        } else {
            selection = []
        }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        add("Cut", #selector(cut(_:)))
        add("Copy", #selector(copy(_:)))
        add("Paste", #selector(paste(_:)))
        add("Duplicate", #selector(duplicate(_:)))
        add("Delete", #selector(delete(_:)))
        menu.addItem(.separator())
        add("Link to Element…", #selector(linkToElement(_:)))
        add("Follow Link", #selector(followLink(_:)))
        add("Remove Link", #selector(removeLink(_:)))
        menu.addItem(.separator())
        add("Bring to Front", #selector(bringToFront(_:)))
        add("Send to Back", #selector(sendToBack(_:)))
        add("Group", #selector(groupSelection(_:)))
        add("Ungroup", #selector(ungroupSelection(_:)))
        return menu
    }

    private var selectionHasLink: Bool { model.elements.contains { selection.contains($0.id) && $0.link != nil } }

    /// Waits for a click on the shape the selection should link to.
    @objc func linkToElement(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        if tool != .select { switchTool(.select) }
        linkSources = selection
        linkSourcePage = model.id
    }

    @objc func removeLink(_ sender: Any?) {
        var next = model
        guard (try? next.setLink(selection, to: nil)) != nil, next != model else { return }
        onCommit?(next, "Remove Link")
    }

    private func edit(_ name: String, _ change: (inout DottieDocument) -> Void) {
        var next = model
        change(&next)
        if next != model { onCommit?(next, name) }
    }

    @objc func bringToFront(_ sender: Any?) { let ids = selection; edit("Arrange") { $0.reorder(ids, .toFront) } }
    @objc func sendToBack(_ sender: Any?) { let ids = selection; edit("Arrange") { $0.reorder(ids, .toBack) } }
    @objc func groupSelection(_ sender: Any?) { let ids = selection; edit("Group") { $0.group(ids) } }
    @objc func ungroupSelection(_ sender: Any?) { let ids = selection; edit("Ungroup") { $0.ungroup(ids) } }

    /// Ends Link to Element… with a click at `p`: a shape outside the sources gets the link; empty canvas cancels;
    /// a connector or one of the sources beeps and keeps waiting.
    private func finishLink(at p: CGPoint) {
        guard let sources = linkSources else { return }
        guard let hit = spatial.element(at: p, in: model) else { linkSources = nil; return }
        guard hit.kind != .connector, !sources.contains(hit.id) else { NSSound.beep(); return }
        let sourcePage = linkSourcePage
        linkSources = nil
        if let sourcePage, sourcePage != model.id {
            // Picked on another page: link there, then go back to where the links start.
            guard onLinkOtherPage?(sources, sourcePage, hit.id) == true else { NSSound.beep(); return }
            onShowPage?(sourcePage)
            selection = sources.intersection(model.elements.map(\.id))
            return
        }
        var next = model
        guard (try? next.setLink(sources, to: hit.id)) != nil else { NSSound.beep(); return }
        onCommit?(next, "Link")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(linkToElement(_:)), #selector(bringToFront(_:)), #selector(sendToBack(_:)):
            return !selection.isEmpty
        case #selector(followLink(_:)), #selector(removeLink(_:)):
            return selectionHasLink
        case #selector(groupSelection(_:)):
            return model.expandingGroups(selection).count >= 2
        case #selector(ungroupSelection(_:)):
            return model.elements.contains { selection.contains($0.id) && $0.groupID != nil }
        case #selector(delete(_:)), #selector(copy(_:)), #selector(cut(_:)), #selector(duplicate(_:)):
            return !selection.isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.data(forType: Self.pasteboardType) != nil
        default: return true
        }
    }

    private func deleteSelection(actionName: String = "Delete") {
        guard !selection.isEmpty else { return }
        var next = model
        next.remove(selection)
        selection = []
        onCommit?(next, actionName)
    }

    override func resetCursorRects() {
        if linkSources != nil, !spaceDown {
            addCursorRect(bounds, cursor: .crosshair)
        } else if spaceDown {
            addCursorRect(bounds, cursor: gesture.map { if case .panning = $0 { return true } else { return false } } == true ? .closedHand : .openHand)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { // ⌘ + wheel zooms around the cursor
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            zoom(by: exp(dy * 0.01), at: convert(event.locationInWindow, from: nil))
            return
        }
        stopJumpAnimation()
        pan = CGPoint(x: pan.x + event.scrollingDeltaX, y: pan.y + event.scrollingDeltaY)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false } else { super.keyUp(with: event) }
    }

    // MARK: Snapping

    private var snapToObjects: Bool { Pref.bool(Pref.snapToObjects, default: true) }
    private var gridSize: Double? {
        Pref.bool(Pref.snapToGrid, default: false) ? (UserDefaults.standard.object(forKey: Pref.gridSize) as? Double ?? Pref.gridSizeDefault) : nil
    }

    /// Grid-snaps a point unless ⌘ is held.
    private func snapped(_ p: CGPoint, _ event: NSEvent) -> CGPoint {
        guard let g = gridSize, !event.modifierFlags.contains(.command) else { return p }
        return CGPoint(x: Snap.grid(p.x, size: g), y: Snap.grid(p.y, size: g))
    }

    // MARK: Connector helpers

    /// Topmost non-connector shape under `p`.
    private func shape(at p: CGPoint, in doc: DottieDocument) -> Element? {
        doc.orderedElements.last { e in
            e.kind != .connector && e.frame.insetBy(dx: -6, dy: -6).contains(p)
                && doc.layers.first { $0.id == e.layerID }.map { $0.visible && !$0.locked } == true
        }
    }

    /// Binds to the shape under the cursor (snapping to a port when close), otherwise stays free.
    private func endpoint(at p: CGPoint, in doc: DottieDocument) -> Endpoint {
        guard let s = shape(at: p, in: doc) else { return .free(p) }
        return .bound(s.id, port: Connector.port(near: p, of: s))
    }

    private func connectorEndpointHit(_ p: CGPoint) -> (UUID, Bool)? {
        guard let id = singleSelectionID, let c = model.elements.first(where: { $0.id == id }), c.kind == .connector else { return nil }
        let (a, b) = Connector.endpoints(of: c, in: model)
        if hypot(p.x - a.x, p.y - a.y) <= 8 / zoom { return (id, true) }
        if hypot(p.x - b.x, p.y - b.y) <= 8 / zoom { return (id, false) }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        endEditing()
        stopJumpAnimation()
        window?.makeFirstResponder(self)
        if spaceDown {
            gesture = .panning
            panAnchor = (convert(event.locationInWindow, from: nil), pan)
            window?.invalidateCursorRects(for: self)
            return
        }
        if linkSources != nil { finishLink(at: point(event)); return }
        if showRulers {
            let raw = convert(event.locationInWindow, from: nil)
            let inTop = raw.y < rulerSize, inLeft = raw.x < rulerSize
            if inTop != inLeft, model.guidesLocked != true { // a drag from a ruler pulls out a guide (the corner does nothing)
                baseline = model
                var next = model
                let q = point(event)
                if inLeft { next.guidesX = (next.guidesX ?? []) + [q.x] } else { next.guidesY = (next.guidesY ?? []) + [q.y] }
                gesture = .guide(vertical: inLeft, index: (inLeft ? next.guidesX : next.guidesY)!.count - 1)
                model = next
                return
            }
        }
        var p = point(event)
        if tool.kind != nil, tool != .text, tool != .pencil { p = snapped(p, event) }
        dragStart = p
        if tool == .select, event.clickCount == 1, let target = badgeHit(p) { // a link badge: go there
            jump(to: target)
            return
        }
        baseline = model
        if showRulers, tool == .select, let hit = guideHit(p), handle(at: p) == nil, spatial.element(at: p, in: model) == nil {
            gesture = .guide(vertical: hit.vertical, index: hit.index)
            return
        }
        let usable = model.layers.filter { !$0.locked && $0.visible }
        guard let layer = usable.first(where: { $0.id == activeLayerID }) ?? usable.first else { return }

        if event.clickCount == 2, tool == .select, let hit = spatial.element(at: p, in: model) {
            selection = [hit.id]
            beginEditing(hit.id)
            gesture = nil
            return
        }

        if tool == .text {
            var e = Element(kind: .text, frame: CGRect(x: p.x, y: p.y, width: 180, height: 28), style: style, layerID: layer.id, text: "")
            e.style.roughness = 0
            model.elements.append(e)
            selection = [e.id]
            onPreview?(model)
            gesture = nil
            beginEditing(e.id, isNew: true)
            return
        }

        if tool == .eraser {
            gesture = .erasing
            eraseStep(at: p)
            return
        }
        if tool == .select, let (id, index) = strokePointHit(p) {
            gesture = .editingPoint(id: id, index: index)
            return
        }

        if tool == .connector {
            var st = style
            st.fill = .clear
            let c = ConnectorData(start: endpoint(at: p, in: model), end: .free(p), routing: routing)
            let e = Element(kind: .connector, frame: .zero, style: st, layerID: layer.id, connector: c)
            model.elements.append(e)
            selection = [e.id]
            hoverShapeID = shape(at: p, in: model)?.id
            gesture = .connecting(id: e.id)
            onPreview?(model)
        } else if tool == .select, let (id, isStart) = connectorEndpointHit(p) {
            gesture = .endpoint(id: id, isStart: isStart)
        } else if tool == .pencil {
            var st = style
            st.fill = .clear
            st.roughness = 0
            let e = Element(kind: .freehand, frame: CGRect(x: p.x, y: p.y, width: 1, height: 1), style: st, layerID: layer.id,
                            points: [StrokePoint(x: 0, y: 0)])
            strokePoints = [p]
            model.elements.append(e)
            selection = [e.id]
            gesture = .drawing(id: e.id)
            onPreview?(model)
        } else if let kind = tool.kind {
            let e = Element(kind: kind, frame: CGRect(origin: p, size: .zero), style: kind == .note ? Note.style(from: style) : style,
                            layerID: layer.id)
            gesture = .creating(e)
            model.elements.append(e)
            selection = [e.id]
            onPreview?(model)
        } else if tool == .select, let (box, knob) = groupRotationKnob(), hypot(p.x - knob.x, p.y - knob.y) <= hs {
            let c = CGPoint(x: box.midX, y: box.midY)
            gesture = .rotatingGroup(center: c, start: atan2(p.y - c.y, p.x - c.x))
        } else if tool == .select, let id = rotationHit(p) {
            gesture = .rotating(id: id)
        } else if let (id, h, frame) = handle(at: p) {
            gesture = .resizing(id: id, handle: h, original: frame)
        } else if let hit = spatial.element(at: p, in: model) {
            let hitSet = model.expandingGroups([hit.id])
            if event.modifierFlags.contains(.shift) {
                selection = selection.isSuperset(of: hitSet) ? selection.subtracting(hitSet) : selection.union(hitSet)
            } else if !selection.contains(hit.id) {
                selection = hitSet
            }
            pressedLink = tool == .select && event.modifierFlags.contains(.command) ? hit.link : nil
            gesture = .moving
        } else {
            if !event.modifierFlags.contains(.shift) { selection = [] }
            gesture = .marquee
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if case .panning? = gesture {
            let raw = convert(event.locationInWindow, from: nil)
            pan = CGPoint(x: panAnchor.pan.x + raw.x - panAnchor.raw.x, y: panAnchor.pan.y + raw.y - panAnchor.raw.y)
            return
        }
        if case .erasing? = gesture { eraseStep(at: point(event)); return }
        if case .guide(let vertical, let index)? = gesture {
            let q = point(event)
            var pos = vertical ? q.x : q.y
            if let g = gridSize, !event.modifierFlags.contains(.command) { pos = Snap.grid(pos, size: g) }
            var next = model
            setGuide(&next, vertical: vertical, index: index, to: pos)
            model = next
            return
        }
        guard let g = gesture, var next = baseline else { return }
        let p = snapped(point(event), event)
        var d = CGPoint(x: p.x - dragStart.x, y: p.y - dragStart.y)
        if case .moving = g {
            // Moving snaps the whole selection's bounds (objects first, then grid); ⌘ bypasses.
            d = CGPoint(x: point(event).x - dragStart.x, y: point(event).y - dragStart.y)
            guides = []; spacingGuides = []
            let layersOK = Set(next.layers.filter { $0.visible && !$0.locked }.map(\.id))
            let moving = next.elements.filter { selection.contains($0.id) && $0.kind != .connector }.map(\.rotatedBounds)
                .reduce(CGRect.null) { $0.union($1) }
            if !moving.isNull, !event.modifierFlags.contains(.command) {
                let others = next.elements.filter { !selection.contains($0.id) && $0.kind != .connector && layersOK.contains($0.layerID) }.map(\.rotatedBounds)
                let r = Snap.move(moving.offsetBy(dx: d.x, dy: d.y), others: snapToObjects ? others : [],
                                  threshold: 6 / zoom, gridSize: gridSize,
                                  guidesX: showRulers ? model.guidesX ?? [] : [], guidesY: showRulers ? model.guidesY ?? [] : [])
                d.x += r.dx; d.y += r.dy
                guides = r.guides
                spacingGuides = r.spacing
            }
        }

        switch g {
        case .creating(var e):
            e.frame = CGRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y), width: abs(d.x), height: abs(d.y))
            gesture = .creating(e)
            next.elements.append(e)
        case .moving:
            for i in next.elements.indices where selection.contains(next.elements[i].id) {
                if var c = next.elements[i].connector {
                    // Bound ends follow their shapes; only free ends move with the drag.
                    if c.start.elementID == nil { c.start.x += d.x; c.start.y += d.y }
                    if c.end.elementID == nil { c.end.x += d.x; c.end.y += d.y }
                    next.elements[i].connector = c
                } else {
                    next.elements[i].x += d.x; next.elements[i].y += d.y
                }
            }
        case .connecting(let id), .endpoint(let id, _):
            if let i = next.elements.firstIndex(where: { $0.id == id }) {
                let ep = endpoint(at: p, in: next)
                if case .endpoint(_, let isStart) = g, isStart { next.elements[i].connector?.start = ep }
                else { next.elements[i].connector?.end = ep }
            } else if let i = model.elements.firstIndex(where: { $0.id == id }) {
                // Newly created connector isn't in the baseline yet.
                var e = model.elements[i]
                e.connector?.end = endpoint(at: p, in: next)
                next.elements.append(e)
            }
            hoverShapeID = shape(at: p, in: next)?.id
        case .resizing(let id, let h, let original):
            if let i = next.elements.firstIndex(where: { $0.id == id }) {
                if let grid = gridSize, !event.modifierFlags.contains(.command) {
                    // Snap only the edges this handle moves.
                    if h.hx < 0 { d.x = Snap.grid(original.minX + d.x, size: grid) - original.minX }
                    if h.hx > 0 { d.x = Snap.grid(original.maxX + d.x, size: grid) - original.maxX }
                    if h.hy < 0 { d.y = Snap.grid(original.minY + d.y, size: grid) - original.minY }
                    if h.hy > 0 { d.y = Snap.grid(original.maxY + d.y, size: grid) - original.maxY }
                }
                let angle = next.elements[i].angle
                if angle != 0 { d = Element.rotate(d, about: .zero, by: -angle) } // drag in the shape's own axes
                var f = h.resized(original, by: d)
                f.size.width = max(f.width, 4); f.size.height = max(f.height, 4)
                guides = []; spacingGuides = []
                if angle == 0, snapToObjects, !event.modifierFlags.contains(.command) {
                    let ok = Set(next.layers.filter { $0.visible && !$0.locked }.map(\.id))
                    let others = next.elements.filter { $0.id != id && $0.kind != .connector && ok.contains($0.layerID) }.map(\.rotatedBounds)
                    let r = Snap.resize(f, hx: h.hx, hy: h.hy, others: others, threshold: 6 / zoom,
                                        guidesX: showRulers ? model.guidesX ?? [] : [], guidesY: showRulers ? model.guidesY ?? [] : [])
                    if h.hx < 0 { f.origin.x += r.dx; f.size.width -= r.dx }
                    if h.hx > 0 { f.size.width += r.dx }
                    if h.hy < 0 { f.origin.y += r.dy; f.size.height -= r.dy }
                    if h.hy > 0 { f.size.height += r.dy }
                    f.size.width = max(f.width, 4); f.size.height = max(f.height, 4)
                    guides = r.guides
                }
                if angle != 0 {
                    // Keep the opposite corner fixed on the canvas.
                    f = Element.reanchored(f, original: original, angle: angle,
                                           fx: h.hx < 0 ? 1 : h.hx > 0 ? 0 : 0.5, fy: h.hy < 0 ? 1 : h.hy > 0 ? 0 : 0.5)
                }
                next.elements[i].frame = f
            }
        case .panning, .erasing, .guide:
            return
        case .rotating(let id):
            if let i = next.elements.firstIndex(where: { $0.id == id }) {
                let f = next.elements[i].frame
                let q = point(event)
                var a = atan2(q.y - f.midY, q.x - f.midX) + .pi / 2
                // Snap to 15° steps: always with Shift, otherwise when within 3° of one.
                let step = Double.pi / 12
                let near = (a / step).rounded() * step
                if event.modifierFlags.contains(.shift) || abs(a - near) < .pi / 60 { a = near }
                a = a.truncatingRemainder(dividingBy: 2 * .pi)
                next.elements[i].rotation = abs(a) < 1e-9 ? nil : a
            }
        case .rotatingGroup(let center, let start):
            let q = point(event)
            var delta = atan2(q.y - center.y, q.x - center.x) - start
            let step = Double.pi / 12
            let near = (delta / step).rounded() * step
            if event.modifierFlags.contains(.shift) || abs(delta - near) < .pi / 60 { delta = near }
            next.rotate(selection, by: delta, about: center)
        case .editingPoint(let id, let index):
            if let i = next.elements.firstIndex(where: { $0.id == id }) {
                next.elements[i].moveStrokeControlPoint(index, to: point(event))
            }
        case .drawing(let id):
            let p = point(event) // freehand never grid-snaps
            if let last = strokePoints.last, hypot(p.x - last.x, p.y - last.y) < 1 / zoom { return }
            strokePoints.append(p)
            let xs = strokePoints.map(\.x), ys = strokePoints.map(\.y)
            let frame = CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 1), height: max(ys.max()! - ys.min()!, 1))
            if let i = model.elements.firstIndex(where: { $0.id == id }) {
                var e = model.elements[i]
                e.frame = frame
                e.points = strokePoints.map { StrokePoint(x: ($0.x - frame.minX) / frame.width, y: ($0.y - frame.minY) / frame.height) }
                next.elements.append(e)
            }
        case .marquee:
            let r = CGRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y), width: abs(d.x), height: abs(d.y))
            marqueeRect = r
            selection = next.expandingGroups(Set(spatial.elements(intersecting: r, in: model)))
            needsDisplay = true
            return
        }
        model = next
        onPreview?(next)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil; baseline = nil; marqueeRect = nil; hoverShapeID = nil; pressedLink = nil; guides = []; spacingGuides = []; strokePoints = []; needsDisplay = true
            if spaceDown { window?.invalidateCursorRects(for: self) }
        }
        guard let base = baseline, let g = gesture else { return }
        switch g {
        case .creating(let e):
            if e.kind == .note { // a click places a default-size note; either way, start typing in it
                if let i = model.elements.firstIndex(where: { $0.id == e.id }),
                   model.elements[i].width < 3 && model.elements[i].height < 3 {
                    model.elements[i].frame.size = DiagramOps.defaultSize(for: .note, text: "")
                }
                onPreview?(model)
                beginEditing(e.id, isNew: true)
                return
            }
            if e.width < 3 && e.height < 3 { // accidental click
                model = base; selection = []; onPreview?(base); return
            }
            commit(base, "Add Shape")
        case .connecting(let id):
            if let e = model.elements.first(where: { $0.id == id }), let c = e.connector,
               c.start.elementID == nil, c.end.elementID == nil,
               hypot(c.end.x - c.start.x, c.end.y - c.start.y) < 6 { // accidental click
                model = base; selection = []; onPreview?(base); return
            }
            commit(base, "Add Connector")
        case .drawing(let id):
            if strokePoints.count < 2 { model = base; selection = []; onPreview?(base); return }
            if let i = model.elements.firstIndex(where: { $0.id == id }) { model.elements[i].fitStroke() }
            commit(base, "Draw")
        case .guide(let vertical, let index):
            // Dropping a guide back on its ruler removes it.
            let raw = convert(event.locationInWindow, from: nil)
            if vertical ? raw.x < rulerSize : raw.y < rulerSize {
                var next = model
                if vertical { if next.guidesX?.indices.contains(index) == true { next.guidesX?.remove(at: index) } }
                else if next.guidesY?.indices.contains(index) == true { next.guidesY?.remove(at: index) }
                if next.guidesX?.isEmpty == true { next.guidesX = nil }
                if next.guidesY?.isEmpty == true { next.guidesY = nil }
                model = next
            }
            if model != base {
                let before = (base.guidesX?.count ?? 0) + (base.guidesY?.count ?? 0)
                let after = (model.guidesX?.count ?? 0) + (model.guidesY?.count ?? 0)
                commit(base, after > before ? "Add Guide" : after < before ? "Remove Guide" : "Move Guide")
            }
        case .erasing where model != base: commit(base, "Erase")
        case .editingPoint where model != base: commit(base, "Edit Stroke")
        case .rotating where model != base: commit(base, "Rotate")
        case .rotatingGroup where model != base: commit(base, "Rotate")
        case .endpoint where model != base: commit(base, "Move Connector End")
        case .moving where model != base: commit(base, "Move")
        case .moving: if let target = pressedLink { jump(to: target) } // ⌘-click on a linked shape
        case .resizing where model != base: commit(base, "Resize")
        default: break
        }
    }

    /// One eraser dab. Applied to the live model so a sweep accumulates; undo sees the whole sweep as one step.
    private func eraseStep(at p: CGPoint) {
        var next = model
        guard next.erase(at: p, radius: eraserRadius) else { return }
        selection = selection.filter { id in next.elements.contains { $0.id == id } }
        model = next
        onPreview?(next)
    }

    private func switchTool(_ t: Tool) {
        if t != .select { linkSources = nil }
        tool = t
        onToolChange?(t)
        if t != .select, t != .connector { hoverShapeID = nil }
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if event.keyCode == 49, plain { // space: hold to pan
            if !event.isARepeat { spaceDown = true }
            return
        }
        if event.keyCode == 53, linkSources != nil { linkSources = nil; return } // escape cancels Link to Element…
        if event.keyCode == 53 { // escape: back to the arrow; a second press clears the selection
            if tool != .select { switchTool(.select) } else { selection = [] }
            return
        }
        if plain, Pref.bool(Pref.singleKeyShortcuts, default: true),
           let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let t = Tool.allCases.first(where: { $0.shortcut == ch }) {
            switchTool(t)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117, !selection.isEmpty { // delete / forward delete
            deleteSelection()
        } else if event.keyCode == 36, let id = singleSelectionID { // return edits text
            beginEditing(id)
        } else {
            super.keyDown(with: event)
        }
    }

    /// Resets the document to the pre-gesture baseline, then commits so undo lands there.
    private func commit(_ base: DottieDocument, _ name: String) {
        let final = model
        onPreview?(base)
        onCommit?(final, name)
    }

    // MARK: In-place text editing

    private func beginEditing(_ id: UUID, isNew: Bool = false) {
        guard let e = model.elements.first(where: { $0.id == id }) else { return }
        endEditing()
        let field = NSTextField(frame: viewFrame(editFrame(for: e)))
        field.stringValue = e.text ?? ""
        field.isBordered = false
        field.focusRingType = .none
        field.alignment = e.kind == .text || e.kind == .note ? .left : .center
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.backgroundColor = canvasBackground
        // The ink the label is drawn in: a dark label on a light fill even when the canvas ink is light.
        let ink = nsColor(e.resolvingInk(to: canvasInk).style.stroke)
        field.textColor = ink
        field.drawsBackground = e.kind == .connector
        field.delegate = self
        addSubview(field)
        editor = field
        editingID = id
        editBase = isNew ? baseline : nil
        layoutEditor()
        window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.insertionPointColor = ink
        needsDisplay = true
    }

    /// `deferCommit` is for a page switch, which happens during a SwiftUI update that must not change the document.
    private func endEditing(deferCommit: Bool = false) {
        guard let field = editor, let id = editingID else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        editor = nil; editingID = nil
        needsDisplay = true
        guard let i = model.elements.firstIndex(where: { $0.id == id }) else { return }
        var next = model
        let kind = next.elements[i].kind
        // Empty text boxes disappear, and so does a note left empty as it was placed (one emptied later stays).
        if text.isEmpty && (kind == .text || (kind == .note && editBase != nil)) {
            next.elements.remove(at: i)
            selection = []
        } else {
            next.elements[i].text = text
            if next.elements[i].kind == .text {
                // Grow the box to fit the text.
                let w = (text as NSString).size(withAttributes: [.font: NSFont(name: "Helvetica Neue", size: next.elements[i].style.fontSize) ?? .systemFont(ofSize: 18)]).width + 12
                next.elements[i].width = max(next.elements[i].width, ceil(w))
            }
        }
        let base = editBase
        editBase = nil
        let name = base != nil && kind == .note ? "Add Note" : "Edit Text"
        if deferCommit {
            DispatchQueue.main.async { [weak self] in self?.commitEdit(next, base: base, name: name) }
        } else {
            commitEdit(next, base: base, name: name)
        }
        window?.makeFirstResponder(self)
    }

    private func commitEdit(_ next: DottieDocument, base: DottieDocument?, name: String) {
        if let base { onPreview?(base) }
        if next == base { return } // a new box or note left empty: nothing to undo
        onCommit?(next, name)
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }

    /// Escape inside the text editor finishes editing and returns to the arrow. In a note, Return starts a
    /// new line, since Markdown needs them; Escape or clicking away finishes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let id = editingID,
           model.elements.first(where: { $0.id == id })?.kind == .note {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endEditing()
        switchTool(.select)
        return true
    }
}

struct CanvasView: NSViewRepresentable {
    @ObservedObject var document: DrawingDocument
    @Binding var tool: Tool
    @Binding var selection: Set<UUID>
    var style: Style
    var routing: Routing
    var activeLayerID: UUID?
    @Binding var placeRequest: PlaceRequest?
    var showRulers = false
    @Binding var jumpRequest: JumpRequest?
    @Environment(\.undoManager) private var undoManager

    func makeNSView(context: Context) -> CanvasNSView {
        let v = CanvasNSView()
        v.onPreview = { [document] in document.preview($0) }
        v.onToolChange = { t in DispatchQueue.main.async { tool = t } }
        v.onSelectionChange = { sel in DispatchQueue.main.async { selection = sel } }
        v.onShowPage = { [document, weak v] page in
            guard document.file.index(of: page) != nil else { return }
            document.currentPageID = page
            v?.model = document.model
        }
        v.findPage = { [document] id in document.linkTargetPages[id] }
        v.elementExists = { [document] id in document.file.pageIndex(containing: id) != nil }
        return v
    }

    func updateNSView(_ v: CanvasNSView, context: Context) {
        v.onCommit = { [document, undoManager] new, name in document.commit(new, actionName: name, undoManager: undoManager) }
        v.onLinkOtherPage = { [document, undoManager] sources, page, target in
            var next = document.file
            guard let i = next.index(of: page),
                  (try? next.pages[i].setLink(sources, to: target, otherPages: next.pages)) != nil else { return false }
            document.commitFile(next, actionName: "Link", undoManager: undoManager)
            return true
        }
        if v.model != document.model { v.model = document.model }
        if v.fileRevision != document.revision { v.fileRevision = document.revision; v.linksElsewhereChanged() }
        v.tool = tool
        v.style = style
        v.routing = routing
        v.activeLayerID = activeLayerID
        v.showRulers = showRulers
        if v.selection != selection { v.selection = selection }
        if let req = placeRequest, v.handledPlace != req.id {
            v.handledPlace = req.id
            // Applying it changes the model and bindings, so do it after this update pass.
            DispatchQueue.main.async {
                v.placeStencil(req.item, keepOriginalColors: req.keepOriginalColors)
                if placeRequest == req { placeRequest = nil }
            }
        }
        if let req = jumpRequest, v.handledJump != req.id {
            v.handledJump = req.id
            DispatchQueue.main.async {
                v.jump(to: req.target)
                if jumpRequest == req { jumpRequest = nil }
            }
        }
    }
}
