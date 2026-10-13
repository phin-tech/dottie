import AppKit
import SwiftUI
import DottieKit

enum Tool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, diamond, text
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .diamond: "diamond"
        case .text: "textformat"
        }
    }
    var kind: ElementKind? {
        switch self {
        case .select: nil
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .diamond: .diamond
        case .text: .text
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
}

/// Core Graphics canvas. Model coordinates are top-left origin, so the view is flipped.
final class CanvasNSView: NSView, NSTextFieldDelegate {
    var model = DottieDocument() { didSet { needsDisplay = true } }
    var tool: Tool = .select
    var selection: Set<UUID> = [] { didSet { needsDisplay = true; onSelectionChange?(selection) } }
    var style = Style()

    var onPreview: ((DottieDocument) -> Void)?
    var onCommit: ((DottieDocument, String) -> Void)?
    var onSelectionChange: ((Set<UUID>) -> Void)?

    private var gesture: Gesture?
    private var dragStart: CGPoint = .zero
    private var baseline: DottieDocument?
    private var marqueeRect: CGRect?
    private var editor: NSTextField?
    private var editingID: UUID?
    private var editBase: DottieDocument? // set for new text so undo removes the box entirely

    private let handleSize: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        Renderer.draw(model, in: ctx)

        let accent = NSColor.controlAccentColor
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5)
        for e in model.elements where selection.contains(e.id) {
            ctx.stroke(e.frame.insetBy(dx: -4, dy: -4))
        }
        if let id = singleSelectionID, let e = model.elements.first(where: { $0.id == id }) {
            ctx.setFillColor(NSColor.white.cgColor)
            for h in Handle.all {
                let p = h.point(in: e.frame.insetBy(dx: -4, dy: -4))
                let r = CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize)
                ctx.fill(r); ctx.stroke(r)
            }
        }
        if let m = marqueeRect {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(m)
            ctx.setLineWidth(1); ctx.stroke(m)
        }
    }

    private var singleSelectionID: UUID? { selection.count == 1 ? selection.first : nil }

    private func handle(at p: CGPoint) -> (UUID, Handle, CGRect)? {
        guard let id = singleSelectionID, let e = model.elements.first(where: { $0.id == id }) else { return nil }
        let box = e.frame.insetBy(dx: -4, dy: -4)
        for h in Handle.all {
            let c = h.point(in: box)
            if abs(p.x - c.x) <= handleSize, abs(p.y - c.y) <= handleSize { return (id, h, e.frame) }
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        endEditing()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        baseline = model
        guard let layer = model.layers.first(where: { !$0.locked && $0.visible }) else { return }

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

        if let kind = tool.kind {
            let e = Element(kind: kind, frame: CGRect(origin: p, size: .zero), style: style, layerID: layer.id)
            gesture = .creating(e)
            model.elements.append(e)
            selection = [e.id]
            onPreview?(model)
        } else if let (id, h, frame) = handle(at: p) {
            gesture = .resizing(id: id, handle: h, original: frame)
        } else if let hit = model.element(at: p) {
            if event.modifierFlags.contains(.shift) {
                selection.formSymmetricDifference([hit.id])
            } else if !selection.contains(hit.id) {
                selection = [hit.id]
            }
            gesture = .moving
        } else {
            if !event.modifierFlags.contains(.shift) { selection = [] }
            gesture = .marquee
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let g = gesture, var next = baseline else { return }
        let p = convert(event.locationInWindow, from: nil)
        let d = CGPoint(x: p.x - dragStart.x, y: p.y - dragStart.y)

        switch g {
        case .creating(var e):
            e.frame = CGRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y), width: abs(d.x), height: abs(d.y))
            gesture = .creating(e)
            next.elements.append(e)
        case .moving:
            for i in next.elements.indices where selection.contains(next.elements[i].id) {
                next.elements[i].x += d.x; next.elements[i].y += d.y
            }
        case .resizing(let id, let h, let original):
            if let i = next.elements.firstIndex(where: { $0.id == id }) {
                var f = h.resized(original, by: d)
                f.size.width = max(f.width, 4); f.size.height = max(f.height, 4)
                next.elements[i].frame = f
            }
        case .marquee:
            let r = CGRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y), width: abs(d.x), height: abs(d.y))
            marqueeRect = r
            selection = Set(next.elements.filter { r.intersects($0.frame) }.map(\.id))
            needsDisplay = true
            return
        }
        model = next
        onPreview?(next)
    }

    override func mouseUp(with event: NSEvent) {
        defer { gesture = nil; baseline = nil; marqueeRect = nil; needsDisplay = true }
        guard let base = baseline, let g = gesture else { return }
        switch g {
        case .creating(let e):
            if e.width < 3 && e.height < 3 { // accidental click
                model = base; selection = []; onPreview?(base); return
            }
            commit(base, "Add Shape")
        case .moving where model != base: commit(base, "Move")
        case .resizing where model != base: commit(base, "Resize")
        default: break
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, !selection.isEmpty { // delete / forward delete
            var next = model
            next.elements.removeAll { selection.contains($0.id) }
            selection = []
            onCommit?(next, "Delete")
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
        let field = NSTextField(frame: e.frame)
        field.stringValue = e.text ?? ""
        field.font = NSFont(name: "Helvetica Neue", size: e.style.fontSize)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = e.kind == .text ? .left : .center
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
}

struct CanvasView: NSViewRepresentable {
    @ObservedObject var document: DrawingDocument
    @Binding var tool: Tool
    @Binding var selection: Set<UUID>
    var style: Style
    @Environment(\.undoManager) private var undoManager

    func makeNSView(context: Context) -> CanvasNSView {
        let v = CanvasNSView()
        v.onPreview = { [document] in document.preview($0) }
        v.onSelectionChange = { sel in DispatchQueue.main.async { selection = sel } }
        return v
    }

    func updateNSView(_ v: CanvasNSView, context: Context) {
        v.onCommit = { [document, undoManager] new, name in document.commit(new, actionName: name, undoManager: undoManager) }
        if v.model != document.model { v.model = document.model }
        v.tool = tool
        v.style = style
        if v.selection != selection { v.selection = selection }
    }
}
