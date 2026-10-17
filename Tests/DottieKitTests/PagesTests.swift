import XCTest
@testable import DottieKit

final class PagesTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, _ text: String, x: Double = 0) throws -> Element {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: x, y: 0, width: 80, height: 40), at: .zero,
                                text: text, fill: nil, stroke: nil, roughness: 0)
    }

    func testFileRoundTripsEveryPage() throws {
        var file = DottieFile()
        _ = try box(&file.pages[0], "A")
        let second = file.addPage(name: "Details")
        let i = try XCTUnwrap(file.index(of: second))
        _ = try box(&file.pages[i], "B")
        let back = try DottieFile.decode(file.encoded())
        XCTAssertEqual(back, file)
        XCTAssertEqual(back.pages.map(\.name), ["Page 1", "Details"])
    }

    func testDecodeRejectsNoPagesAndSharedIds() throws {
        XCTAssertThrowsError(try DottieFile.decode(Data(#"{"version":2,"pages":[]}"#.utf8)))
        let page = DottieDocument()
        var file = DottieFile(pages: [page, page])
        file.version = 2
        XCTAssertThrowsError(try DottieFile.decode(file.encoded()))
    }

    func testPageNamesAndLookup() {
        var file = DottieFile()
        file.addPage()
        file.addPage(name: "Overview")
        file.addPage(name: "overview")
        XCTAssertEqual(file.pages.map(\.name), ["Page 1", "Page 2", "Overview", "overview 2"])
        file.renamePage(file.pages[0].id, to: "page 1")
        XCTAssertEqual(file.pages[0].name, "page 1", "a change of case is not a clash with itself")
        file.renamePage(file.pages[0].id, to: "Page 2")
        XCTAssertEqual(file.pages[0].name, "Page 2 2")
        XCTAssertEqual(file.pageIndex(matching: "OVERVIEW"), 2)
        XCTAssertEqual(file.pageIndex(matching: "2"), 1)
        XCTAssertNil(file.pageIndex(matching: "9"))
        // Inserted after the given page.
        let id = file.addPage(name: "Inserted", after: file.pages[0].id)
        XCTAssertEqual(file.index(of: id), 1)
    }

    func testLastPageCannotBeRemoved() {
        var file = DottieFile()
        XCTAssertFalse(file.removePage(file.pages[0].id))
        let id = file.addPage()
        XCTAssertTrue(file.removePage(id))
        XCTAssertEqual(file.pages.count, 1)
    }

    func testMovePage() {
        var file = DottieFile()
        let b = file.addPage(name: "B"), c = file.addPage(name: "C")
        file.movePage(c, to: 0)
        XCTAssertEqual(file.pages.map(\.name), ["C", "Page 1", "B"])
        file.movePage(c, to: 2)
        XCTAssertEqual(file.pages.map(\.name), ["Page 1", "B", "C"])
        _ = b
    }

    func testLinkToAnotherPage() throws {
        var file = DottieFile()
        let a = try box(&file.pages[0], "A")
        let added = file.addPage()
        let p2 = try XCTUnwrap(file.index(of: added))
        let b = try box(&file.pages[p2], "B")
        // Not found on this page alone…
        var alone = file.pages[0]
        XCTAssertThrowsError(try alone.setLink([a.id], to: b.id))
        // …but found among the other pages.
        try file.pages[0].setLink([a.id], to: b.id, otherPages: file.pages)
        XCTAssertEqual(file.pages[0].elements[0].link, b.id)
        XCTAssertEqual(file.linkTargetPages[b.id], file.pages[p2].id)
    }

    func testLinkTargetsSkipHiddenLayersAndConnectors() throws {
        var file = DottieFile()
        let a = try box(&file.pages[0], "A"), b = try box(&file.pages[0], "B", x: 200)
        let c = try DiagramOps.addConnector(&file.pages[0], from: a.id, to: b.id)
        XCTAssertNotNil(file.linkTargetPages[a.id])
        XCTAssertNil(file.linkTargetPages[c.id])
        file.pages[0].layers[0].visible = false
        XCTAssertNil(file.linkTargetPages[a.id])
    }

    func testDuplicatePageGivesFreshIdsAndKeepsStructure() throws {
        var file = DottieFile()
        let a = try box(&file.pages[0], "A"), b = try box(&file.pages[0], "B", x: 200)
        try DiagramOps.addConnector(&file.pages[0], from: a.id, to: b.id)
        file.pages[0].group([a.id, b.id])
        let added = file.addPage(name: "Other")
        let p2 = try XCTUnwrap(file.index(of: added))
        let far = try box(&file.pages[p2], "Far")
        try file.pages[0].setLink([a.id], to: b.id)
        try file.pages[0].setLink([b.id], to: far.id, otherPages: file.pages)

        let copyID = try XCTUnwrap(file.duplicatePage(file.pages[0].id))
        XCTAssertEqual(file.index(of: copyID), 1, "the copy sits next to the original")
        let original = file.pages[0], copy = try XCTUnwrap(file.page(copyID))
        XCTAssertEqual(copy.name, "Page 1 copy")

        let all = file.pages.flatMap { $0.elements.map(\.id) }
        XCTAssertEqual(Set(all).count, all.count, "element ids stay unique across the file")

        let copyIDs = Set(copy.elements.map(\.id))
        let ca = try XCTUnwrap(copy.elements.first { $0.text == "A" })
        let cb = try XCTUnwrap(copy.elements.first { $0.text == "B" })
        let cc = try XCTUnwrap(copy.elements.first { $0.kind == .connector })
        XCTAssertEqual(cc.connector?.start.elementID, ca.id)
        XCTAssertEqual(cc.connector?.end.elementID, cb.id)
        XCTAssertEqual(ca.link, cb.id, "a link within the page follows the copy")
        XCTAssertEqual(cb.link, far.id, "a link to another page is kept")
        XCTAssertNotNil(ca.groupID)
        XCTAssertEqual(ca.groupID, cb.groupID)
        XCTAssertNotEqual(ca.groupID, original.elements.first { $0.id == a.id }?.groupID)
        XCTAssertTrue(copyIDs.isDisjoint(with: original.elements.map(\.id)))
    }

    func testPasteKeepsLinksToOtherPages() throws {
        var file = DottieFile()
        let a = try box(&file.pages[0], "A")
        let added = file.addPage()
        let p2 = try XCTUnwrap(file.index(of: added))
        let b = try box(&file.pages[p2], "B")
        try file.pages[0].setLink([a.id], to: b.id, otherPages: file.pages)
        let data = try JSONEncoder().encode(file.pages[0].elements)

        var target = DottieDocument()
        target.paste(data)
        XCTAssertNil(target.elements[0].link, "without the file, the target is unknown")
        var kept = DottieDocument()
        kept.paste(data, keepsLink: { file.pageIndex(containing: $0) != nil })
        XCTAssertEqual(kept.elements[0].link, b.id)
    }

    func testScriptSeesPagesAndLinksAcross() throws {
        var file = DottieFile()
        let added = file.addPage(name: "Details")
        let p2 = try XCTUnwrap(file.index(of: added))
        let b = try box(&file.pages[p2], "Target")
        var doc = file.pages[0]
        let r = DottieScript.run("""
            const pages = dottie.pages();
            const target = pages[1].shapes[0];
            const a = dottie.rect({x: 0, y: 0, text: "From"});
            dottie.update(a, {link: target.id});
            return pages.map(p => p.name + (p.current ? "*" : ""));
            """, on: &doc, in: file, libraries: [.starter])
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, #"["Page 1*","Details"]"#)
        XCTAssertEqual(doc.elements.first?.link, b.id)
    }
}

final class VersionTests: XCTestCase {
    /// The app's version (project.yml) and the tools' (DottieVersion) are bumped together by `just bump`.
    func testToolVersionMatchesTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let line = try XCTUnwrap(yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") })
        XCTAssertEqual(line.split(separator: "\"").dropFirst().first.map(String.init), DottieVersion.current)
    }
}
