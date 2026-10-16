import XCTest
import ImageIO
@testable import DottieKit

final class TimelineTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, x: Double = 0, roughness: Double = 0) throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: x, y: 0, width: 80, height: 40), at: .zero,
                                text: nil, fill: nil, stroke: nil, roughness: roughness)
    }

    func testPageWithoutTimelineIsUnchanged() throws {
        var doc = DottieDocument()
        _ = try box(&doc)
        XCTAssertEqual(doc.resolved(at: 1), doc)
    }

    func testTweensBetweenKeysAndHoldsOutside() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var tl = Timeline(duration: 2)
        tl.setKey(Keyframe(t: 0.5, x: 0), for: a.id)
        tl.setKey(Keyframe(t: 1.5, x: 100), for: a.id)
        doc.timeline = tl
        XCTAssertEqual(doc.resolved(at: 0).elements[0].x, 0)
        XCTAssertEqual(doc.resolved(at: 1).elements[0].x, 50, accuracy: 1e-9)
        XCTAssertEqual(doc.resolved(at: 2).elements[0].x, 100)
        XCTAssertEqual(doc.resolved(at: 1).elements[0].y, 0, "unkeyed properties keep the base value")
    }

    func testPropertiesTweenBetweenTheKeysThatSetThem() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var tl = Timeline(duration: 2)
        tl.setKey(Keyframe(t: 0, x: 0), for: a.id)
        tl.setKey(Keyframe(t: 1, fill: RGBA(r: 1, g: 0, b: 0)), for: a.id)
        tl.setKey(Keyframe(t: 2, x: 200), for: a.id)
        doc.timeline = tl
        XCTAssertEqual(doc.resolved(at: 1).elements[0].x, 100, accuracy: 1e-9, "the fill key doesn't pin x")
    }

    func testEaseAndHold() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var tl = Timeline(duration: 1)
        tl.setKey(Keyframe(t: 0, x: 0, ease: .easeIn), for: a.id)
        tl.setKey(Keyframe(t: 1, x: 100), for: a.id)
        doc.timeline = tl
        XCTAssertEqual(doc.resolved(at: 0.5).elements[0].x, 12.5, accuracy: 1e-9)
        doc.timeline!.setKey(Keyframe(t: 0, ease: .hold), for: a.id)
        XCTAssertEqual(doc.resolved(at: 0.99).elements[0].x, 0)
        XCTAssertEqual(doc.resolved(at: 1).elements[0].x, 100)
    }

    func testSetKeyMergesKeysAtTheSameFrame() throws {
        var tl = Timeline(fps: 10, duration: 1)
        let id = UUID()
        tl.setKey(Keyframe(t: 0.5, x: 1), for: id)
        tl.setKey(Keyframe(t: 0.52, y: 2), for: id)
        XCTAssertEqual(tl.tracks[0].keys, [Keyframe(t: 0.5, x: 1, y: 2)])
    }

    func testConnectorFollowsAnimatedShape() throws {
        var doc = DottieDocument()
        let a = try box(&doc), b = try box(&doc, x: 300)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        var tl = Timeline(duration: 1)
        tl.setKey(Keyframe(t: 0, y: 0), for: b.id)
        tl.setKey(Keyframe(t: 1, y: 200), for: b.id)
        doc.timeline = tl
        let still = doc.resolved(at: 0), moved = doc.resolved(at: 1)
        let end0 = Connector.endpoints(of: still.elements.first { $0.id == c.id }!, in: still).1
        let end1 = Connector.endpoints(of: moved.elements.first { $0.id == c.id }!, in: moved).1
        XCTAssertGreaterThan(end1.y - end0.y, 150)
    }

    func testElementAppearsAtItsVisibleKeyWithItsConnectors() throws {
        var doc = DottieDocument()
        let a = try box(&doc), b = try box(&doc, x: 300)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        var tl = Timeline(duration: 2)
        tl.setKey(Keyframe(t: 1, visible: true), for: b.id)
        doc.timeline = tl
        XCTAssertEqual(doc.resolved(at: 0.5).elements.map(\.id), [a.id])
        XCTAssertEqual(doc.resolved(at: 1).elements.map(\.id), [a.id, b.id, c.id])
        doc.timeline!.setKey(Keyframe(t: 1.5, visible: false), for: b.id)
        XCTAssertEqual(doc.resolved(at: 1.75).elements.map(\.id), [a.id])
    }

    func testBoilReseedsEveryNFramesAndSteadyDoesNot() throws {
        var doc = DottieDocument()
        let a = try box(&doc, roughness: 1)
        doc.timeline = Timeline(fps: 12, duration: 1)
        XCTAssertEqual(doc.resolved(at: 0.5).elements[0].seed, a.seed)
        doc.timeline!.boil = 2
        let seeds = (0..<6).map { doc.resolved(at: doc.timeline!.time(ofFrame: $0)).elements[0].seed }
        XCTAssertEqual(seeds[0], a.seed)
        XCTAssertEqual(seeds[0], seeds[1]); XCTAssertEqual(seeds[2], seeds[3]); XCTAssertEqual(seeds[4], seeds[5])
        XCTAssertEqual(Set([seeds[0], seeds[2], seeds[4]]).count, 3)
    }

    func testSettledShapesStopBoilingWhenStill() throws {
        var doc = DottieDocument()
        let a = try box(&doc, roughness: 1), b = try box(&doc, x: 300, roughness: 1)
        _ = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        var tl = Timeline(fps: 10, duration: 3, boil: 1, settle: true)
        tl.setKey(Keyframe(t: 0, x: 0), for: a.id)
        tl.setKey(Keyframe(t: 1, x: 100), for: a.id)
        tl.setKey(Keyframe(t: 2, x: 100, ease: .hold), for: a.id)
        tl.setKey(Keyframe(t: 3, x: 200), for: a.id)
        doc.timeline = tl
        func seeds(at t: Double) -> [UInt32] { doc.resolved(at: t).elements.map(\.seed) }
        let base = doc.elements.map(\.seed)
        let mid = seeds(at: 0.55)
        XCTAssertNotEqual(mid[0], base[0], "moving shape boils")
        XCTAssertEqual(mid[1], base[1], "unkeyed shape stays steady")
        XCTAssertNotEqual(mid[2], base[2], "connector to a moving shape boils")
        XCTAssertEqual(seeds(at: 1.55), base, "same value on both keys: settled")
        XCTAssertEqual(seeds(at: 2.55), base, "held: settled")
    }

    func testTrackBoilOverridesTheTimeline() throws {
        var doc = DottieDocument()
        let live = try box(&doc, roughness: 1), calm = try box(&doc, x: 300, roughness: 1)
        var tl = Timeline(fps: 10, duration: 1, boil: 1, settle: true)
        tl.setBoil(true, for: live.id)
        tl.setKey(Keyframe(t: 0, x: 300), for: calm.id)
        tl.setKey(Keyframe(t: 1, x: 400), for: calm.id)
        tl.setBoil(false, for: calm.id)
        doc.timeline = tl
        let seeds = doc.resolved(at: 0.55).elements.map(\.seed)
        XCTAssertNotEqual(seeds[0], live.seed, "boils while still")
        XCTAssertEqual(seeds[1], calm.seed, "never boils, even moving")
        XCTAssertEqual(doc.timeline!.track(for: calm.id)?.boil, false, "setKey keeps the override")
        doc.timeline!.settle = nil
        doc.timeline!.setBoil(nil, for: calm.id)
        XCTAssertNotEqual(doc.resolved(at: 0.55).elements[1].seed, calm.seed, "nil follows the timeline")
    }

    func testStillShowsThePosterFrameAndFramesAreStills() throws {
        var doc = DottieDocument()
        let a = try box(&doc), b = try box(&doc, x: 300)
        let c = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        let dot = try doc.addPacket(along: c.id, at: 0.5)
        try doc.addTransition(.popIn, to: b.id, at: 1)
        XCTAssertNil(doc.resolved(at: 0.5).timeline)
        XCTAssertEqual(doc.resolved(at: 0.7).resolved(at: 0), doc.resolved(at: 0.7))
        let end = doc.still.elements.map(\.id)
        XCTAssertFalse(end.contains(dot.id), "the packet has arrived")
        XCTAssertTrue(end.contains(b.id))
        doc.timeline!.poster = 0.2
        XCTAssertEqual(doc.still.elements.map(\.id), [a.id], "before b and the arrow appear")
        XCTAssertEqual(Exporter.bounds(of: doc.still).width, Exporter.bounds(of: doc.resolved(at: 0.2)).width)
    }

    func testRoundTripsAndOldPagesStillDecode() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var tl = Timeline(duration: 1, boil: 3)
        tl.setKey(Keyframe(t: 0.25, x: 10, visible: true, ease: .easeOut), for: a.id)
        doc.timeline = tl
        XCTAssertEqual(try DottieDocument.decode(doc.encoded()).timeline, tl)
        doc.timeline = nil
        XCTAssertFalse(String(decoding: try doc.encoded(), as: UTF8.self).contains("timeline"))
    }

    func testDeletingAnElementDropsItsTrack() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var tl = Timeline(duration: 1)
        tl.setKey(Keyframe(t: 0, x: 5), for: a.id)
        doc.timeline = tl
        doc.remove([a.id])
        XCTAssertEqual(doc.timeline?.tracks, [])
    }

    func testGIFHasOneFramePerTimelineFrame() throws {
        var doc = DottieDocument()
        let a = try box(&doc)
        var tl = Timeline(fps: 10, duration: 0.5)
        tl.setKey(Keyframe(t: 0, x: 0), for: a.id)
        tl.setKey(Keyframe(t: 0.5, x: 300), for: a.id)
        doc.timeline = tl
        let data = try XCTUnwrap(Exporter.gif(doc))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 5)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertGreaterThan(first.width, 300, "every frame is framed to the whole motion")
    }
}
