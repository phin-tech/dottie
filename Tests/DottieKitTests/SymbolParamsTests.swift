import XCTest
@testable import DottieKit

final class SymbolParamsTests: XCTestCase {
    private func fixture() throws -> DottieDocument {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/edge/params.dottie")
        return try DottieFile.decode(Data(contentsOf: url)).pages[0]
    }

    private func texts(_ page: DottieDocument, at t: Double, of instance: Int) -> [String] {
        var alone = page
        alone.elements = [page.elements[instance]]
        return alone.resolved(at: t).elements.compactMap(\.text)
    }

    func testCopiesShowTheirOwnValuesOrTheDefaults() throws {
        let page = try fixture()
        XCTAssertEqual(texts(page, at: 1, of: 0), ["Upload failed (3) {{missing}}", "Upload failed!", "by Sam"])
        XCTAssertEqual(texts(page, at: 1, of: 1), ["Saved (1) {{missing}}", "Saved!", "by me"], "no args: the defaults")
        XCTAssertEqual(texts(page, at: 3, of: 2), ["Later (1) {{missing}}", "Later!", "by me"], "an arg it doesn't declare is ignored")
        XCTAssertEqual(texts(page, at: 0, of: 3), ["{{message}}"], "a value is text, not filled in again")
    }

    func testTextTypesOutAfterFilling() throws {
        var page = try fixture()
        page.elements = [page.elements[0]]
        let note = try XCTUnwrap(page.resolved(at: 0.5).elements.first { $0.kind == .text })
        XCTAssertEqual(note.text, "Upload failed!", "the renderer types out the filled-in text")
        XCTAssertEqual(try XCTUnwrap(note.reveal), 0.5, accuracy: 1e-9)
    }

    func testAPoppedToastWaitsForItsMoment() throws {
        let page = try fixture()
        let toast = page.elements[2]
        let symbol = try XCTUnwrap(page.symbolIndex[try XCTUnwrap(toast.symbol)])
        XCTAssertEqual(symbol.localTime(1, playback: toast.playback, offset: toast.offset), 0, "before 1.5 s it rests at the start")
        XCTAssertEqual(symbol.localTime(2, playback: toast.playback, offset: toast.offset), 0.5, accuracy: 1e-9)
    }

    func testBreakingApartKeepsTheValues() throws {
        var page = try fixture()
        let ids = page.breakApart(page.elements[0].id)
        let texts = page.elements.filter { ids.contains($0.id) }.compactMap(\.text)
        XCTAssertTrue(texts.contains("Upload failed!"))
        XCTAssertTrue(texts.contains("by Sam"))
    }

    func testFilesKeepParamsAndArgs() throws {
        let page = try fixture()
        XCTAssertEqual(page.symbols?.first?.params, ["message": "Saved", "count": "1", "author": "me"])
        XCTAssertEqual(page.elements[0].args?["author"], "Sam")
        let again = try JSONDecoder().decode(DottieDocument.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(again, page)
    }

    func testScriptsDeclareAndFillParams() throws {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            const box = dottie.rect({x: 0, y: 0, width: 120, height: 40, text: "{{message}}"});
            const made = dottie.symbol([box], {name: "Toast", params: {message: "Saved"}});
            const copy = dottie.place("Toast", {x: 0, y: 100, args: {message: "Sent", n: 2}});
            dottie.update(made.instance, {args: {message: "Hi"}});
            return {symbols: dottie.symbols(), copy};
            """, on: &doc, selection: [], libraries: [.starter], timeLimit: 5)
        XCTAssertNil(r.error)
        let v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(r.value).utf8)) as? [String: Any])
        XCTAssertEqual((v["symbols"] as? [[String: Any]])?.first?["params"] as? [String: String], ["message": "Saved"])
        XCTAssertEqual((v["copy"] as? [String: Any])?["args"] as? [String: String], ["message": "Sent", "n": "2"])
        XCTAssertEqual(Set(doc.resolved(at: 0).elements.compactMap(\.text)), ["Hi", "Sent"])
    }
}
