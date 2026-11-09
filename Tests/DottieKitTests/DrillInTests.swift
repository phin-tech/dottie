import XCTest
@testable import DottieKit

/// `DottieFile.drillIn`: a shape that leads to a page of its own, and `Simulation` following it there and back.
final class DrillInTests: XCTestCase {
    private func overview() -> (DottieFile, UUID) {
        var doc = DottieDocument()
        doc.name = "Overview"
        doc.theme = "chalkboard"
        var api = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 120, height: 60), layerID: doc.layers[0].id)
        api.text = "API\nthe front door"
        api.url = "https://example.com"
        doc.elements = [api]
        return (DottieFile(pages: [doc]), api.id)
    }

    func testMakesAPageWithATitleAndAWayBack() throws {
        var (file, api) = overview()
        let made = try file.drillIn(from: api)
        XCTAssertTrue(made.newPage)
        XCTAssertEqual(file.pages.map(\.name), ["Overview", "API"])
        let page = file.pages[1]
        XCTAssertEqual(page.theme, "chalkboard", "the new page keeps the look")
        let title = try XCTUnwrap(page.elements.first { $0.id == made.title })
        XCTAssertEqual(title.text, "API")
        let back = try XCTUnwrap(page.elements.first { $0.id == made.back })
        XCTAssertEqual(back.text, "← Overview")
        XCTAssertEqual(back.link, api)
        XCTAssertLessThan(back.frame.minY, title.frame.minY, "the way back is above the title")
        let source = file.pages[0].elements[0]
        XCTAssertEqual(source.link, made.title)
        XCTAssertNil(source.url, "a link replaces its url")
    }

    /// Again, it finds what it made instead of making more; a named page that exists is used, with its content kept below.
    func testReusesWhatIsThere() throws {
        var (file, api) = overview()
        let first = try file.drillIn(from: api)
        let again = try file.drillIn(from: api)
        XCTAssertEqual(again, DottieFile.DrillIn(page: first.page, title: first.title, back: first.back, newPage: false))
        XCTAssertEqual(file.pages.count, 2)
        XCTAssertEqual(file.pages[1].elements.count, 2)

        var details = DottieDocument()
        details.name = "Storage"
        var box = Element(kind: .rectangle, frame: CGRect(x: 300, y: 200, width: 80, height: 40), layerID: details.layers[0].id)
        box.text = "S3"
        details.elements = [box]
        file.pages.append(details)
        let made = try file.drillIn(from: api, pageName: "storage", back: false)
        XCTAssertFalse(made.newPage)
        XCTAssertNil(made.back)
        let title = try XCTUnwrap(file.pages[2].elements.first { $0.id == made.title })
        XCTAssertEqual(title.text, "Storage")
        XCTAssertEqual(title.frame.minX, 300)
        XCTAssertLessThan(title.frame.maxY, 200, "above what is on the page")
        XCTAssertEqual(file.pages[0].elements[0].link, made.title)
        XCTAssertThrowsError(try file.drillIn(from: UUID()))
    }

    func testSimulationFollowsTheLinkAndGoesBack() throws {
        var (file, api) = overview()
        file.pages[0].elements[0].url = nil
        try file.drillIn(from: api)
        var sim = try Simulation(file: file)
        XCTAssertTrue(sim.summary.hasPrefix("page Overview"), sim.summary)
        XCTAssertEqual(try sim.click("API\nthe front door"), "shows page API")
        XCTAssertEqual(sim.doc.name, "API")
        XCTAssertEqual(try sim.click("← Overview"), "shows page Overview")
        XCTAssertEqual(sim.back(), "back to page API")
        XCTAssertEqual(sim.back(), "back to page Overview")
        XCTAssertEqual(sim.back(), "nothing to go back to")
        // On its own, the page reports the link without following it.
        var alone = try Simulation(file.pages[0])
        XCTAssertTrue(try alone.click(api.uuidString).contains("not followed"))
    }

    func testARecordingFollowsThePages() throws {
        var (file, api) = overview()
        file.pages[0].elements[0].url = nil
        try file.drillIn(from: api)
        var sim = try Simulation(file: file)
        sim.record()
        sim.wait(0.25)
        try sim.click(api.uuidString)
        sim.wait(0.25)
        let r = try XCTUnwrap(sim.recording)
        XCTAssertEqual(r.pages.map(\.name), ["Overview", "API"])
        XCTAssertEqual(r.picture(0).name, "Overview")
        XCTAssertEqual(r.picture(r.frames.count - 1).name, "API")
        XCTAssertNotNil(Exporter.gif(r, scale: 0.5))
    }
}
