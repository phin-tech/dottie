import XCTest
import ImageIO
@testable import DottieKit

/// The pre-release adversarial review's confirmed findings, replayed so they stay fixed.
final class ReviewRegressionTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, x: Double = 0, y: Double = 0) throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: x, y: y, width: 80, height: 40), at: .zero,
                                text: nil, fill: nil, stroke: nil, roughness: 1)
    }
    private func page(_ timelineJSON: String, element: Element) throws -> DottieDocument {
        var doc = DottieDocument(elements: [element])
        doc.elements[0].layerID = doc.layers[0].id
        let json = String(decoding: try doc.encoded(), as: UTF8.self)
        let withTimeline = json.replacingOccurrences(of: "\"elements\"", with: "\"timeline\" : \(timelineJSON),\n  \"elements\"")
        return try DottieDocument.decode(Data(withTimeline.utf8))
    }

    // 1. Huge or non-finite numbers no longer trap.
    func testHugeAndNonFiniteTimesAreClamped() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        let script = DottieScript.run("dottie.timeline({duration: 1e308, boil: 1}); dottie.timeline()", on: &doc)
        XCTAssertNil(script.error)
        XCTAssertEqual(doc.timeline?.duration, Timeline.maxDuration)
        XCTAssertNotNil(DottieScript.run("dottie.key(dottie.elements()[0].id, 1e300, {x: 5})", on: &doc).error)
        XCTAssertNoThrow(doc.resolved(at: .infinity))
        XCTAssertNoThrow(doc.resolved(at: .nan))
        _ = doc.still
        let file = try page(#"{"fps": 0, "duration": 1e300, "boil": 1, "poster": 1e300, "tracks": []}"#, element: a)
        XCTAssertEqual(file.timeline?.fps, 1)
        XCTAssertEqual(file.timeline?.duration, Timeline.maxDuration)
        XCTAssertEqual(file.still.elements.count, 1)
        var tl = Timeline(fps: .nan, duration: -.infinity)
        XCTAssertEqual(tl.duration, 0)
        tl.duration = .infinity
        XCTAssertEqual(tl.duration, Timeline.maxDuration)
    }

    // 2. Exports refuse instead of hanging.
    func testTooLongAnimationsAreRefused() throws {
        var doc = DottieDocument()
        _ = try box(&doc)
        doc.timeline = Timeline(fps: 60, duration: 1e7)
        XCTAssertTrue(Exporter.animationTooLong(doc))
        XCTAssertNil(Exporter.gif(doc))
        XCTAssertNil(Exporter.player(doc))
    }

    // 3. Frames before anything enters don't stretch the canvas.
    func testEmptyFramesDontInflateExportBounds() throws {
        var doc = DottieDocument()
        let a = try box(&doc, x: 1000, y: 1000)
        try doc.addTransition(.fadeIn, to: a.id, at: 0.5)
        let gif = try XCTUnwrap(Exporter.gif(doc))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(gif as CFData, nil)!, 0, nil))
        XCTAssertLessThan(img.width, 200)
    }

    // 4. Posing inside a path span keeps the start pose and doesn't fight the path.
    func testPosingDuringAFollowLeavesTheStartAlone() throws {
        var doc = DottieDocument()
        let ring = try DiagramOps.addShape(&doc, kind: .ellipse, frame: CGRect(x: 200, y: 0, width: 300, height: 300),
                                           at: .zero, text: nil, fill: nil, stroke: nil, roughness: 0)
        let a = try box(&doc)
        try doc.addFollow(a.id, along: ring.id, at: 1, duration: 1)
        var frame = doc.resolved(at: 1.5)
        let i = frame.elements.firstIndex { $0.id == a.id }!
        frame.elements[i].x += 10
        frame.elements[i].height = 60
        let posed = doc.applyingPose(frame, at: 1.5)
        XCTAssertEqual(posed.resolved(at: 0).elements.first { $0.id == a.id }?.x, 0)
        XCTAssertNil(posed.timeline?.track(for: a.id)?.keys.first { $0.x != nil }, "the path decides x")
        XCTAssertEqual(posed.resolved(at: 1.5).elements.first { $0.id == a.id }?.height, 60, "size still poses")
    }

    // 5. Edits outside the animated fields survive posing.
    func testReattachingAndRestackingWhilePosingSticks() throws {
        var doc = DottieDocument()
        let a = try box(&doc), b = try box(&doc, x: 200), e = try box(&doc, x: 400)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        doc.startAnimation()
        var frame = doc.resolved(at: 1)
        let ci = frame.elements.firstIndex { $0.id == c.id }!
        frame.elements[ci].connector?.end = .bound(e.id)
        frame.elements.swapAt(0, 1)
        let posed = doc.applyingPose(frame, at: 1)
        XCTAssertEqual(posed.elements.first { $0.id == c.id }?.connector?.end.elementID, e.id)
        XCTAssertEqual(posed.elements.prefix(2).map(\.id), [b.id, a.id])
        XCTAssertEqual(doc.applyingPose(doc.resolved(at: 1), at: 1), doc, "and an untouched frame still changes nothing")
    }

    // 6. One key at a time, and transitions keep their shape at low frame rates.
    func testKeysStayDistinctAtLowFrameRates() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        doc.timeline = Timeline(fps: 2, duration: 1)
        try doc.addTransition(.popIn, to: a.id, at: 0)
        XCTAssertEqual(doc.timeline?.track(for: a.id)?.keys.count, 3)
        try doc.addTransition(.dropIn, to: a.id, at: 2)
        XCTAssertEqual(doc.timeline?.track(for: a.id)?.keys.count, 7, "dropIn keeps its bounce")
        doc.timeline!.removeKey(of: a.id, at: 0)
        XCTAssertEqual(doc.timeline?.track(for: a.id)?.keys.count, 6, "only the one key goes")
    }

    // 7. Duplicate ids don't hang a build.
    func testBuildFinishesWithDuplicateIDs() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var twin = a
        twin.x = 300
        doc.elements.append(twin)
        try doc.addBuild()
        XCTAssertNotNil(doc.timeline)
    }

    // 8 and 9. Files: unsorted keys sort, missing fields default.
    func testTolerantTimelineDecoding() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        let unsorted = try page(#"{"fps": 12, "duration": 2, "tracks": [{"element": "\#(a.id.uuidString)", "keys": [{"t": 2, "x": 100}, {"t": 0, "x": 0}]}]}"#, element: a)
        XCTAssertEqual(unsorted.resolved(at: 1).elements[0].x, 50, accuracy: 1e-9)
        let sparse = try page(#"{"duration": 2}"#, element: a)
        XCTAssertEqual(sparse.timeline?.fps, 12)
        XCTAssertEqual(sparse.timeline?.tracks, [])
    }

    // 10. A loop ends on the pose the still shows.
    func testExportsReachTheRestPose() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        try doc.addTransition(.popIn, to: a.id, at: 0)
        let times = try XCTUnwrap(doc.timeline).frameTimes
        XCTAssertEqual(times.last, doc.timeline?.duration)
        XCTAssertEqual(doc.resolved(at: times.last!).elements[0].frame, doc.still.elements[0].frame)
    }
}
