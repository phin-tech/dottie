import AppKit
import DottieKit

/// The tool chosen in the toolbar, named by the id its `CanvasTool` is registered under. A plain value, so the
/// toolbar, the Tools menu and the canvas can all bind to it.
struct Tool: Hashable, Identifiable, Sendable {
    let id: String

    static let select = Tool(id: "select")
    static let rectangle = Tool(id: "rectangle")
    static let ellipse = Tool(id: "ellipse")
    static let diamond = Tool(id: "diamond")
    static let text = Tool(id: "text")
    static let note = Tool(id: "note")
    static let connector = Tool(id: "connector")
    static let pencil = Tool(id: "pencil")
    static let highlighter = Tool(id: "highlighter")
    static let eraser = Tool(id: "eraser")
    static let redact = Tool(id: "redact")

    /// Every registered tool, in toolbar order.
    @MainActor static var all: [Tool] { CanvasTools.registered.map(\.tool) }

    /// What the tool does on the canvas.
    @MainActor var behavior: any CanvasTool { CanvasTools.behavior(of: self) }
    @MainActor var symbol: String { behavior.symbol }
    @MainActor var label: String { behavior.label }
    @MainActor var shortcut: Character? { behavior.shortcut }
}

/// A drawing tool: how it shows in the toolbar, and what a press on the canvas does with it. A press usually starts
/// one of the canvas's gestures (`CanvasGesture`), which the canvas carries through the drag and the release, so
/// tools that draw alike (the shape tools) share them. A tool that runs its own gesture starts `.tool`, and the canvas
/// hands it the drag and the release.
@MainActor
protocol CanvasTool {
    var tool: Tool { get }
    /// An SF Symbol name for the toolbar.
    var symbol: String { get }
    var label: String { get }
    /// The key that picks the tool, Photoshop-style; nil for none (extension tools).
    var shortcut: Character? { get }
    /// Whether the press point snaps to the grid before `press` sees it.
    var snapsPress: Bool { get }
    /// Whether the selection's own controls show and take presses: adjustment handles, stroke control points, a
    /// posed camera's view.
    var editsSelection: Bool { get }
    /// Whether a multi-selection's rotation knob shows.
    var showsGroupRotation: Bool { get }
    /// Handles a press at `p` (in model points, snapped when `snapsPress`), after the canvas has dealt with panning,
    /// pending links and the rulers.
    func press(_ canvas: CanvasNSView, at p: CGPoint, event: NSEvent)
    /// A step of the drag, while the tool's own `.tool` gesture runs.
    func drag(_ canvas: CanvasNSView, to p: CGPoint, event: NSEvent)
    /// The release that ends the tool's own `.tool` gesture. The canvas clears the gesture afterwards.
    func release(_ canvas: CanvasNSView, at p: CGPoint, event: NSEvent)
}

extension CanvasTool {
    var shortcut: Character? { nil }
    func drag(_ canvas: CanvasNSView, to p: CGPoint, event: NSEvent) {}
    func release(_ canvas: CanvasNSView, at p: CGPoint, event: NSEvent) {}
    var snapsPress: Bool { false }
    var editsSelection: Bool { false }
    var showsGroupRotation: Bool { false }
}

/// The registered tools: the built-in ones, then each loaded extension's. A new built-in tool is one more
/// `CanvasTool` type and one more entry in `builtIn`.
@MainActor
enum CanvasTools {
    static var registered: [any CanvasTool] {
        builtIn + ExtensionHost.shared.runtimes.flatMap { rt in rt.tools.map { ExtensionTool(runtime: rt, definition: $0) } }
    }

    static let builtIn: [any CanvasTool] = [
        SelectTool(),
        ShapeTool(tool: .rectangle, kind: .rectangle, symbol: "rectangle", label: "Rectangle", shortcut: "r"),
        ShapeTool(tool: .ellipse, kind: .ellipse, symbol: "circle", label: "Ellipse", shortcut: "o"),
        ShapeTool(tool: .diamond, kind: .diamond, symbol: "diamond", label: "Diamond", shortcut: "d"),
        TextTool(),
        ShapeTool(tool: .note, kind: .note, symbol: "note.text", label: "Note", shortcut: "n"),
        ConnectorTool(),
        PencilTool(tool: .pencil, symbol: "pencil.tip", label: "Pencil", shortcut: "p"),
        PencilTool(tool: .highlighter, symbol: "highlighter", label: "Highlighter", shortcut: "h"),
        EraserTool(),
        RedactTool(),
    ]

    static func behavior(of tool: Tool) -> any CanvasTool {
        registered.first { $0.tool == tool } ?? builtIn[0]
    }
}

/// Picks, moves, resizes and rotates; follows link badges and ticks note checkboxes; double-click edits text.
struct SelectTool: CanvasTool {
    let tool = Tool.select
    let symbol = "cursorarrow", label = "Select"
    let shortcut: Character? = "v"
    var editsSelection: Bool { true }
    var showsGroupRotation: Bool { true }

