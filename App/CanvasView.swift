import AppKit
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
    case select, rectangle, ellipse, diamond, text, connector, pencil, eraser
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .diamond: "diamond"
        case .text: "textformat"
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
        case .connector: nil
        case .pencil: .freehand
        case .eraser: nil
        }
    }
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
}

/// Core Graphics canvas. Model coordinates are top-left origin, so the view is flipped.
final class CanvasNSView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    var model = DottieDocument() {
        didSet { needsDisplay = true; spatialStale = true }
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

    private let handleSize: CGFloat = 8
    /// Handle size in model units so handles stay the same size on screen at any zoom.
    private var hs: CGFloat { handleSize / zoom }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)
        // Only what the dirty rectangle shows, in model units, found through the spatial index.
        let visible = CGRect(x: (dirtyRect.minX - pan.x) / zoom, y: (dirtyRect.minY - pan.y) / zoom,
                             width: dirtyRect.width / zoom, height: dirtyRect.height / zoom)
        Renderer.draw(model, in: ctx, background: NSColor.textBackgroundColor.cgColor, clip: visible,
                      zoom: Double(zoom), ink: isDark ? .inkOnDark : .black, spatial: spatial)

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
        if let m = marqueeRect {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(m)
            ctx.setLineWidth(1 / zoom); ctx.stroke(m)
        }
        ctx.restoreGState()

        if zoom != 1 {
            let label = "\(Int((zoom * 100).rounded()))%" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: bounds.maxX - size.width - 12, y: bounds.maxY - size.height - 8), withAttributes: attrs)
        }
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

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
        guard tool == .select || tool == .rectangle || tool == .ellipse || tool == .diamond || tool == .text,
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
        guard let f = editor, let id = editingID, let e = model.elements.first(where: { $0.id == id }) else { return }
        f.frame = viewFrame(editFrame(for: e))
        f.font = NSFont(name: "Helvetica Neue", size: e.style.fontSize * zoom)
    }

    /// Where an element's text is edited: a connector's label sits at the middle of its route.
    private func editFrame(for e: Element) -> CGRect {
        e.kind == .connector ? Renderer.labelRect(for: e, in: model) : e.frame
    }

    private func viewFrame(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom + pan.x, y: r.minY * zoom + pan.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// Zooms keeping the model point under `anchor` (view coords) fixed.
    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
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
    @objc func zoomActualSize(_ sender: Any?) { zoom = 1; pan = .zero }

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
        let added = next.paste(data, offset: CGPoint(x: step, y: step))
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

    private func droppedSVGs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "svg" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedStencil(sender) != nil || !droppedSVGs(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let dragged = draggedStencil(sender) {
            let raw = convert(sender.draggingLocation, from: nil)
            let at = CGPoint(x: (raw.x - pan.x) / zoom, y: (raw.y - pan.y) / zoom)
            return placeStencil(dragged.item, keepOriginalColors: dragged.keepOriginalColors, at: at)
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
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
        if spaceDown {
            addCursorRect(bounds, cursor: gesture.map { if case .panning = $0 { return true } else { return false } } == true ? .closedHand : .openHand)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { // ⌘ + wheel zooms around the cursor
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            zoom(by: exp(dy * 0.01), at: convert(event.locationInWindow, from: nil))
            return
        }
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
        window?.makeFirstResponder(self)
        if spaceDown {
            gesture = .panning
            panAnchor = (convert(event.locationInWindow, from: nil), pan)
            window?.invalidateCursorRects(for: self)
            return
        }
        var p = point(event)
        if tool.kind != nil, tool != .text, tool != .pencil { p = snapped(p, event) }
        dragStart = p
        baseline = model
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
            let e = Element(kind: kind, frame: CGRect(origin: p, size: .zero), style: style, layerID: layer.id)
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
                                  threshold: 6 / zoom, gridSize: gridSize)
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
                    let r = Snap.resize(f, hx: h.hx, hy: h.hy, others: others, threshold: 6 / zoom)
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
        case .panning, .erasing:
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
            gesture = nil; baseline = nil; marqueeRect = nil; hoverShapeID = nil; guides = []; spacingGuides = []; strokePoints = []; needsDisplay = true
            if spaceDown { window?.invalidateCursorRects(for: self) }
        }
        guard let base = baseline, let g = gesture else { return }
        switch g {
        case .creating(let e):
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
        case .erasing where model != base: commit(base, "Erase")
        case .editingPoint where model != base: commit(base, "Edit Stroke")
        case .rotating where model != base: commit(base, "Rotate")
        case .rotatingGroup where model != base: commit(base, "Rotate")
        case .endpoint where model != base: commit(base, "Move Connector End")
        case .moving where model != base: commit(base, "Move")
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
        field.font = NSFont(name: "Helvetica Neue", size: e.style.fontSize * zoom)
        field.isBordered = false
        field.focusRingType = .none
        field.alignment = e.kind == .text ? .left : .center
        field.backgroundColor = .textBackgroundColor
        field.drawsBackground = e.kind == .connector
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        editor = field
        editingID = id
        editBase = isNew ? baseline : nil
    }

    private func endEditing() {
        guard let field = editor, let id = editingID else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        editor = nil; editingID = nil
        guard let i = model.elements.firstIndex(where: { $0.id == id }) else { return }
        var next = model
        if next.elements[i].kind == .text && text.isEmpty {
            next.elements.remove(at: i) // empty text boxes disappear
            selection = []
        } else {
            next.elements[i].text = text
            if next.elements[i].kind == .text {
                // Grow the box to fit the text.
                let w = (text as NSString).size(withAttributes: [.font: NSFont(name: "Helvetica Neue", size: next.elements[i].style.fontSize) ?? .systemFont(ofSize: 18)]).width + 12
                next.elements[i].width = max(next.elements[i].width, ceil(w))
            }
        }
        if let base = editBase { onPreview?(base); editBase = nil }
        onCommit?(next, "Edit Text")
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }

    /// Escape inside the text editor finishes editing and returns to the arrow.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
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
    @Environment(\.undoManager) private var undoManager

    func makeNSView(context: Context) -> CanvasNSView {
        let v = CanvasNSView()
        v.onPreview = { [document] in document.preview($0) }
        v.onToolChange = { t in DispatchQueue.main.async { tool = t } }
        v.onSelectionChange = { sel in DispatchQueue.main.async { selection = sel } }
        return v
    }

    func updateNSView(_ v: CanvasNSView, context: Context) {
        v.onCommit = { [document, undoManager] new, name in document.commit(new, actionName: name, undoManager: undoManager) }
        if v.model != document.model { v.model = document.model }
        v.tool = tool
        v.style = style
        v.routing = routing
        v.activeLayerID = activeLayerID
        if v.selection != selection { v.selection = selection }
        if let req = placeRequest {
            // Applying it changes the model and bindings, so do it after this update pass.
            DispatchQueue.main.async {
                v.placeStencil(req.item, keepOriginalColors: req.keepOriginalColors)
                if placeRequest == req { placeRequest = nil }
            }
        }
    }
}
