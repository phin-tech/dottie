import XCTest
import ImageIO
@testable import DottieKit

final class WalkthroughTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, x: Double = 0, y: Double = 0, fill: RGBA? = nil) throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: x, y: y, width: 80, height: 40), at: .zero,
                                text: nil, fill: fill, stroke: nil, roughness: 0)
    }

    // MARK: Repeats

    func testRepeatPlaysASpanAgainForeverOrCounted() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var tl = Timeline(duration: 10)
        tl.setKey(Keyframe(t: 1, x: 0), for: a.id)
        tl.setKey(Keyframe(t: 2, x: 100), for: a.id)
        tl.addRepeat(for: a.id, from: 1, to: 2)
        doc.timeline = tl
        func x(_ t: Double) -> Double { doc.resolved(at: t).elements[0].x }
        XCTAssertEqual(x(1.5), 50, accuracy: 1e-9)
        XCTAssertEqual(x(4.5), 50, accuracy: 1e-9, "forever")
        XCTAssertEqual(x(0.5), 0, "before the span, as before")

        doc.timeline!.tracks[0].repeats = [Repeat(start: 1, end: 2, count: 3)]
        XCTAssertEqual(x(3.5), 50, accuracy: 1e-9, "third time round")
        XCTAssertEqual(x(4.5), 100, accuracy: 1e-9, "done: holds the end")
    }

    func testScriptRepeatsATransition() throws {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const a = dottie.rect({x: 0, y: 0, width: 80, height: 40});
            dottie.transition(a, "pulse", 0, {repeat: true});
            dottie.timeline({duration: 6});
            """, on: &doc)
        XCTAssertNil(r.error)
        let w = { (t: Double) in doc.resolved(at: t).elements[0].width }
        XCTAssertGreaterThan(w(0.25), 80)
        XCTAssertEqual(w(0.25), w(5.25), accuracy: 1e-6, "still pulsing ten times later")
        XCTAssertEqual(TimelineRows(doc).groups[0].rows[0].spans.filter { if case .repeating = $0.kind { true } else { false } }.count, 1)
    }

    // MARK: Camera

    func testCameraEasesBetweenViews() {
        var tl = Timeline(duration: 2)
        XCTAssertNil(tl.cameraRect(at: 1))
        tl.setCamera(CameraKey(t: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 50), ease: .linear))
        tl.setCamera(CameraKey(t: 2, rect: CGRect(x: 100, y: 0, width: 200, height: 100)))
        XCTAssertEqual(tl.cameraRect(at: 1), CGRect(x: 50, y: 0, width: 150, height: 75))
        XCTAssertEqual(tl.cameraRect(at: 5)?.width, 200, "holds after the last key")
        XCTAssertEqual(Exporter.fit(CGRect(x: 0, y: 0, width: 100, height: 100), aspect: 2),
                       CGRect(x: -50, y: 0, width: 200, height: 100), "widened, never cropped")
    }

    func testCameraExportsKeepOneSizeAndFrameTheirTarget() throws {
        var doc = DottieDocument()
        let left = try box(&doc, fill: RGBA(r: 1, g: 0, b: 0))
        let right = try box(&doc, x: 1000, y: 600, fill: RGBA(r: 0, g: 0, b: 1))
        let r = DottieScript.run("""
            dottie.timeline({fps: 4, duration: 2});
            dottie.camera(0, "\(left.id.uuidString)", {padding: 20});
            dottie.camera(2, ["\(right.id.uuidString)"], {padding: 20});
            """, on: &doc)
        XCTAssertNil(r.error)
        let plan = try XCTUnwrap(Exporter.animation(doc))
        XCTAssertEqual(plan.rects.first?.midX ?? 0, left.frame.midX, accuracy: 1e-6)
        XCTAssertEqual(plan.rects.last?.midX ?? 0, right.frame.midX, accuracy: 1e-6)
        let gif = try XCTUnwrap(Exporter.gif(doc))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        let sizes = Set((0..<CGImageSourceGetCount(src)).map { i -> String in
            let img = CGImageSourceCreateImageAtIndex(src, i, nil)!
            return "\(img.width)x\(img.height)"
        })
        XCTAssertEqual(sizes.count, 1, "every frame the same size: \(sizes)")
        XCTAssertNotNil(Exporter.mp4(doc, scale: 1))
        XCTAssertEqual(DottieScript.run("dottie.camera(null)", on: &doc).error, nil)
        XCTAssertNil(doc.timeline?.camera)
    }

    // MARK: Scenes

    func testScenesBecomeAPresentation() throws {
        var doc = DottieDocument()
        _ = try box(&doc)
        let r = DottieScript.run("""
            dottie.timeline({duration: 3});
            dottie.scene(2, "Then </script><b>this");
            dottie.scene(1, "First");
            """, on: &doc)
        XCTAssertNil(r.error)
        XCTAssertEqual(doc.timeline?.markers?.map(\.name), ["First", "Then </script><b>this"])
        let html = try XCTUnwrap(Exporter.player(doc))
        XCTAssertTrue(html.contains("id=\"next\""))
        XCTAssertFalse(html.contains("</script><b>"), "names can't break out of the script")
        XCTAssertTrue(html.contains("Then <\\/script>"))
        XCTAssertFalse(try XCTUnwrap(Exporter.player(DottieDocument(elements: doc.elements))).contains("id=\"next\""))
        let back = try DottieDocument.decode(doc.encoded())
        XCTAssertEqual(back.timeline?.markers, doc.timeline?.markers)
    }
}
