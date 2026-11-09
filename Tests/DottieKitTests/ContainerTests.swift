import XCTest
@testable import DottieKit

/// Containers (ADR 0006): they fit round what they hold, take it along when they move, keep a size set by hand, and
/// gain and lose members as shapes are dropped in and dragged out.
final class ContainerTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, _ x: Double, _ y: Double, _ t: String) throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: x, y: y, width: 100, height: 50), at: .zero,
                                text: t, fill: nil, stroke: nil, roughness: 0)
    }
    private func el(_ doc: DottieDocument, _ id: UUID) -> Element { doc.elements.first { $0.id == id }! }

    func testAContainerFitsRoundItsChildrenBehindThem() throws {
        var doc = DottieDocument()
        let a = try box(&doc, 100, 100, "A"), b = try box(&doc, 300, 200, "B")
        let c = try DiagramOps.addContainer(&doc, title: "Service", children: [a.id, b.id])
        let pad = DottieDocument.containerPadding, band = DottieDocument.titleBand(c)
        XCTAssertEqual(c.frame, CGRect(x: 100 - pad, y: 100 - pad - band, width: 300 + 2 * pad, height: 150 + 2 * pad + band))
        XCTAssertEqual(doc.elements.first?.id, c.id, "drawn behind what it holds")
        XCTAssertEqual(c.labelRect?.y, 0)
        XCTAssertEqual(c.labelFrame.height, band, accuracy: 1e-9)
        XCTAssertEqual(doc.children(of: c.id).map(\.id), [a.id, b.id])
    }

    func testMovingAContainerTakesWhatItHolds() throws {
        var doc = DottieDocument()
        let a = try box(&doc, 100, 100, "A")
        let inner = try DiagramOps.addContainer(&doc, title: "Inner", children: [a.id])
        let outer = try DiagramOps.addContainer(&doc, title: "Outer", children: [inner.id])
        let before = doc
        var moved = doc
        let i = moved.elements.firstIndex { $0.id == outer.id }!
        moved.elements[i].x += 50; moved.elements[i].y += 30
        let after = moved.reconcilingContainers(from: before)
        XCTAssertEqual(el(after, a.id).x, 150); XCTAssertEqual(el(after, a.id).y, 130)
        XCTAssertEqual(el(after, inner.id).x, el(before, inner.id).x + 50)
        XCTAssertEqual(el(after, outer.id).frame, el(before, outer.id).frame.offsetBy(dx: 50, dy: 30))
    }

    func testDroppingInAndDraggingOutChangesMembership() throws {
        var doc = DottieDocument()
        let a = try box(&doc, 100, 100, "A"), b = try box(&doc, 600, 100, "B")
        let c = try DiagramOps.addContainer(&doc, title: "Box", children: [a.id])
        // B dragged into the box.
        var next = doc
        let bi = next.elements.firstIndex { $0.id == b.id }!
        next.elements[bi].x = 110; next.elements[bi].y = 110
        let joined = next.reconcilingContainers(from: doc)
        XCTAssertEqual(el(joined, b.id).containerID, c.id)
        // A dragged far out: it leaves, and the box fits round B alone.
        var out = joined
        let ai = out.elements.firstIndex { $0.id == a.id }!
        out.elements[ai].x = 900
        let left = out.reconcilingContainers(from: joined)
        XCTAssertNil(el(left, a.id).containerID)
        XCTAssertEqual(el(left, c.id).frame.minX, 110 - DottieDocument.containerPadding)
    }

    func testAContainerResizedByHandKeepsItsSize() throws {
        var doc = DottieDocument()
        let a = try box(&doc, 100, 100, "A")
        let c = try DiagramOps.addContainer(&doc, title: nil, children: [a.id])
        var next = doc
        let i = next.elements.firstIndex { $0.id == c.id }!
        next.elements[i].width = 500
        let after = next.reconcilingContainers(from: doc)
        XCTAssertEqual(el(after, c.id).width, 500)
        XCTAssertEqual(el(after, c.id).container?.fixed, true)
    }

    func testASwimlaneStacksItsLanes() throws {
        var doc = DottieDocument()
        let a = try box(&doc, 100, 100, "A"), b = try box(&doc, 400, 400, "B")
        let l1 = try DiagramOps.addContainer(&doc, title: "Lane 1", children: [a.id])
        let l2 = try DiagramOps.addContainer(&doc, title: "Lane 2", children: [b.id])
        let pool = try DiagramOps.addContainer(&doc, title: "Pool", children: [l1.id, l2.id], lanes: .rows)
        let p = el(doc, pool.id), one = el(doc, l1.id), two = el(doc, l2.id)
        XCTAssertEqual(one.frame.minY, p.frame.minY + DottieDocument.titleBand(p), accuracy: 1e-9)
        XCTAssertEqual(two.frame.minY, one.frame.maxY, accuracy: 1e-9)
        XCTAssertEqual(one.width, two.width)
        XCTAssertEqual(one.frame.minX, p.frame.minX)
        // B went with its lane.
        XCTAssertTrue(two.frame.contains(el(doc, b.id).frame))
    }

    func testScriptsMakeContainersAndNestShapes() {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const a = dottie.rect({x: 0, y: 0, text: "A"});
            const box = dottie.container({title: "VPC", children: [a]});
            const b = dottie.rect({x: 300, y: 0, text: "B", parent: box});
            dottie.update(a, {parent: null});
            return [dottie.get(b.id).parent === box.id, dottie.get(a.id).parent === undefined, dottie.get(box.id).container];
            """, on: &doc, libraries: [.starter])
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.value, "[true,true,true]")
        XCTAssertThrowsError(try DiagramOps.setParent(&doc, id: doc.elements.first { $0.container != nil }!.id,
                                                      parent: doc.elements.first { $0.container != nil }!.id))
    }
}

/// Containers from other tools: draw.io swimlanes and containers, Excalidraw frames.
final class ContainerImportTests: XCTestCase {
    func testDrawioSwimlanesBecomeContainers() throws {
        let xml = """
        <mxfile><diagram><mxGraphModel><root>
          <mxCell id="0"/><mxCell id="1" parent="0"/>
          <mxCell id="pool" value="Pool" style="swimlane;horizontal=1;" vertex="1" parent="1"><mxGeometry x="0" y="0" width="400" height="300" as="geometry"/></mxCell>
          <mxCell id="lane" value="Lane" style="swimlane;" vertex="1" parent="pool"><mxGeometry x="0" y="30" width="400" height="120" as="geometry"/></mxCell>
          <mxCell id="a" value="Task" style="rounded=0;" vertex="1" parent="lane"><mxGeometry x="40" y="40" width="100" height="50" as="geometry"/></mxCell>
        </root></mxGraphModel></diagram></mxfile>
        """
        let els = try DrawioImporter.importItems(from: Data(xml.utf8), layerID: UUID())[0].elements
        let pool = try XCTUnwrap(els.first { $0.text == "Pool" }), lane = try XCTUnwrap(els.first { $0.text == "Lane" })
        let task = try XCTUnwrap(els.first { $0.text == "Task" })
        XCTAssertEqual(pool.container?.lanes, .rows)
        XCTAssertNotNil(lane.container)
        XCTAssertEqual(lane.containerID, pool.id)
        XCTAssertEqual(task.containerID, lane.id)
        XCTAssertTrue(lane.frame.contains(task.frame))
    }

    func testExcalidrawFramesBecomeContainers() throws {
        let scene = """
        {"type":"excalidraw","version":2,"elements":[
          {"id":"f","type":"frame","x":0,"y":0,"width":300,"height":200,"name":"Team","strokeColor":"#bbb","backgroundColor":"transparent"},
          {"id":"a","type":"rectangle","x":40,"y":60,"width":100,"height":50,"frameId":"f","strokeColor":"#1e1e1e","backgroundColor":"transparent"}
        ]}
        """
        let els = try ExcalidrawImporter.importItems(from: Data(scene.utf8), layerID: UUID())[0].elements
        let frame = try XCTUnwrap(els.first { $0.container != nil })
        XCTAssertEqual(frame.text, "Team")
        XCTAssertEqual(els.first { $0.kind == .rectangle && $0.container == nil }?.containerID, frame.id)
        XCTAssertEqual(els.first?.id, frame.id, "behind what it holds")
    }
}
