import AppKit
import SwiftUI
import DottieKit

enum Tool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, diamond
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .diamond: "diamond"
        }
    }
    var kind: ElementKind? {
        switch self {
        case .select: nil
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .diamond: .diamond
        }
    }
}

/// Core Graphics canvas. Model coordinates are top-left origin, so the view is flipped.
final class CanvasNSView: NSView {
    var model = DottieDocument() { didSet { needsDisplay = true } }
    var tool: Tool = .select
    var selection: Set<UUID> = [] { didSet { needsDisplay = true; onSelectionChange?(selection) } }
    var style = Style()

    var onPreview: ((DottieDocument) -> Void)?
    var onCommit: ((DottieDocument, String) -> Void)?
    var onSelectionChange: ((Set<UUID>) -> Void)?

    private var dragStart: CGPoint?
    private var baseline: DottieDocument?
    private var creating: Element?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        Renderer.draw(model, in: ctx)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        for e in model.elements where selection.contains(e.id) {
            ctx.stroke(e.frame.insetBy(dx: -4, dy: -4))
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        baseline = model
        guard let layer = model.layers.first(where: { !$0.locked }) else { return }

        if let kind = tool.kind {
            let e = Element(kind: kind, frame: CGRect(origin: p, size: .zero), style: style, layerID: layer.id)
            creating = e
            model.elements.append(e)
            selection = [e.id]
            onPreview?(model)
        } else if let hit = model.element(at: p) {
            if !selection.contains(hit.id) { selection = event.modifierFlags.contains(.shift) ? selection.union([hit.id]) : [hit.id] }
        } else {
            selection = []
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, var next = baseline else { return }
        let p = convert(event.locationInWindow, from: nil)
        if var e = creating {
            e.frame = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            creating = e
            next.elements.append(e)
        } else {
            let dx = p.x - start.x, dy = p.y - start.y
            for i in next.elements.indices where selection.contains(next.elements[i].id) {
                next.elements[i].x += dx; next.elements[i].y += dy
            }
        }
        model = next
        onPreview?(next)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; baseline = nil; creating = nil }
        guard let base = baseline else { return }
        if let e = creating {
            // Discard accidental zero-size clicks.
            if e.width < 3 && e.height < 3 {
                model = base; selection = []; onPreview?(base); return
            }
            commit(base, "Add Shape")
        } else if model != base {
            commit(base, "Move")
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, !selection.isEmpty { // delete / forward delete
            var next = model
            next.elements.removeAll { selection.contains($0.id) }
            selection = []
            onCommit?(next, "Delete")
        } else {
            super.keyDown(with: event)
        }
    }

    /// Restores the document's baseline then commits `model` so undo returns to the pre-gesture state.
    private func commit(_ base: DottieDocument, _ name: String) {
        let final = model
        onPreview?(base)
        onCommit?(final, name)
    }
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
