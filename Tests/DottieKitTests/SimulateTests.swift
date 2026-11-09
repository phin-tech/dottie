import XCTest
@testable import DottieKit

/// Checking an interactive page without a browser: drawing a chosen state, and `Simulation` playing it as
/// `<dottie-player>` does.
final class SimulateTests: XCTestCase {
    /// A page with a looping scene "Live" (0–2s) and a scene "Outage" (2–4s); "east" toggles `down` and "backup"
    /// plays Outage. "west" shows while up, "spare" while down.
    private func page() -> DottieDocument {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        var east = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 40), layerID: layer)
        east.text = "east"; east.click = ClickAction(toggle: ["down"])
        var west = Element(kind: .rectangle, frame: CGRect(x: 200, y: 0, width: 80, height: 40), layerID: layer)
        west.text = "west"; west.when = "!down"
        var spare = Element(kind: .rectangle, frame: CGRect(x: 200, y: 100, width: 80, height: 40), layerID: layer)
        spare.text = "spare"; spare.when = "down"
        var backup = Element(kind: .rectangle, frame: CGRect(x: 0, y: 100, width: 80, height: 40), layerID: layer)
        backup.text = "backup"; backup.click = ClickAction(scene: "outage")
        doc.elements = [east, west, spare, backup]
        doc.variables = ["down": false]
        var tl = Timeline(duration: 4)
        tl.fps = 10
        tl.setKey(Keyframe(t: 0, x: 0), for: east.id)
        tl.setKey(Keyframe(t: 4, x: 40), for: east.id)
        tl.addMarker(at: 0, name: "Live", loop: true)
        tl.addMarker(at: 2, name: "Outage")
        doc.timeline = tl
        return doc
    }

    func testStartingValuesPickWhatRendersDraw() throws {
        let doc = page()
        XCTAssertEqual(doc.still.elements.compactMap(\.text).sorted(), ["backup", "east", "west"])
        let down = doc.starting(with: ["down": true])
        XCTAssertEqual(down.still.elements.compactMap(\.text).sorted(), ["backup", "east", "spare"])
        XCTAssertEqual(down.variables, ["down": true])
        XCTAssertNotEqual(Exporter.svg(doc.still, background: nil), Exporter.svg(down.still, background: nil))
        // An empty choice changes nothing, so default exports (and goldens) don't move.
        XCTAssertEqual(doc.starting(with: [:]), doc)
    }

    func testAssignments() throws {
        XCTAssertEqual(try PageState.assignments("down=true, east=false"), ["down": true, "east": false])
        XCTAssertEqual(try PageState.assignments("down,!east"), ["down": true, "east": false])
        XCTAssertEqual(try PageState.assignments("a=off,b=1,c=2.5"), ["a": false, "b": 1, "c": 2.5], "numbers are numbers (ADR 0007)")
        XCTAssertThrowsError(try PageState.assignments("9x"))
        XCTAssertThrowsError(try PageState.assignments("down=maybe"))
    }

    /// The looping scene goes round instead of stopping; a toggle changes what is drawn without moving the playhead;
    /// a scene jump plays on and stops at the end, since the page has scenes.
    func testPlayingLoopsTogglesAndJumps() throws {
        var sim = try Simulation(page())
        XCTAssertTrue(sim.playing)
        XCTAssertEqual(sim.scene, "Live")
        sim.wait(1.5)
        XCTAssertEqual(sim.time, 1.5, accuracy: 1e-9)
        sim.wait(1)   // round the loop: 1.5 + 1 = 2.5, which is 0.5 into Live
        XCTAssertEqual(sim.time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(sim.scene, "Live")
        XCTAssertTrue(sim.playing)

        let did = try sim.click("east")
        XCTAssertTrue(did.contains("down=true"), did)
        XCTAssertTrue(did.contains("shows \"spare\"") && did.contains("hides \"west\""), did)
        XCTAssertEqual(sim.time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(sim.picture.elements.compactMap(\.text).sorted(), ["backup", "east", "spare"])
        XCTAssertEqual(sim.hiddenByState.compactMap(\.text), ["west"])

        XCTAssertTrue(try sim.click("BACKUP").contains("plays scene Outage"))
        XCTAssertEqual(sim.time, 2, accuracy: 1e-9)
        sim.wait(10)
        XCTAssertFalse(sim.playing)
        XCTAssertEqual(sim.time, 4, accuracy: 1e-9)
        XCTAssertEqual(sim.scene, "Outage")
        // Next from the end goes back to the start.
        sim.nextScene()
        XCTAssertEqual(sim.time, 0)
        XCTAssertTrue(sim.playing)
        XCTAssertEqual(sim.state, ["down": true])
    }

    /// Without a looping first scene the player stands at the start; `scene` starts at one, playing.
    func testStartsAndStops() throws {
        var doc = page()
        doc.timeline?.markers = [Marker(t: 0, name: "Live"), Marker(t: 2, name: "Outage")]
        var sim = try Simulation(doc)
        XCTAssertFalse(sim.playing)
        sim.wait(1)
        XCTAssertEqual(sim.time, 0)
        sim.nextScene()
        sim.wait(5)
        XCTAssertEqual(sim.time, 2, accuracy: 1e-9)   // stops on reaching Outage
        XCTAssertFalse(sim.playing)

        sim = try Simulation(doc, scene: "outage")
        XCTAssertEqual(sim.time, 2, accuracy: 1e-9)
        XCTAssertTrue(sim.playing)
        XCTAssertThrowsError(try Simulation(doc, scene: "nowhere"))
    }

    func testFindingWhatToClick() throws {
        var doc = page()
        let sim = try Simulation(doc)
        XCTAssertEqual(try sim.element(doc.elements[1].id.uuidString).text, "west")
        XCTAssertEqual(try sim.element(String(doc.elements[2].id.uuidString.prefix(8))).text, "spare")
        XCTAssertThrowsError(try sim.element("nobody"))
        var copy = doc.elements[1]
        copy.id = UUID(); copy.when = nil
        doc.elements.append(copy)
        XCTAssertThrowsError(try Simulation(doc).element("west")) { e in
            XCTAssertTrue("\(e)".contains("2 elements"), "\(e)")
        }
        var noClick = try Simulation(doc)
        XCTAssertEqual(try noClick.click("spare"), "does nothing (no click)")
    }
}
