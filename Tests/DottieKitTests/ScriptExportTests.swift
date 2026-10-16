import XCTest
@testable import DottieKit

/// `dottie render -f js`: dottie.js's player runtime plus the page, which dottie.js's own tests load in a browser.
final class ScriptExportTests: XCTestCase {
    private func tour() throws -> DottieDocument {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/design/tour.dottie")
        return try DottieFile.decode(Data(contentsOf: url)).pages[0]
    }

    func testCarriesTheRuntimeThePageAndTheOptions() throws {
        let page = try tour()
        let js = try Exporter.script(page, options: Exporter.ScriptOptions(at: 3.25, clean: true, label: "Tour </script>"))
        XCTAssertTrue(js.hasPrefix(PlayerScript.runtime))
        let loader = String(js.dropFirst(PlayerScript.runtime.count))
        XCTAssertFalse(loader.contains("DOTTIE_DATA"))
        XCTAssertFalse(loader.contains("</script"), "nothing can close an inline script tag")
        let data = try XCTUnwrap(loader.range(of: "var data = ").map { loader[$0.upperBound...] })
        let json = String(data[..<data.range(of: ", options = ")!.lowerBound])
        let file = try DottieFile.decode(Data(json.utf8))
        XCTAssertEqual(file.pages.map(\.id), [page.id])
        XCTAssertEqual(file.pages[0].timeline, page.timeline)
        XCTAssertTrue(loader.contains(#"options = {"at":"3.25","clean":"","label":"Tour <\/script>"}"#))
    }

    func testOnlyThePagesPicturesGoIn() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/edge/shapes.dottie")
        var page = try DottieFile.decode(Data(contentsOf: url)).pages[0]
        func loader(_ p: DottieDocument) throws -> String { String(try Exporter.script(p).dropFirst(PlayerScript.runtime.count)) }
        XCTAssertTrue(try loader(page).contains(#""images":{"#))
        page.elements.removeAll { $0.kind == .image }
        XCTAssertFalse(try loader(page).contains(#""images""#))
    }
}
