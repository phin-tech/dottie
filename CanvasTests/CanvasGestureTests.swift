import XCTest
import AppKit
import DottieKit

/// Drives the real `CanvasNSView` with synthesized mouse events, the same calls AppKit makes, so the
/// gesture wiring (hit order, snapping, commit-once-per-gesture) is exercised and not just the math.
@MainActor
final class CanvasGestureTests: XCTestCase {
    var window: NSWindow!
    var view: CanvasNSView!
    var commits: [(doc: DottieDocument, name: String)] = []
    var layer = UUID()

    override func setUp() async throws {
        UserDefaults.standard.set(false, forKey: Pref.snapToGrid)
        UserDefaults.standard.set(true, forKey: Pref.snapToObjects)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                          backing: .buffered, defer: false)
        view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = view
        view.model = DottieDocument()
        layer = view.model.layers[0].id
        commits = []
        // Mirror what CanvasView's coordinator does: previews and commits both replace the view's model.
        view.onPreview = { [unowned self] d in view.model = d }
        view.onCommit = { [unowned self] d, name in commits.append((d, name)); view.model = d }
    }

    // MARK: Helpers

    func add(_ kind: ElementKind, _ frame: CGRect, rotation: Double? = nil, text: String? = nil) -> Element {
        var st = Style(); st.roughness = 0
        var e = Element(kind: kind, frame: frame, style: st, layerID: layer, text: text)
        e.rotation = rotation
        view.model.elements.append(e)
        return e
    }

    func element(_ id: UUID) -> Element { view.model.elements.first { $0.id == id }! }

    func stroke(from a: CGPoint, to b: CGPoint, wobble: Double = 0) -> Element {
        let raw = (0...200).map { i -> CGPoint in
            let t = Double(i) / 200
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + wobble * sin(t * 9))
        }
        let xs = raw.map(\.x), ys = raw.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 1), height: max(ys.max()! - ys.min()!, 1))
        var st = Style(); st.roughness = 0; st.fill = .clear
        var e = Element(kind: .freehand, frame: box, style: st, layerID: layer,
                        points: raw.map { StrokePoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) })
        e.fitStroke()
        view.model.elements.append(e)
        return e
    }

    func event(_ type: NSEvent.EventType, _ p: CGPoint, mods: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: mods, timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func drag(_ a: CGPoint, _ b: CGPoint, steps: Int = 10, mods: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: event(.leftMouseDown, a, mods: mods))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), mods: mods))
        }
        view.mouseUp(with: event(.leftMouseUp, b, mods: mods))
    }

    func knob(of e: Element) -> CGPoint { e.rotated(CGPoint(x: e.frame.midX, y: e.frame.minY - 4 - 24)) }

    /// Canvas point at `angle` radians clockwise from "up" at distance `r` from `c`.
    func around(_ c: CGPoint, angle: Double, r: Double = 200) -> CGPoint {
        CGPoint(x: c.x + r * cos(angle - .pi / 2), y: c.y + r * sin(angle - .pi / 2))
    }

    // MARK: Rotation

    func testKnobRotatesTheSelectedShapeInOneUndoStep() {
        let e = add(.rectangle, CGRect(x: 300, y: 300, width: 200, height: 100))
        view.selection = [e.id]
        let c = CGPoint(x: 400, y: 350)
        drag(knob(of: e), around(c, angle: .pi / 2))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].name, "Rotate")
        XCTAssertEqual(element(e.id).angle, .pi / 2, accuracy: 1e-6)
        XCTAssertEqual(element(e.id).frame, e.frame) // rotating about the center doesn't move the frame
    }

    func testShiftSnapsRotationToFifteenDegrees() {
        let e = add(.rectangle, CGRect(x: 300, y: 300, width: 200, height: 100))
        view.selection = [e.id]
        let c = CGPoint(x: 400, y: 350)
        drag(knob(of: e), around(c, angle: 20 * .pi / 180), mods: .shift)
        XCTAssertEqual(element(e.id).angle, .pi / 12, accuracy: 1e-6)
    }

    func testRotatingBackToZeroClearsTheAngle() {
        let e = add(.rectangle, CGRect(x: 300, y: 300, width: 200, height: 100), rotation: .pi / 2)
        view.selection = [e.id]
        let c = CGPoint(x: 400, y: 350)
        drag(knob(of: e), around(c, angle: 0.001))
        XCTAssertNil(element(e.id).rotation)
    }

    func testGroupKnobRotatesEveryShapeAboutTheSharedCenter() {
        let a = add(.rectangle, CGRect(x: 200, y: 300, width: 100, height: 60))
        let b = add(.ellipse, CGRect(x: 500, y: 300, width: 100, height: 60))
        view.selection = [a.id, b.id]
        let box = view.model.selectionBounds([a.id, b.id]).insetBy(dx: -6, dy: -6)
        let center = CGPoint(x: box.midX, y: box.midY)
        let knobPoint = CGPoint(x: box.midX, y: box.minY - 24)
        drag(knobPoint, around(center, angle: .pi / 2))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].name, "Rotate")
        XCTAssertEqual(element(a.id).angle, .pi / 2, accuracy: 1e-6)
        XCTAssertEqual(element(b.id).angle, .pi / 2, accuracy: 1e-6)
        // The pair was side by side; a quarter turn about their center stacks them vertically.
        XCTAssertEqual(element(a.id).frame.midX, element(b.id).frame.midX, accuracy: 1e-6)
        XCTAssertGreaterThan(abs(element(a.id).frame.midY - element(b.id).frame.midY), 250)
    }

    // MARK: Resize

    func testResizingARotatedShapeKeepsTheOppositeCornerFixed() {
        let e = add(.rectangle, CGRect(x: 300, y: 300, width: 200, height: 100), rotation: .pi / 6)
        view.selection = [e.id]
        let anchor = e.rotated(CGPoint(x: e.frame.minX, y: e.frame.minY))
        let handle = e.rotated(CGPoint(x: e.frame.maxX + 4, y: e.frame.maxY + 4))
        drag(handle, CGPoint(x: handle.x + 60, y: handle.y + 25))
        XCTAssertEqual(commits.last?.name, "Resize")
        let after = element(e.id)
        let anchorAfter = after.rotated(CGPoint(x: after.frame.minX, y: after.frame.minY))
        XCTAssertEqual(anchorAfter.x, anchor.x, accuracy: 0.01)
        XCTAssertEqual(anchorAfter.y, anchor.y, accuracy: 0.01)
        XCTAssertGreaterThan(after.width, 200)
        XCTAssertEqual(after.angle, .pi / 6, accuracy: 1e-9)
    }

    func testResizeSnapsTheMovingEdgeToANeighbour() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 100, height: 100))
        _ = add(.rectangle, CGRect(x: 400, y: 100, width: 100, height: 100))
        view.selection = [a.id]
        let handle = CGPoint(x: 204, y: 150) // right-middle handle (frame inset by 4)
        drag(handle, CGPoint(x: 204 + 197, y: 150))
        XCTAssertEqual(element(a.id).frame.maxX, 400, accuracy: 0.001)
        // ⌘ bypasses snapping.
        view.selection = [a.id]
        let h2 = CGPoint(x: 404, y: 150)
        drag(h2, CGPoint(x: 404 - 3, y: 150), mods: .command)
        XCTAssertEqual(element(a.id).frame.maxX, 397, accuracy: 0.001)
    }

    func testMovingSnapsToEqualSpacingBetweenNeighbours() {
        _ = add(.rectangle, CGRect(x: 0, y: 100, width: 50, height: 50))
        _ = add(.rectangle, CGRect(x: 205, y: 100, width: 50, height: 50))
        let m = add(.rectangle, CGRect(x: 100, y: 100, width: 40, height: 50))
        view.selection = [m.id]
        drag(CGPoint(x: 120, y: 125), CGPoint(x: 125, y: 125)) // drifts to x = 105
        XCTAssertEqual(element(m.id).frame.minX, 107.5, accuracy: 0.001) // 57.5 each side
    }

    // MARK: Tools

    func testEveryToolIsRegisteredOnceWithItsOwnKey() {
        let tools = Tool.all
        XCTAssertEqual(tools.first, .select)
        XCTAssertEqual(tools.count, 11)
        XCTAssertEqual(Set(tools.map(\.id)).count, tools.count)
        XCTAssertEqual(Set(tools.map(\.shortcut)).count, tools.count)
        for t in tools { XCTAssertEqual(t.behavior.tool, t, t.id) }
    }

    func testShapeToolsDragOutTheirShapeSnappedToTheGrid() {
        UserDefaults.standard.set(true, forKey: Pref.snapToGrid)
        UserDefaults.standard.set(20.0, forKey: Pref.gridSize)
        defer { UserDefaults.standard.set(false, forKey: Pref.snapToGrid); UserDefaults.standard.removeObject(forKey: Pref.gridSize) }
        for (tool, kind) in [(Tool.rectangle, ElementKind.rectangle), (.ellipse, .ellipse), (.diamond, .diamond)] {
            view.model.elements = []; commits = []
            view.tool = tool
            drag(CGPoint(x: 103, y: 107), CGPoint(x: 300, y: 200))
            XCTAssertEqual(commits.map(\.name), ["Add Shape"])
            XCTAssertEqual(view.model.elements.map(\.kind), [kind])
            XCTAssertEqual(view.model.elements.first?.frame, CGRect(x: 100, y: 100, width: 200, height: 100), "the press snaps too")
            XCTAssertEqual(view.tool, .select, "back to Select to move it")
        }
    }

    func testTextToolClickTypesIntoANewTextBox() {
        view.tool = .text
        click(CGPoint(x: 200, y: 200))
        let e = view.model.elements.first
        XCTAssertEqual(e?.kind, .text)
        XCTAssertEqual(e?.frame.origin, CGPoint(x: 200, y: 200))
        XCTAssertNotNil(view.textEditor)
        XCTAssertEqual(view.selection, Set([e?.id].compactMap { $0 }))
    }

    func testConnectorToolBindsBothEnds() throws {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 100, height: 60))
        let b = add(.rectangle, CGRect(x: 400, y: 100, width: 100, height: 60))
        view.tool = .connector
        drag(CGPoint(x: 150, y: 130), CGPoint(x: 450, y: 130))
        XCTAssertEqual(commits.map(\.name), ["Add Connector"])
        let c = try XCTUnwrap(view.model.elements.first { $0.kind == .connector }?.connector)
        XCTAssertEqual(c.start.elementID, a.id)
        XCTAssertEqual(c.end.elementID, b.id)
    }

    func testHighlighterDrawsInItsOwnStyleAndKeepsGoing() {
        view.tool = .highlighter
        drag(CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 320), steps: 30)
        XCTAssertEqual(commits.map(\.name), ["Draw"])
        XCTAssertEqual(view.model.elements.first?.kind, .freehand)
        XCTAssertEqual(view.model.elements.first?.style.strokeWidth, CanvasNSView.highlighterStyle.strokeWidth)
        XCTAssertEqual(view.tool, .highlighter)
    }

    func testToolsDrawNothingWhenEveryLayerIsLocked() {
        view.model.layers[0].locked = true
        for tool in [Tool.rectangle, .text, .connector, .pencil] {
            view.tool = tool
            drag(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))
        }
        XCTAssertTrue(view.model.elements.isEmpty)
        XCTAssertTrue(commits.isEmpty)
    }

    // MARK: Extension tools

    /// Loads one bundle with a Boxer tool (a box from the press to the pointer, and its corner dot once let go) and a
    /// tool whose `draw` throws, into the app's extensions. Undone by `unloadExtensions`.
    private func loadToolExtension() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-tools-\(UUID().uuidString)", isDirectory: true)
        let dir = folder.appendingPathComponent("Tools.dottieext", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"id":"com.example.tools","name":"Tools","version":"1.0.0","dottieApi":1}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
            extension.tool({ id: "boxer", name: "Boxer", icon: "square.dashed", draw: function (g) {
              var a = g.points[0], b = g.points[g.points.length - 1];
              var out = [{ kind: "rectangle", x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) }];
              if (g.done) out.push({ kind: "ellipse", x: b.x - 3, y: b.y - 3, width: 6, height: 6 });
              return { elements: out };
            } });
            extension.tool({ id: "broken", name: "Broken", draw: function (g) {
              if (g.points.length > 3) throw new Error("no more");
              return { elements: [{ kind: "rectangle", x: 0, y: 0, width: 10, height: 10 }] };
            } });
            """.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        ExtensionHost.shared.registry.scan(in: folder, disabled: [])
        return folder
    }

    private func unloadExtensions(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        ExtensionHost.shared.registry.scan(in: folder, disabled: [])
    }

    func testExtensionToolsJoinTheToolbarWithoutAKey() throws {
        let folder = try loadToolExtension()
        defer { unloadExtensions(folder) }
        let boxer = Tool(id: "com.example.tools/boxer")
        XCTAssertEqual(Tool.all.suffix(2), [boxer, Tool(id: "com.example.tools/broken")])
        XCTAssertEqual(boxer.label, "Boxer")
        XCTAssertEqual(boxer.symbol, "square.dashed")
        XCTAssertNil(boxer.shortcut)
        XCTAssertEqual(Tool(id: "com.example.tools/broken").symbol, "wand.and.stars", "no icon: the default")
        unloadExtensions(folder)
        XCTAssertFalse(Tool.all.contains(boxer))
    }

    func testAnExtensionToolDrawsOneUndoStepFromTheWholeDrag() throws {
        let folder = try loadToolExtension()
        defer { unloadExtensions(folder) }
        let before = add(.rectangle, CGRect(x: 600, y: 500, width: 50, height: 50))
        view.tool = Tool(id: "com.example.tools/boxer")
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        XCTAssertEqual(view.model.elements.count, 2, "the press already shows what it draws")
        for i in 1...20 {
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 100 + Double(i) * 10, y: 100 + Double(i) * 5)))
        }
        XCTAssertEqual(view.model.elements.count, 2, "each step redraws from the page as it was, so nothing piles up")
        XCTAssertTrue(commits.isEmpty)
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 300, y: 200)))
        XCTAssertEqual(commits.map(\.name), ["Boxer"])
        let drawn = view.model.elements.filter { $0.id != before.id }
        XCTAssertEqual(drawn.map(\.kind), [.rectangle, .ellipse])
        XCTAssertEqual(drawn[0].frame, CGRect(x: 100, y: 100, width: 200, height: 100))
        XCTAssertEqual(view.selection, Set(drawn.map(\.id)))
        XCTAssertEqual(drawn[0].seed &+ 1, drawn[1].seed)
        XCTAssertEqual(view.tool, Tool(id: "com.example.tools/boxer"), "a drawing tool keeps going")
    }

    func testAFailingExtensionToolLeavesThePageAsItWas() throws {
        let folder = try loadToolExtension()
        defer { unloadExtensions(folder) }
        let page = view.model
        view.tool = Tool(id: "com.example.tools/broken")
        drag(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))
        XCTAssertEqual(view.model, page)
        XCTAssertTrue(commits.isEmpty)
    }

    // MARK: Eraser

    func testEraserClickCutsAStrokeInTwoAndSweepRemovesTheRest() {
        let s = stroke(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 500, y: 200))
        view.tool = .eraser
        drag(CGPoint(x: 300, y: 200), CGPoint(x: 300, y: 200), steps: 1)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].name, "Erase")
        let pieces = view.model.elements.filter { $0.kind == .freehand }
        XCTAssertEqual(pieces.count, 2)
        XCTAssertNotNil(pieces[0].path)
        XCTAssertLessThan(pieces[0].frame.maxX, 300)
        XCTAssertGreaterThan(pieces[1].frame.minX, 300)
        XCTAssertTrue(pieces.contains { $0.id == s.id })

        // One sweep along the whole line is one undo step and leaves nothing.
        drag(CGPoint(x: 80, y: 200), CGPoint(x: 520, y: 200), steps: 60)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[1].name, "Erase")
        XCTAssertTrue(view.model.elements.filter { $0.kind == .freehand }.isEmpty)
    }

    func testEraserRemovesShapesItTouchesButNotOthers() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 80, height: 80))
        let b = add(.rectangle, CGRect(x: 400, y: 100, width: 80, height: 80))
        view.tool = .eraser
        drag(CGPoint(x: 140, y: 140), CGPoint(x: 140, y: 140), steps: 1)
        XCTAssertNil(view.model.elements.first { $0.id == a.id })
        XCTAssertNotNil(view.model.elements.first { $0.id == b.id })
    }

    // MARK: Pencil and stroke handles

    func testPencilCommitsAFittedStrokeWithFewControlPoints() {
        view.tool = .pencil
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 300)))
        for i in 1...120 {
            let x = 100 + Double(i) * 4
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: x, y: 300 + 40 * sin(Double(i) / 12))))
        }
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 580, y: 300)))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].name, "Draw")
        let s = view.model.elements[0]
        XCTAssertNil(s.points)
        XCTAssertLessThan(s.path?.count ?? .max, 120) // 120 samples became a handful of control points
        XCTAssertNotNil(s.strokeControlPoints)
    }

    func testDraggingAnAnchorMovesItsHandlesAndCommitsOnce() throws {
        let s = stroke(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 500, y: 300), wobble: 40)
        view.selection = [s.id]
        let before = try XCTUnwrap(s.strokeControlPoints)
        let a = before[3] // an interior anchor
        drag(a, CGPoint(x: a.x, y: a.y - 70))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].name, "Edit Stroke")
        let after = try XCTUnwrap(element(s.id).strokeControlPoints)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after[3].y, a.y - 70, accuracy: 0.5)
        XCTAssertEqual(after[2].y - before[2].y, -70, accuracy: 0.5) // handles travelled with the anchor
        XCTAssertEqual(after[4].y - before[4].y, -70, accuracy: 0.5)
        // Untouched points only move by the 4-decimal normalisation (well under a tenth of a point).
        XCTAssertEqual(after[0].x, before[0].x, accuracy: 0.05)
        XCTAssertEqual(after[0].y, before[0].y, accuracy: 0.05)
    }

    func testClickingEmptyCanvasDoesNotRotateOrCommit() {
        let e = add(.rectangle, CGRect(x: 300, y: 300, width: 200, height: 100))
        view.selection = [e.id]
        drag(CGPoint(x: 50, y: 50), CGPoint(x: 55, y: 55))
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(element(e.id), e)
    }

    // MARK: SVG import

    func testImportingSVGsIsOneUndoStepSelectedAndScaledUp() {
        let icon = Data(##"<svg viewBox="0 0 24 24"><path d="M2 2h20v20H2z" fill="#f00"/></svg>"##.utf8)
        let two = Data(##"<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#00f"/></svg>"##.utf8)
        XCTAssertTrue(view.importSVGs([icon, two], at: CGPoint(x: 200, y: 200), keepOriginalColors: true))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].name, "Import SVG")
        let added = view.model.elements
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(view.selection, Set(added.map(\.id)))
        XCTAssertEqual(added[0].frame.width, 96 * 20 / 24, accuracy: 0.5) // 24pt icon scaled to 96
        XCTAssertLessThan(added[0].frame.maxX, added[1].frame.minX)       // laid out left to right
        XCTAssertFalse(view.importSVGs([Data("nope".utf8)], at: .zero, keepOriginalColors: true))
        XCTAssertEqual(commits.count, 1)
    }

    func testPlacingAStencilIsOneUndoStepAtTheRequestedPoint() throws {
        let item = try XCTUnwrap(StencilLibrary.starter.items.first { $0.name == "Database" })
        XCTAssertTrue(view.placeStencil(item, keepOriginalColors: false, at: CGPoint(x: 400, y: 300)))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].name, "Place Database")
        XCTAssertEqual(view.model.elements.count, item.elements.count)
        let box = view.model.elements.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(box.midX, 400, accuracy: 1)
        XCTAssertEqual(box.midY, 300, accuracy: 1)
        XCTAssertTrue(view.model.elements.allSatisfy { $0.style.roughness > 0 }, "restyled to the sketchy default")
        XCTAssertEqual(view.selection.count, item.elements.count)
    }

    func testImportingDrawioAndExcalidrawScenesAreOneUndoStepEach() {
        let drawio = Data(##"<mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/><mxCell id="a" value="A" style="rounded=1;" vertex="1" parent="1"><mxGeometry x="10" y="10" width="100" height="50" as="geometry"/></mxCell><mxCell id="b" value="B" vertex="1" parent="1"><mxGeometry x="200" y="10" width="100" height="50" as="geometry"/></mxCell><mxCell id="e" edge="1" parent="1" source="a" target="b"><mxGeometry relative="1" as="geometry"/></mxCell></root></mxGraphModel>"##.utf8)
        XCTAssertTrue(view.importDrawio(drawio, at: CGPoint(x: 300, y: 300), keepOriginalColors: false))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].name, "Import draw.io")
        XCTAssertEqual(view.model.elements.count, 3)
        let link = view.model.elements.first { $0.kind == .connector }
        XCTAssertNotNil(link?.connector?.start.elementID)
        XCTAssertTrue(view.model.elements.contains { $0.id == link?.connector?.start.elementID }, "bound to the placed copy")

        let exc = Data(##"{"type":"excalidraw","elements":[{"id":"r","type":"rectangle","x":0,"y":0,"width":50,"height":30}]}"##.utf8)
        XCTAssertTrue(view.importExcalidraw(exc, at: CGPoint(x: 100, y: 100)))
        XCTAssertEqual(commits.count, 2)
        XCTAssertFalse(view.importDrawio(Data("<nope/>".utf8), at: .zero, keepOriginalColors: false))
        XCTAssertEqual(commits.count, 2)
    }

    // MARK: Rulers and guides

    func testDraggingFromTheRulersPullsOutGuidesAndDroppingBackRemovesThem() {
        view.showRulers = true
        // Left ruler (x < 20) pulls a vertical guide; the model point is the drop point at zoom 1, pan 0.
        drag(CGPoint(x: 10, y: 300), CGPoint(x: 250, y: 300))
        XCTAssertEqual(view.model.guidesX, [250])
        XCTAssertEqual(commits.count, 1)
        // Top ruler (y < 20) pulls a horizontal one.
        drag(CGPoint(x: 400, y: 10), CGPoint(x: 400, y: 180))
        XCTAssertEqual(view.model.guidesY, [180])
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits.map(\.name), ["Add Guide", "Add Guide"])
        // Grab the existing vertical guide in empty space and move it.
        drag(CGPoint(x: 250, y: 500), CGPoint(x: 320, y: 500))
        XCTAssertEqual(view.model.guidesX, [320])
        XCTAssertEqual(commits.last?.name, "Move Guide")
        // Drop it back on the left ruler: gone.
        drag(CGPoint(x: 320, y: 500), CGPoint(x: 5, y: 500))
        XCTAssertNil(view.model.guidesX)
        XCTAssertEqual(commits.last?.name, "Remove Guide")
        XCTAssertEqual(view.model.guidesY, [180])
    }

    func testShapesSnapToGuidesWhileMoving() {
        view.showRulers = true
        var doc = view.model
        doc.guidesX = [500]
        view.model = doc
        let e = add(.rectangle, CGRect(x: 300, y: 300, width: 100, height: 60))
        // Drag so the right edge lands 3 points shy of the guide at x=500.
        drag(CGPoint(x: 350, y: 330), CGPoint(x: 350 + 97, y: 330))
        XCTAssertEqual(element(e.id).frame.maxX, 500, accuracy: 0.001)
    }

    func testRulersAndThemeRenderWithoutDisturbingContent() throws {
        view.showRulers = true
        var doc = view.model
        doc.theme = "blueprint"; doc.guidesX = [200]
        view.model = doc
        _ = add(.rectangle, CGRect(x: 100, y: 100, width: 200, height: 100), text: "hello")
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let out = ProcessInfo.processInfo.environment["DOTTIE_SNAPSHOT"], let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out))
        }
        // The page color is the theme's, not the system's, in the middle of the canvas.
        let c = try XCTUnwrap(rep.colorAt(x: 700, y: 600)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(c.redComponent, 0.3)            // dark blue, not the system's white or black
        XCTAssertGreaterThan(c.blueComponent, c.redComponent + 0.15)
    }

    func testLockedGuidesStaySnappableButCannotBeDraggedOrCreated() {
        view.showRulers = true
        var doc = view.model
        doc.guidesX = [500]; doc.guidesLocked = true
        view.model = doc
        drag(CGPoint(x: 500, y: 300), CGPoint(x: 600, y: 300))          // would have moved the guide
        XCTAssertEqual(view.model.guidesX, [500])
        drag(CGPoint(x: 10, y: 300), CGPoint(x: 250, y: 300))           // would have pulled a new one
        XCTAssertEqual(view.model.guidesX, [500])
        XCTAssertTrue(commits.isEmpty)
        let e = add(.rectangle, CGRect(x: 300, y: 100, width: 100, height: 60))
        drag(CGPoint(x: 350, y: 130), CGPoint(x: 447, y: 130))          // still snaps: right edge to 500
        XCTAssertEqual(element(e.id).frame.maxX, 500, accuracy: 0.001)
    }

    // MARK: Links

    /// Where the link badge of an unrotated, ungrouped element is drawn at zoom 1, in view points.
    func badge(of e: Element) -> CGPoint {
        let (pan, zoom) = view.viewport
        let m = CGPoint(x: e.frame.maxX + 4 + 18 / zoom, y: e.frame.minY + 6 / zoom)
        return CGPoint(x: m.x * zoom + pan.x, y: m.y * zoom + pan.y)
    }

    func click(_ p: CGPoint, mods: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: event(.leftMouseDown, p, mods: mods))
        view.mouseUp(with: event(.leftMouseUp, p, mods: mods))
    }

    /// The model point at the middle of the view.
    var viewCenter: CGPoint {
        let (pan, zoom) = view.viewport
        return CGPoint(x: (view.bounds.midX - pan.x) / zoom, y: (view.bounds.midY - pan.y) / zoom)
    }

    func testClickingABadgeJumpsToTheTargetAndBackReturns() {
        let toc = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60), text: "Contents")
        let far = add(.rectangle, CGRect(x: 3000, y: 2000, width: 200, height: 100), text: "Billing")
        view.model.elements[0].link = far.id
        click(badge(of: toc))
        XCTAssertEqual(viewCenter.x, far.frame.midX, accuracy: 0.5)
        XCTAssertEqual(viewCenter.y, far.frame.midY, accuracy: 0.5)
        XCTAssertEqual(view.viewport.zoom, 1, accuracy: 1e-9) // it fits at 100%, so no zoom change
        XCTAssertTrue(commits.isEmpty)                        // following a link is not an edit
        XCTAssertTrue(view.selection.isEmpty)
        XCTAssertTrue(view.jumpBack(animated: false))
        XCTAssertEqual(view.viewport.pan, .zero)
        XCTAssertTrue(view.jumpForward(animated: false))
        XCTAssertEqual(viewCenter.x, far.frame.midX, accuracy: 0.5)
        XCTAssertFalse(view.jumpForward(animated: false))
    }

    func testJumpZoomsOutToFitALargeTarget() {
        let toc = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60), text: "Contents")
        let section = add(.rectangle, CGRect(x: 2000, y: 0, width: 2000, height: 1000), text: "Section")
        view.model.elements[0].link = section.id
        click(badge(of: toc))
        let zoom = view.viewport.zoom
        XCTAssertLessThan(zoom, 1)
        XCTAssertLessThanOrEqual(section.frame.width * zoom, view.bounds.width - 120 + 0.001)
        XCTAssertEqual(viewCenter.x, section.frame.midX, accuracy: 0.5)
    }

    func testBrokenLinkStaysPut() {
        let toc = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60), text: "Contents")
        view.model.elements[0].link = UUID()
        click(badge(of: toc))
        XCTAssertEqual(view.viewport.pan, .zero)
        XCTAssertFalse(view.jumpBack(animated: false))
    }

    func testLinksOutOfTheDrawingGoToTheWindow() throws {
        var opened: [OutsideLink] = []
        view.onOpenOutsideLink = { opened.append($0) }
        let site = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60), text: "Docs")
        try view.model.setURL([site.id], to: "https://example.com/docs")
        click(badge(of: site))
        click(CGPoint(x: 160, y: 130), mods: .command)
        XCTAssertEqual(opened, [.web("https://example.com/docs"), .web("https://example.com/docs")])
        XCTAssertTrue(commits.isEmpty, "following a link is not an edit")
        XCTAssertEqual(view.viewport.pan, .zero)
        XCTAssertFalse(view.jumpBack(animated: false), "leaving the drawing is not a jump")
    }

    /// Whether the link badge of `e` is drawn gray, the look of a link that leads nowhere.
    private func badgeIsGray(_ e: Element) -> Bool {
        let p = badge(of: e)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let c = rep.colorAt(x: Int(p.x * scale), y: Int((p.y + 6) * scale))!.usingColorSpace(.sRGB)! // below the glyph
        return c.saturationComponent < 0.2 && c.brightnessComponent < 0.9
    }

    func testADrawingLinkToAMissingFileLooksBroken() throws {
        view.linkBase = URL(fileURLWithPath: "/tmp/plans/overview.dottie")
        view.outsideLinkBroken = { OutsideLinks.isBroken($0, from: URL(fileURLWithPath: "/tmp/plans/overview.dottie")) }
        let gone = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60), text: "Gone")
        let web = add(.rectangle, CGRect(x: 100, y: 300, width: 120, height: 60), text: "Web")
        try view.model.setURL([gone.id], to: "nowhere-\(UUID().uuidString).dottie#Top")
        try view.model.setURL([web.id], to: "https://example.com")
        XCTAssertTrue(badgeIsGray(gone))
        XCTAssertFalse(badgeIsGray(web))
    }

    func testRemoveLinkClearsAnOutsideLink() throws {
        let site = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60))
        try view.model.setURL([site.id], to: "next.dottie")
        view.selection = [site.id]
        view.removeLink(nil)
        XCTAssertNil(element(site.id).url)
        XCTAssertEqual(commits.map(\.name), ["Remove Link"])
    }

    func testCommandClickFollowsButCommandDragStillMoves() {
        let toc = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60), text: "Contents")
        let far = add(.rectangle, CGRect(x: 3000, y: 2000, width: 200, height: 100), text: "Billing")
        view.model.elements[0].link = far.id
        drag(CGPoint(x: 160, y: 130), CGPoint(x: 260, y: 130), mods: .command)
        XCTAssertEqual(commits.last?.name, "Move")
        XCTAssertEqual(view.viewport.pan, .zero)
        click(CGPoint(x: 260, y: 130), mods: .command)
        XCTAssertEqual(viewCenter.x, far.frame.midX, accuracy: 0.5)
        XCTAssertEqual(element(toc.id).frame.minX, 200, accuracy: 0.001)
    }

    func testResizeHandleNextToTheBadgeStillResizes() {
        let toc = add(.rectangle, CGRect(x: 300, y: 300, width: 120, height: 40), text: "Contents")
        let far = add(.rectangle, CGRect(x: 3000, y: 2000, width: 200, height: 100), text: "Billing")
        view.model.elements[0].link = far.id
        view.selection = [toc.id]
        for top in [true, false] { // the top-right handle, then the right-middle one
            let f = element(toc.id).frame, before = f.maxX
            let handle = CGPoint(x: f.maxX + 4, y: top ? f.minY - 4 : f.midY)
            drag(handle, CGPoint(x: handle.x + 30, y: handle.y))
            XCTAssertEqual(commits.last?.name, "Resize")
            XCTAssertEqual(element(toc.id).frame.maxX, before + 30, accuracy: 0.001)
        }
        XCTAssertEqual(view.viewport.pan, .zero)
    }

    // MARK: Text editing

    func testEditingALabelIsCenteredAndInTheLabelsInk() throws {
        window.appearance = NSAppearance(named: .darkAqua) // light canvas ink
        var e = add(.rectangle, CGRect(x: 100, y: 100, width: 160, height: 120), text: "Hello")
        e.style.fill = RGBA(r: 1, g: 0.95, b: 0.7) // a light fill: the label is drawn dark
        view.model.elements[0] = e
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 180, y: 160), clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 180, y: 160), clicks: 2))
        let field = try XCTUnwrap(view.textEditor)
        XCTAssertEqual(field.frame.midY, e.frame.midY, accuracy: 1, "the editor sits where the label is drawn")
        XCTAssertLessThan(field.frame.height, e.frame.height / 2)
        let ink = try XCTUnwrap(field.textColor?.usingColorSpace(.sRGB))
        XCTAssertLessThan(ink.brightnessComponent, 0.3, "dark text on a light fill, not the white canvas ink")
    }

    // MARK: Pictures

    func pngData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testPastingPictureDataPlacesAnImageInOneStep() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("tech.phin.dottie.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setData(pngData(width: 120, height: 80), forType: .png)
        XCTAssertTrue(CanvasNSView.hasImages(pb))
        view.pasteImages(from: pb)
        XCTAssertEqual(commits.map(\.name), ["Paste"])
        let e = try XCTUnwrap(view.model.elements.first)
        XCTAssertEqual(e.kind, .image)
        XCTAssertEqual(e.frame.size, CGSize(width: 120, height: 80))
        XCTAssertEqual(view.selection, [e.id])
    }

    func testImportingMermaidLaysOutConnectedShapesInOneStep() throws {
        XCTAssertTrue(view.importMermaid("flowchart LR\n  A[Start] --> B{OK?}\n  B -->|yes| C((Done))", at: CGPoint(x: 400, y: 300)))
        XCTAssertEqual(commits.map(\.name), ["Import Mermaid"])
        let kinds = view.model.elements.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .connector }.count, 2)
        XCTAssertEqual(Set(kinds.filter { $0 != .connector }), [.rectangle, .diamond, .ellipse])
        XCTAssertEqual(view.selection.count, view.model.elements.count)
        let c = try XCTUnwrap(view.model.elements.first { $0.text == "yes" })
        XCTAssertNotNil(c.connector?.start.elementID)
    }

    func testDoubleClickingAPictureDoesNotEditALabel() throws {
        var doc = view.model
        let e = try DiagramOps.addImage(&doc, data: pngData(width: 100, height: 100), at: CGPoint(x: 100, y: 100))
        view.model = doc
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 150, y: 150), clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 150, y: 150), clicks: 2))
        XCTAssertNil(view.textEditor)
        XCTAssertEqual(view.selection, [e.id])
    }

    func testClickingWithTheNoteToolPlacesANoteAndReturnStartsANewLine() throws {
        view.tool = .note
        click(CGPoint(x: 120, y: 100))
        let note = try XCTUnwrap(view.model.elements.first)
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.frame, CGRect(origin: CGPoint(x: 120, y: 100), size: DiagramOps.defaultSize(for: .note, text: "")))
        XCTAssertEqual(note.style.fill, Note.defaultFill)
        XCTAssertTrue(commits.isEmpty, "nothing commits until the typing is done")

        let field = try XCTUnwrap(view.textEditor)
        XCTAssertEqual(field.frame.minY, Note.textRect(note.frame).minY, accuracy: 1, "a note is edited from the top, not centered")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("# Hi", replacementRange: editor.selectedRange())
        XCTAssertTrue(view.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        editor.insertText("- one", replacementRange: editor.selectedRange())
        XCTAssertNotNil(view.textEditor, "Return did not end editing")

        window.makeFirstResponder(view)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.last?.name, "Add Note")
        XCTAssertEqual(commits.last?.doc.elements.first?.text, "# Hi\n- one")
    }

    /// Return through the app's event queue, as typed, so the editor sees it as the current event.
    func pressReturn(_ mods: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, characters: "\r",
                                             charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!, atStart: false)
            // Dequeuing is what makes it NSApp.currentEvent, as the run loop would.
            guard let e = NSApp.nextEvent(matching: [.keyDown, .keyUp], until: .distantFuture, inMode: .default, dequeue: true) else { return }
            NSApp.sendEvent(e)
        }
    }

    func testReturnInANoteIsANewLineAndShiftOrCommandReturnFinishes() throws {
        window.makeKeyAndOrderFront(nil)
        for mods: NSEvent.ModifierFlags in [.shift, .command] {
            commits = []
            view.model.elements = []
            view.tool = .note
            click(CGPoint(x: 120, y: 100))
            let editor = try XCTUnwrap(view.textEditor?.currentEditor() as? NSTextView)
            editor.insertText("a", replacementRange: editor.selectedRange())
            pressReturn()
            editor.insertText("b", replacementRange: editor.selectedRange())
            XCTAssertNotNil(view.textEditor, "plain Return keeps editing")
            pressReturn(mods)
            XCTAssertNil(view.textEditor, "\(mods) Return finishes")
            XCTAssertEqual(view.tool, .select)
            XCTAssertEqual(commits.last?.doc.elements.first?.text, "a\nb")
        }
    }

    func testClickingANotesCheckboxTicksItInOneUndoStepWithoutMovingIt() throws {
        let note = add(.note, CGRect(x: 100, y: 100, width: 220, height: 160), text: "- [ ] ship it\n- [x] test it")
        let rect = Note.textRect(note.frame)
        // Where each box is drawn: down the marker column until the hit test names its source line.
        func box(_ line: Int) throws -> CGPoint {
            let y = try XCTUnwrap(stride(from: rect.minY, to: rect.maxY, by: 1).first {
                Note.checkboxLine(at: CGPoint(x: rect.minX + 5, y: $0), in: note) == line
            })
            return CGPoint(x: rect.minX + 5, y: y + 6)
        }
        let first = try box(1), second = try box(2)
        click(first)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.last?.name, "Check Item")
        XCTAssertEqual(element(note.id).text, "- [x] ship it\n- [x] test it")
        XCTAssertEqual(element(note.id).frame, note.frame)
        click(second)
        XCTAssertEqual(element(note.id).text, "- [x] ship it\n- [ ] test it")
        click(CGPoint(x: rect.midX + 40, y: first.y)) // the item's text just selects
        XCTAssertEqual(commits.count, 2)
    }

    func testTabIndentsTheLineInANoteAndShiftTabOutdents() throws {
        _ = add(.note, CGRect(x: 100, y: 100, width: 220, height: 160), text: "- one\n- two")
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 200, y: 200), clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 200, y: 200), clicks: 2))
        let field = try XCTUnwrap(view.textEditor)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 9, length: 0)) // in "two"
        XCTAssertTrue(view.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(editor.string, "- one\n  - two")
        XCTAssertEqual(editor.selectedRange().location, 11, "the caret stays in the word")
        XCTAssertNotNil(view.textEditor, "Tab did not end editing")
        XCTAssertTrue(view.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(editor.string, "- one\n- two")
    }

    func testANewNoteLeftEmptyDisappearsButOneEmptiedLaterStays() throws {
        view.tool = .note
        click(CGPoint(x: 120, y: 100))
        var field = try XCTUnwrap(view.textEditor)
        var editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(view.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(view.model.elements.isEmpty, "an untouched new note is not left behind")
        XCTAssertTrue(commits.isEmpty)

        let note = add(.note, CGRect(x: 100, y: 100, width: 200, height: 160), text: "keep")
        view.tool = .select
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 180, y: 160), clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 180, y: 160), clicks: 2))
        field = try XCTUnwrap(view.textEditor)
        editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.delete(nil)
        window.makeFirstResponder(view)
        XCTAssertEqual(element(note.id).text, "", "a note emptied on purpose stays")
    }

    // MARK: Context menu

    func testRightClickSelectsTheShapeAndOffersLinkItems() throws {
        view.editorActions = { .inert(selectionCount: $0.count) } // the window's actions, doing nothing here
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60))
        let b = add(.rectangle, CGRect(x: 500, y: 400, width: 120, height: 60))
        let menu = try XCTUnwrap(view.menu(for: event(.rightMouseDown, CGPoint(x: 150, y: 130))))
        XCTAssertEqual(view.selection, [a.id])
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Link to Element…"))
        XCTAssertTrue(titles.contains("Copy"))
        XCTAssertFalse(titles.contains("Follow Link")) // nothing to follow yet
        view.model.elements[0].link = b.id
        let linked = try XCTUnwrap(view.menu(for: event(.rightMouseDown, CGPoint(x: 150, y: 130))))
        let follow = try XCTUnwrap(linked.items.first { $0.title == "Follow Link" })
        XCTAssertTrue(view.validateMenuItem(follow))
        _ = view.menu(for: event(.rightMouseDown, CGPoint(x: 800, y: 650)))
        XCTAssertTrue(view.selection.isEmpty)
    }

    func testLinkToElementWaitsForAClickOnTheTarget() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60))
        let b = add(.ellipse, CGRect(x: 500, y: 400, width: 120, height: 80)) // unlabelled: the inspector list can't offer it
        view.selection = [a.id]
        view.linkToElement(nil)
        click(CGPoint(x: 150, y: 130))           // the source itself: still waiting
        XCTAssertTrue(commits.isEmpty)
        click(CGPoint(x: 560, y: 440))
        XCTAssertEqual(commits.map(\.name), ["Link"])
        XCTAssertEqual(element(a.id).link, b.id)
        click(CGPoint(x: 560, y: 440))           // back to normal clicking: selects b, no new link
        XCTAssertEqual(view.selection, [b.id])
        view.selection = [a.id]
        view.removeLink(nil)
        XCTAssertNil(element(a.id).link)
        XCTAssertEqual(commits.last?.name, "Remove Link")
    }

    func testEscapeOrAnEmptyClickCancelsLinkToElement() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60))
        let b = add(.rectangle, CGRect(x: 500, y: 400, width: 120, height: 60))
        view.selection = [a.id]
        view.linkToElement(nil)
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        XCTAssertEqual(view.selection, [a.id])    // Esc only cancelled the pick
        click(CGPoint(x: 560, y: 430))
        XCTAssertNil(element(a.id).link)
        view.selection = [a.id]
        view.linkToElement(nil)
        click(CGPoint(x: 800, y: 100))            // empty canvas
        click(CGPoint(x: 560, y: 430))
        XCTAssertNil(element(a.id).link)
        XCTAssertNil(element(b.id).link)
        XCTAssertTrue(commits.isEmpty)
    }

    // MARK: Flowcharts

    func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags = [], repeating: Bool = false) {
        let arrow = (123...126).contains(code)
        let chars = [48: "\t", 53: "\u{1b}", 123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}"][code] ?? ""
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: arrow ? mods.union([.function, .numericPad]) : mods,
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: repeating, keyCode: code)!)
    }

    func releaseCommand() {
        view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "",
                                                 charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!)
    }

    func testCommandArrowGrowsARowThatLettingGoKeepsAsOneStep() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60), text: "Start")
        view.selection = [a.id]
        key(125, .command)
        key(125, .command, repeating: true) // a held key repeats; it adds nothing
        XCTAssertEqual(view.model.elements.count, 3)
        key(125, .command)
        XCTAssertEqual(view.model.elements.count, 5)
        XCTAssertTrue(commits.isEmpty)       // only shown while ⌘ is down
        releaseCommand()
        XCTAssertEqual(commits.map(\.name), ["Add Nodes"])
        let nodes = view.model.elements.filter { $0.kind == .rectangle && $0.id != a.id }
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(view.model.elements.filter { $0.kind == .connector }.count, 2)
        XCTAssertEqual(view.selection.count, 1)
        XCTAssertTrue(nodes.map(\.id).contains(view.selection.first!))
    }

    func testEscapeBeforeLettingGoDropsTheRowAndAClickKeepsIt() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60))
        let before = view.model
        view.selection = [a.id]
        key(124, .command)
        key(53, .command)
        XCTAssertEqual(view.model, before)
        releaseCommand()
        XCTAssertTrue(commits.isEmpty)
        key(124, .command)
        click(CGPoint(x: 800, y: 600))       // ⌘ let go out of the window: the next click keeps the row
        XCTAssertEqual(commits.map(\.name), ["Add Node"])
    }

    func testArrowsNudgeTheSelectionAsOneStepUntilTheKeyComesUp() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60))
        view.selection = [a.id]
        key(124); key(124, repeating: true); key(124, repeating: true) // a held → repeats
        XCTAssertEqual(element(a.id).frame.origin, CGPoint(x: 103, y: 100))
        XCTAssertTrue(commits.isEmpty)
        view.keyUp(with: NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
                                          charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!)
        XCTAssertEqual(commits.map(\.name), ["Nudge"])
        key(125, .shift)
        key(48) // another key keeps the nudge before acting
        XCTAssertEqual(commits.map(\.name), ["Nudge", "Nudge", "Change Shape"])
        XCTAssertEqual(element(a.id).frame.origin, CGPoint(x: 103, y: 110))
    }

    func testOptionArrowWalksAndTabChangesTheShape() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60))
        view.selection = [a.id]
        key(124, .command); releaseCommand()
        let b = view.selection.first!
        key(123, .option)
        XCTAssertEqual(view.selection, [a.id])
        key(124, .option)
        XCTAssertEqual(view.selection, [b])
        key(48)
        XCTAssertEqual(element(b).kind, .diamond)
        XCTAssertEqual(commits.last?.name, "Change Shape")
    }

    // MARK: Pages

    /// Pages not on screen, by id, standing in for the document's file.
    var offscreen: [UUID: DottieDocument] = [:]
    var otherPageLinks: [(sources: Set<UUID>, page: UUID, target: UUID)] = []

    /// Adds a page holding one labelled box and wires the page callbacks the way CanvasView does.
    func addPage(box frame: CGRect, text: String) -> (page: UUID, box: Element) {
        var page = DottieDocument(name: "Other")
        var st = Style(); st.roughness = 0
        let e = Element(kind: .rectangle, frame: frame, style: st, layerID: page.layers[0].id, text: text)
        page.elements.append(e)
        offscreen[page.id] = page
        view.onShowPage = { [unowned self] id in
            guard let next = offscreen.removeValue(forKey: id) else { return }
            offscreen[view.model.id] = view.model
            view.model = next
        }
        view.findPage = { [unowned self] id in
            ([view.model] + Array(offscreen.values)).first { $0.elements.contains { $0.id == id } }?.id
        }
        view.onLinkOtherPage = { [unowned self] sources, page, target in
            otherPageLinks.append((sources, page, target))
            return true
        }
        return (page.id, e)
    }

    func testBadgeToAnotherPageSwitchesPagesAndBackReturns() {
        let toc = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60), text: "Contents")
        let first = view.model.id
        let (other, far) = addPage(box: CGRect(x: 2000, y: 1500, width: 200, height: 100), text: "Billing")
        view.model.elements[0].link = far.id
        click(badge(of: toc))
        XCTAssertEqual(view.model.id, other)
        XCTAssertEqual(viewCenter.x, far.frame.midX, accuracy: 0.5)
        XCTAssertEqual(viewCenter.y, far.frame.midY, accuracy: 0.5)
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(view.jumpBack(animated: false))
        XCTAssertEqual(view.model.id, first)
        XCTAssertEqual(view.viewport.pan, .zero)
        XCTAssertTrue(view.jumpForward(animated: false))
        XCTAssertEqual(view.model.id, other)
        XCTAssertEqual(viewCenter.x, far.frame.midX, accuracy: 0.5)
    }

    func testEachPageKeepsItsOwnViewport() {
        let toc = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60), text: "Contents")
        let far = add(.rectangle, CGRect(x: 3000, y: 2000, width: 200, height: 100), text: "Billing")
        view.model.elements[0].link = far.id
        let first = view.model.id
        let (other, _) = addPage(box: CGRect(x: 0, y: 0, width: 50, height: 50), text: "X")
        click(badge(of: toc)) // pans this page far away
        let moved = view.viewport.pan
        view.onShowPage?(other)
        XCTAssertEqual(view.viewport.pan, .zero, "a page seen for the first time starts at the origin")
        view.onShowPage?(first)
        XCTAssertEqual(view.viewport.pan, moved)
    }

    func testLinkToElementCanPickATargetOnAnotherPage() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60))
        let first = view.model.id
        let (other, target) = addPage(box: CGRect(x: 300, y: 300, width: 120, height: 60), text: "There")
        view.selection = [a.id]
        view.linkToElement(nil)
        view.onShowPage?(other) // the person clicks the other tab
        click(CGPoint(x: 360, y: 330))
        XCTAssertEqual(otherPageLinks.count, 1)
        XCTAssertEqual(otherPageLinks.first?.sources, [a.id])
        XCTAssertEqual(otherPageLinks.first?.page, first)
        XCTAssertEqual(otherPageLinks.first?.target, target.id)
        XCTAssertTrue(commits.isEmpty, "the link lands on the source page, not the one on screen")
        XCTAssertEqual(view.model.id, first, "it goes back to where the link starts")
        XCTAssertEqual(view.selection, [a.id])
    }

    func testSwitchingPagesClearsTheSelection() {
        let a = add(.rectangle, CGRect(x: 100, y: 100, width: 120, height: 60))
        let (other, _) = addPage(box: CGRect(x: 0, y: 0, width: 50, height: 50), text: "X")
        view.selection = [a.id]
        view.onShowPage?(other)
        XCTAssertTrue(view.selection.isEmpty)
    }

    // MARK: Animation preview

    private func redBox() -> Element {
        var st = Style(); st.roughness = 0; st.fill = RGBA(r: 1, g: 0, b: 0)
        let e = Element(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 100, height: 100), style: st, layerID: layer)
        view.model.elements.append(e)
        var tl = Timeline(duration: 1)
        tl.setKey(Keyframe(t: 0, x: 100), for: e.id)
        tl.setKey(Keyframe(t: 1, x: 500), for: e.id)
        view.model.timeline = tl
        return e
    }

    private func isRed(at p: CGPoint) -> Bool {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let c = rep.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))!.usingColorSpace(.sRGB)!
        return c.redComponent > 0.8 && c.greenComponent < 0.5 && c.blueComponent < 0.5 // color-managed red
    }

    func testPreviewDrawsTheFrameAtThePlayhead() {
        _ = redBox()
        XCTAssertTrue(isRed(at: CGPoint(x: 150, y: 150)), "editing shows the base pose")
        view.playhead = 1
        XCTAssertTrue(isRed(at: CGPoint(x: 550, y: 150)))
        XCTAssertFalse(isRed(at: CGPoint(x: 150, y: 150)))
        view.playhead = nil
        XCTAssertTrue(isRed(at: CGPoint(x: 150, y: 150)))
    }

    func testPreviewTakesNoEdits() {
        let e = redBox()
        view.playhead = 0.5
        drag(CGPoint(x: 150, y: 150), CGPoint(x: 400, y: 400))
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(element(e.id).frame, e.frame)
        XCTAssertNil(view.menu(for: event(.rightMouseDown, CGPoint(x: 150, y: 150))))
    }

    func testPosingADragBecomesKeysInOneCommit() {
        let e = redBox()   // x keyed 100 -> 500 over 1s
        let base = view.model
        // What CanvasView does while paused at 0.5s: show that frame, and turn the finished edit into keys.
        view.model = base.resolved(at: 0.5)
        view.poseTime = 0.5
        var posed: DottieDocument?
        view.onPreview = { _ in }
        view.onCommit = { [unowned self] new, name in commits.append((new, name)); posed = base.applyingPose(new, at: 0.5) }
        drag(CGPoint(x: 350, y: 150), CGPoint(x: 350, y: 300))
        XCTAssertEqual(commits.count, 1)
        let result = try! XCTUnwrap(posed)
        XCTAssertEqual(result.elements[0].frame, e.frame, "the page's own geometry is untouched")
        XCTAssertEqual(result.resolved(at: 0.5).elements[0].y, 250, accuracy: 1)
        XCTAssertEqual(result.resolved(at: 0).elements[0].y, 100, accuracy: 1, "pinned where it was at the start")
        XCTAssertEqual(result.resolved(at: 1).elements[0].x, 500, accuracy: 1, "the x tween is kept")
    }

    func testPacketsAreHiddenWhileEditingUnlessSelected() {
        var st = Style(); st.roughness = 0; st.fill = RGBA(r: 1, g: 0, b: 0)
        let dot = Element(kind: .ellipse, frame: CGRect(x: 100, y: 100, width: 100, height: 100), style: st, layerID: layer)
        view.model.elements.append(dot)
        var tl = Timeline(duration: 2)
        tl.setKey(Keyframe(t: 0.5, visible: true), for: dot.id)
        tl.setKey(Keyframe(t: 1, visible: false), for: dot.id)
        view.model.timeline = tl
        XCTAssertFalse(isRed(at: CGPoint(x: 150, y: 150)), "a packet's base pose is not drawn")
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 150, y: 150)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 150, y: 150)))
        XCTAssertTrue(view.selection.isEmpty, "nor clickable")
        view.selection = [dot.id]
        XCTAssertTrue(isRed(at: CGPoint(x: 150, y: 150)), "picked from the timeline, it shows")
    }

    func testDraggingTheCameraFrameWhilePosingSetsAView() {
        _ = redBox()
        view.model.timeline!.setCamera(CameraKey(t: 0, rect: CGRect(x: 300, y: 300, width: 200, height: 100)))
        let base = view.model
        view.model = base.resolved(at: 0.5)
        view.poseSource = base
        view.poseTime = 0.5
        var edits: [CGRect] = []
        view.onCameraEdit = { edits.append($0) }
        view.onCommit = { [unowned self] d, n in commits.append((d, n)) }
        drag(CGPoint(x: 400, y: 300), CGPoint(x: 450, y: 340))   // the top edge: move
        XCTAssertEqual(edits.last, CGRect(x: 350, y: 340, width: 200, height: 100))
        drag(CGPoint(x: 500, y: 400), CGPoint(x: 700, y: 450))   // the bottom-right corner: resize, same shape
        XCTAssertEqual(edits.last?.width ?? 0, 400, accuracy: 1e-6)
        XCTAssertEqual(edits.last?.height ?? 0, 200, accuracy: 1e-6)
        XCTAssertEqual(edits.last?.origin, CGPoint(x: 300, y: 300), "the opposite corner stays")
        edits = []
        drag(CGPoint(x: 400, y: 350), CGPoint(x: 420, y: 360))   // inside: the drawing, not the camera
        XCTAssertTrue(edits.isEmpty)
    }

    func testPreviewClearsSelectionAndEscLeavesIt() {
        let e = redBox()
        view.selection = [e.id]
        var exited = false
        view.onExitPreview = { exited = true }
        view.playhead = 0
        XCTAssertTrue(view.selection.isEmpty)
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: esc)
        XCTAssertTrue(exited)
    }
}

/// Undo and redo in a multi-page document land on the page they change.
@MainActor
final class PageUndoTests: XCTestCase {
    var doc: DrawingDocument!
    var undo: UndoManager!

    override func setUp() async throws {
        doc = DrawingDocument()
        undo = UndoManager()
        undo.groupsByEvent = false
    }

    func step(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }

    func testUndoShowsTheChangedPageAndAFreshEditDoesNot() {
        step { doc.addPage(undoManager: undo) }
        let first = doc.file.pages[0].id, second = doc.file.pages[1].id
        doc.currentPageID = first
        var next = doc.file
        next.pages[1].elements.append(Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                              style: Style(), layerID: next.pages[1].layers[0].id))
        step { doc.commitFile(next, actionName: "Agent Edit", undoManager: undo) }
        XCTAssertEqual(doc.currentPageID, first, "an edit to another page does not pull the view there")
        undo.undo()
        XCTAssertEqual(doc.currentPageID, second)
        XCTAssertTrue(doc.file.pages[1].elements.isEmpty)
        undo.redo()
        XCTAssertEqual(doc.currentPageID, second)
        XCTAssertEqual(doc.file.pages[1].elements.count, 1)
    }

    func testUndoingNewPageLandsOnThePageBefore() {
        let first = doc.currentPageID
        step { doc.addPage(undoManager: undo) }
        XCTAssertNotEqual(doc.currentPageID, first, "a new page is shown")
        undo.undo()
        XCTAssertEqual(doc.file.pages.count, 1)
        XCTAssertEqual(doc.currentPageID, first)
    }

    func testUndoingDeleteShowsTheRestoredPage() {
        step { doc.addPage(undoManager: undo) }
        let doomed = doc.currentPageID
        step { doc.deletePage(doomed, undoManager: undo) }
        XCTAssertNotEqual(doc.currentPageID, doomed)
        undo.undo()
        XCTAssertEqual(doc.currentPageID, doomed)
    }

}

@MainActor
final class SymbolEditingTests: XCTestCase {
    func testEditingASymbolChangesItInPlaceAndUndoes() throws {
        let doc = DrawingDocument()
        let undo = UndoManager()
        undo.groupsByEvent = false
        func step(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
        var page = doc.model
        let box = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 40, height: 20), layerID: page.layers[0].id)
        page.elements = [box]
        let made = try XCTUnwrap(page.makeSymbol(of: [box.id], name: "Box"))
        step { doc.commit(page, actionName: "Convert to Symbol", undoManager: undo) }

        doc.editSymbol(of: made.instance.id)
        XCTAssertEqual(doc.editingSymbol, made.symbol.id)
        XCTAssertEqual(doc.model.id, made.symbol.id, "the canvas edits the symbol as a page")
        var edited = doc.model
        edited.elements[0].width = 80
        step { doc.commit(edited, actionName: "Resize", undoManager: undo) }
        XCTAssertEqual(doc.page.symbols?.first?.elements.first?.width, 80, "stored back into the page's symbol")
        XCTAssertEqual(doc.page.elements.count, 1, "the page itself is untouched")
        undo.undo()
        XCTAssertEqual(doc.model.elements.first?.width, 40)
        XCTAssertEqual(doc.editingSymbol, made.symbol.id, "still editing it")
        undo.undo()
        XCTAssertNil(doc.page.symbols)
        XCTAssertEqual(doc.model.id, doc.currentPageID, "with the symbol gone, the page shows")

        doc.editingSymbol = made.symbol.id
        doc.currentPageID = doc.file.pages[0].id
        step { doc.addPage(undoManager: undo) }
        XCTAssertNil(doc.editingSymbol, "changing pages leaves the symbol")
    }
}

extension EditorActions {
    /// Actions that do nothing, for the canvas's menus under test.
    static func inert(selectionCount: Int) -> EditorActions {
        EditorActions(
            selectionCount: selectionCount, grouped: false, group: {}, ungroup: {},
            instanceSelected: false, editingSymbol: false, makeSymbol: {}, breakApart: {}, editSymbol: {},
            doneEditingSymbol: {}, align: { _ in }, distribute: { _ in }, reorder: { _ in }, export: { _ in },
            exportAnimation: { _ in }, openScriptConsole: {}, runScriptFile: { _ in }, pageCount: 1, newPage: {},
            duplicatePage: {}, deletePage: {}, showPage: { _ in }, renamePage: {}, movePage: { _ in }, pageIndex: 0,
            linkSelected: false, linkToElement: {}, removeLink: {}, hasAnimation: false, boils: false, settles: false,
            connectorsSelected: 0, newAnimation: {}, editTiming: {}, removeAnimation: {}, addTransition: { _ in },
            sendPacket: {}, buildDiagram: { _ in }, hasNextPage: false, magicMove: {}, marchSelection: {},
            toggleBoil: {}, toggleSettle: {}, clearKeys: {}, hasCamera: false, scenes: [], addScene: { _ in },
            showScene: { _ in }, playScene: { _ in }, frameCamera: {}, removeCamera: {}, repeatSelection: {},
            runExtensionCommand: { _, _ in }, repeatLastCommand: {}, updateExtensionShapes: {})
    }
}
