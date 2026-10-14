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
}
