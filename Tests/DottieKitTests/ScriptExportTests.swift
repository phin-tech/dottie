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

    private func clicks() throws -> DottieFile {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/edge/clicks.dottie")
        return try DottieFile.decode(Data(contentsOf: url))
    }

    private func parts(_ html: String) throws -> (file: DottieFile, options: [String: String]) {
        let data = try XCTUnwrap(html.range(of: "var data = ").map { html[$0.upperBound...] })
        let json = String(data[..<data.range(of: ", options = ")!.lowerBound])
        let opts = try XCTUnwrap(html.range(of: "options = ").map { html[$0.upperBound...] })
        let optionsJSON = String(opts[..<opts.range(of: ", fonts = ")!.lowerBound]).replacingOccurrences(of: "<\\/", with: "</")
        return (try DottieFile.decode(Data(json.utf8)),
                try JSONDecoder().decode([String: String].self, from: Data(optionsJSON.utf8)))
    }

    /// Every page in one web page: the player keeps history, starts where asked, and the tab is named after the page.
    func testEveryPageInOneWebPage() throws {
        let file = try clicks()
        let html = try XCTUnwrap(Exporter.player(file: file, title: "Clicks", start: "details"))
        let (inside, options) = try parts(html)
        XCTAssertEqual(inside.pages.map(\.name), ["Overview", "Details"])
        XCTAssertEqual(options, ["history": "", "page": "details"])
        XCTAssertTrue(html.contains("<title>Details · Clicks</title>"))
        XCTAssertTrue(html.contains(#"addEventListener("page""#))
        // One page alone has nothing to retitle.
        let single = try XCTUnwrap(Exporter.player(file: DottieFile(pages: [file.pages[0]]), title: "Clicks"))
        XCTAssertTrue(single.contains("<title>Clicks</title>"))
        XCTAssertFalse(single.contains(#"addEventListener("page""#))
    }

    /// A web page per page: each holds its own page, and a link to another page names that page's file.
    func testEveryPageAsAWebPageOfItsOwn() throws {
        let file = try clicks()
        let pages = try XCTUnwrap(Exporter.playerPages(file, title: "Clicks"))
        XCTAssertEqual(pages.map(\.name), ["index.html", "details.html"])
        let (first, options) = try parts(pages[0].html)
        XCTAssertEqual(first.pages.map(\.name), ["Overview"])
        let target = try XCTUnwrap(file.pages[0].elements.first { $0.text == "Details" }?.link)
        XCTAssertEqual(options["links"], #"{"\#(target.uuidString)":"details.html"}"#)
        XCTAssertNil(options["history"])
        let (second, back) = try parts(pages[1].html)
        XCTAssertEqual(second.pages.map(\.name), ["Details"])
        XCTAssertNil(back["links"], "Details links nowhere")
        XCTAssertTrue(pages[1].html.contains("<title>Details · Clicks</title>"))
    }

    func testPageFileNames() {
        let names = ["Overview", "Ünïcode & More!", "index", "Ünïcode & More!", "日本", ""]
        let file = DottieFile(pages: names.map { var d = DottieDocument(); d.name = $0; return d })
        XCTAssertEqual(Exporter.pageFileNames(file),
                       ["index.html", "unicode-more.html", "page-3.html", "unicode-more-2.html", "page-5.html", "page-6.html"])
    }
}
