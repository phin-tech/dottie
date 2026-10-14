import AppKit
import SwiftUI
import DottieKit

enum Tool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, diamond, text, connector, pencil
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
}

/// Core Graphics canvas. Model coordinates are top-left origin, so the view is flipped.
final class CanvasNSView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    var model = DottieDocument() { didSet { needsDisplay = true } }
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
        Renderer.draw(model.resolvingInk(to: isDark ? .inkOnDark : .black), in: ctx, background: NSColor.textBackgroundColor.cgColor)

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
                ctx.stroke(e.frame.insetBy(dx: -4, dy: -4))
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
                let p = h.point(in: e.frame.insetBy(dx: -4, dy: -4))
                let r = CGRect(x: p.x - hs / 2, y: p.y - hs / 2, width: hs, height: hs)
                ctx.fill(r); ctx.stroke(r)
            }
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
        for h in Handle.all {
            let c = h.point(in: box)
            if abs(p.x - c.x) <= hs, abs(p.y - c.y) <= hs { return (id, h, e.frame) }
        }
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

        if event.clickCount == 2, tool == .select, let hit = model.element(at: p) {
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
        } else if let (id, h, frame) = handle(at: p) {
            gesture = .resizing(id: id, handle: h, original: frame)
        } else if let hit = model.element(at: p) {
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
        guard let g = gesture, var next = baseline else { return }
        let p = snapped(point(event), event)
        var d = CGPoint(x: p.x - dragStart.x, y: p.y - dragStart.y)
        if case .moving = g {
            // Moving snaps the whole selection's bounds (objects first, then grid); ⌘ bypasses.
            d = CGPoint(x: point(event).x - dragStart.x, y: point(event).y - dragStart.y)
            guides = []
            let layersOK = Set(next.layers.filter { $0.visible && !$0.locked }.map(\.id))
            let moving = next.elements.filter { selection.contains($0.id) && $0.kind != .connector }.map(\.frame)
                .reduce(CGRect.null) { $0.union($1) }
            if !moving.isNull, !event.modifierFlags.contains(.command) {
                let others = next.elements.filter { !selection.contains($0.id) && $0.kind != .connector && layersOK.contains($0.layerID) }.map(\.frame)
                let r = Snap.move(moving.offsetBy(dx: d.x, dy: d.y), others: snapToObjects ? others : [],
                                  threshold: 6 / zoom, gridSize: gridSize)
                d.x += r.dx; d.y += r.dy
                guides = r.guides
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
                var f = h.resized(original, by: d)
                f.size.width = max(f.width, 4); f.size.height = max(f.height, 4)
                next.elements[i].frame = f
            }
        case .panning:
            return
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
            selection = next.expandingGroups(Set(next.elements.filter { r.intersects($0.frame) }.map(\.id)))
            needsDisplay = true
            return
        }
        model = next
        onPreview?(next)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil; baseline = nil; marqueeRect = nil; hoverShapeID = nil; guides = []; strokePoints = []; needsDisplay = true
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
        case .endpoint where model != base: commit(base, "Move Connector End")
        case .moving where model != base: commit(base, "Move")
        case .resizing where model != base: commit(base, "Resize")
        default: break
        }
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
    }
}
