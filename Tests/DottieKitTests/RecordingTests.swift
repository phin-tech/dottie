import XCTest
import AVFoundation
@testable import DottieKit

/// A run clicked through (`Simulation.record`) keeps every frame a viewer would see, and exports as a movie or GIF.
final class RecordingTests: XCTestCase {
    private func queueWorkers() throws -> DottieDocument {
        var doc = DottieDocument()
        XCTAssertNil(DottieScript.run(ScriptExamples.named("queue-workers")!.code, on: &doc, libraries: [.starter], timeLimit: 10).error)
        return doc
    }

    func testARecordingKeepsEachFrameShownWithItsQueues() throws {
        let doc = try queueWorkers()
        var sim = try Simulation(doc)
        XCTAssertNil(sim.recording)
        sim.record()
        sim.wait(1)
        _ = try sim.click("traffic spike")
        sim.wait(2)
        let r = try XCTUnwrap(sim.recording)
        let fps = Timeline.clampFPS(try XCTUnwrap(doc.timeline).fps)
        XCTAssertEqual(r.frames.count, 1 + Int(fps) * 3, "the first frame, then one for each frame of each wait")
        XCTAssertEqual(r.frames.last, sim.snapshot, "it ends where the run is")
        XCTAssertEqual(r.picture(r.frames.count - 1), sim.picture)
        // After the click the backlog piles up: the queue's depth grows frame by frame.
        let queue = try XCTUnwrap(doc.elements.first { $0.anchor == "queue" }).id
        let depths = r.frames.suffix(Int(fps) * 2).map {
            doc.metrics(at: $0.time, state: .values($0.state), since: $0.since, carried: $0.carried).elements[queue]?.depth ?? 0
        }
        XCTAssertEqual(depths, depths.sorted())
        XCTAssertGreaterThan(depths.last ?? 0, depths.first ?? 0)
        XCTAssertTrue(r.frames.prefix(Int(fps) + 1).allSatisfy { $0.state["spike"] != true })
        XCTAssertTrue(r.frames.suffix(Int(fps) * 2).allSatisfy { $0.state["spike"] == true })
    }

    func testARecordingExportsAsAMovieAndAGIF() async throws {
        var sim = try Simulation(try queueWorkers())
        sim.record()
        sim.wait(0.5)
        _ = try sim.click("traffic spike")
        sim.wait(1)
        let r = try XCTUnwrap(sim.recording)
        let gif = try XCTUnwrap(Exporter.gif(r, scale: 0.5))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), r.frames.count)

        let mp4 = try XCTUnwrap(Exporter.mp4(r, scale: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).mp4")
        try mp4.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(seconds, Double(r.frames.count) / r.fps, accuracy: 0.05, "frames play back to back, though the page time goes round")
    }

    func testAPageWithoutATimelineRecordsHeldFrames() throws {
        var doc = DottieDocument()
        _ = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 40, height: 40), at: .zero,
                                    text: "a", fill: nil, stroke: nil, roughness: 0)
        var sim = try Simulation(doc)
        sim.record()
        sim.wait(1)
        XCTAssertEqual(sim.recording?.frames.count, 1 + Int(Simulation.Recording.stillFPS))
        XCTAssertNotNil(Exporter.gif(try XCTUnwrap(sim.recording)))
    }
}