    func press(_ c: CanvasNSView, at p: CGPoint, event: NSEvent) {
        if event.clickCount == 1, let target = c.badgeHit(p) { // a link badge: go there
            c.follow(target)
            return
        }
        if event.clickCount == 1, c.toggleCheckbox(at: p) { return }
        let layer = c.startPress()
        if c.showRulers, let hit = c.guideHit(p), c.handle(at: p) == nil, c.spatial.element(at: p, in: c.model, skipping: c.hiddenInEditor) == nil {
            c.gesture = .guide(vertical: hit.vertical, index: hit.index)
            return
        }
        guard layer != nil else { return }
        let hit = c.spatial.element(at: p, in: c.model, skipping: c.hiddenInEditor)
        if event.clickCount == 2, let hit {
            c.selection = [hit.id]
            if hit.kind == .symbol { c.gesture = nil; c.onEditSymbol?(hit.id); return }
            c.beginEditing(hit.id)
            c.gesture = nil
            return
        }
        if let (id, index) = c.strokePointHit(p) {
            c.gesture = .editingPoint(id: id, index: index)
        } else if let (id, isStart) = c.connectorEndpointHit(p) {
            c.gesture = .endpoint(id: id, isStart: isStart)
        } else if let (box, knob) = c.groupRotationKnob(), hypot(p.x - knob.x, p.y - knob.y) <= c.hs {
            let center = CGPoint(x: box.midX, y: box.midY)
            c.gesture = .rotatingGroup(center: center, start: atan2(p.y - center.y, p.x - center.x))
        } else if let id = c.rotationHit(p) {
            c.gesture = .rotating(id: id)
        } else if let (id, h, frame) = c.handle(at: p) {
            c.gesture = .resizing(id: id, handle: h, original: frame)
        } else if let (id, handleID) = c.adjustmentHit(p) {
            c.gesture = .adjusting(id: id, handle: handleID)
        } else if let hit {
            let hitSet = c.model.expandingGroups([hit.id])
            if event.modifierFlags.contains(.shift) {
                c.selection = c.selection.isSuperset(of: hitSet) ? c.selection.subtracting(hitSet) : c.selection.union(hitSet)
            } else if !c.selection.contains(hit.id) {
                c.selection = hitSet
            }
            c.pressedLink = event.modifierFlags.contains(.command) ? LinkGoal(hit) : nil
            c.gesture = .moving
        } else {
            if !event.modifierFlags.contains(.shift) { c.selection = [] }
            c.gesture = .marquee
        }
    }
}

/// Drags out a rectangle, ellipse, diamond or note; a click places a note at its default size.
struct ShapeTool: CanvasTool {
    let tool: Tool
    let kind: ElementKind
    let symbol: String, label: String
    let shortcut: Character?
    var snapsPress: Bool { true }
    var showsGroupRotation: Bool { true }

    func press(_ c: CanvasNSView, at p: CGPoint, event: NSEvent) {
        guard let layer = c.startPress() else { return }
        let e = Element(kind: kind, frame: CGRect(origin: p, size: .zero), style: kind == .note ? Note.style(from: c.style) : c.style,
                        layerID: layer)
        c.gesture = .creating(e)
        c.model.elements.append(e)
        c.selection = [e.id]
        c.onPreview?(c.model)
    }
}

/// A click starts a text box and types into it.
struct TextTool: CanvasTool {
    let tool = Tool.text
    let symbol = "textformat", label = "Text"
    let shortcut: Character? = "t"
    var showsGroupRotation: Bool { true }

    func press(_ c: CanvasNSView, at p: CGPoint, event: NSEvent) {
        guard let layer = c.startPress() else { return }
        var e = Element(kind: .text, frame: CGRect(x: p.x, y: p.y, width: 180, height: 28), style: c.style, layerID: layer, text: "")
        e.style.roughness = 0
        c.model.elements.append(e)
        c.selection = [e.id]
        c.onPreview?(c.model)
        c.gesture = nil
        c.beginEditing(e.id, isNew: true)
        c.returnToSelectIfWanted()
    }
}

/// Drags an arrow from the shape under the press (or from a free point) to wherever it is let go.
struct ConnectorTool: CanvasTool {
    let tool = Tool.connector
    let symbol = "arrow.up.right", label = "Connector"
    let shortcut: Character? = "c"

    func press(_ c: CanvasNSView, at p: CGPoint, event: NSEvent) {
        guard let layer = c.startPress() else { return }
        var st = c.style
        st.fill = .clear
        let data = ConnectorData(start: c.endpoint(at: p, in: c.model), end: .free(p), routing: c.routing)
        let e = Element(kind: .connector, frame: .zero, style: st, layerID: layer, connector: data)
        c.model.elements.append(e)
        c.selection = [e.id]
        c.hoverShapeID = c.shape(at: p, in: c.model)?.id
        c.gesture = .connecting(id: e.id)
        c.onPreview?(c.model)
    }
}

/// Draws a freehand stroke: in the current style for the pencil, or in a wide translucent one for the highlighter.
struct PencilTool: CanvasTool {
    let tool: Tool
    let symbol: String, label: String
    let shortcut: Character?

    func press(_ c: CanvasNSView, at p: CGPoint, event: NSEvent) {
        guard let layer = c.startPress() else { return }
        var st = tool == .highlighter ? CanvasNSView.highlighterStyle : c.style
        st.fill = .clear
        st.roughness = 0
        let e = Element(kind: .freehand, frame: CGRect(x: p.x, y: p.y, width: 1, height: 1), style: st, layerID: layer,
                        points: [StrokePoint(x: 0, y: 0)])
        c.strokePoints = [p]
        c.model.elements.append(e)
        c.selection = [e.id]
        c.gesture = .drawing(id: e.id)
        c.onPreview?(c.model)
    }
}

/// Rubs out what it passes over, as one undo step per sweep.
struct EraserTool: CanvasTool {
    let tool = Tool.eraser
    let symbol = "eraser", label = "Eraser"
    let shortcut: Character? = "e"

    func press(_ c: CanvasNSView, at p: CGPoint, event: NSEvent) {
        guard c.startPress() != nil else { return }
        c.gesture = .erasing
        c.eraseStep(at: p)
    }
}

/// Drags a box over pictures to pixelate what it covers.
struct RedactTool: CanvasTool {
    let tool = Tool.redact
    let symbol = "eye.slash", label = "Redact"
    let shortcut: Character? = "x"

    func press(_ c: CanvasNSView, at p: CGPoint, event: NSEvent) {
        guard c.startPress() != nil else { return }
        if c.poseTime != nil { c.gesture = nil; return NSSound.beep() } // a pose keys motion, not pictures
        c.gesture = .redacting
    }
}

/// A drawing tool from an extension. Its `draw` runs on the press, on every step of the drag and on the release,
/// each time from the page as it was at the press, so the preview never piles up; what it returns on release is
/// added as one undo step. Nothing it draws refers back to the extension.
struct ExtensionTool: CanvasTool {
    let runtime: ExtensionRuntime
    let definition: ToolDefinition

    var tool: Tool { Tool(id: "\(runtime.manifest.id)/\(definition.id)") }
    var label: String { definition.name }
    var symbol: String {
        guard let icon = definition.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil else { return "wand.and.stars" }
        return icon
    }

    func press(_ c: CanvasNSView, at p: CGPoint, event: NSEvent) {
        guard let layer = c.startPress() else { return }
        c.strokePoints = [p]
        c.gesture = .tool(tool, layer: layer, seed: .random(in: 1...UInt32.max))
        show(c, event: event, done: false)
    }

    func drag(_ c: CanvasNSView, to p: CGPoint, event: NSEvent) {
        if let last = c.strokePoints.last, hypot(p.x - last.x, p.y - last.y) < 1 / c.viewport.zoom { return }
        c.strokePoints.append(p)
        show(c, event: event, done: false)
    }

    func release(_ c: CanvasNSView, at p: CGPoint, event: NSEvent) {
        if c.strokePoints.last != p { c.strokePoints.append(p) }
        guard let base = c.baseline, let added = show(c, event: event, done: true) else { return }
        guard !added.isEmpty else { c.model = base; c.onPreview?(base); return }
        c.selection = Set(added)
        c.commit(base, definition.name)
    }

    /// Draws the gesture so far over the page as it was at the press, and returns the new elements' ids. When `draw`
    /// fails, the page goes back to how it was, the gesture ends and the error goes to the Script Console.
    @discardableResult
    private func show(_ c: CanvasNSView, event: NSEvent, done: Bool) -> [UUID]? {
        guard let base = c.baseline, case .tool(_, let layer, let seed)? = c.gesture else { return nil }
        let gesture = ToolGesture(points: c.strokePoints, done: done, shift: event.modifierFlags.contains(.shift),
                                  option: event.modifierFlags.contains(.option))
        defer { ExtensionHost.shared.flushLogs() }
        do {
            let drawn = try DrawnElement.elements(try runtime.draw(tool: definition.id, gesture), style: c.style, layerID: layer, seed: seed)
            var next = base
            next.elements += drawn
            c.model = next
            c.onPreview?(next)
            return drawn.map(\.id)
        } catch {
            c.gesture = nil
            c.model = base
            c.onPreview?(base)
            ExtensionHost.report("\(runtime.manifest.name): \(definition.name): \(ExtensionHost.message(error))")
            return nil
        }
    }
}
