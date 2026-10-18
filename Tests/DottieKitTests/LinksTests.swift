import XCTest
import PDFKit
@testable import DottieKit

/// Links outside the drawing (`url`), anchors as destinations, and links in PDF and SVG exports.
final class LinksTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, _ x: Double, _ y: Double, _ text: String? = nil) throws -> UUID {
        try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: x, y: y, width: 80, height: 40), at: .zero,
                                text: text, fill: nil, stroke: nil, roughness: 0).id
    }

    func testOutsideLinksAreWebAddressesOrDrawings() {
        XCTAssertEqual(OutsideLink(" https://example.com/a "), .web("https://example.com/a"))
        XCTAssertEqual(OutsideLink("mailto:a@b.c"), .web("mailto:a@b.c"))
        XCTAssertEqual(OutsideLink("plans/next.dottie"), .drawing(path: "plans/next.dottie", anchor: nil))
        XCTAssertEqual(OutsideLink("../Next%20Plan.dottie#Login%20form"), .drawing(path: "../Next Plan.dottie", anchor: "Login form"))
        XCTAssertEqual(OutsideLink("/Users/me/a.DOTTIE#"), .drawing(path: "/Users/me/a.DOTTIE", anchor: nil))
        for bad in ["", "javascript:alert(1)", "file:///etc/a.dottie", "data:x.dottie", "notes.txt", ".dottie", "a.dottie\u{7}"] {
            XCTAssertNil(OutsideLink(bad), bad)
        }
        XCTAssertEqual(OutsideLink("a b.dottie#Top")?.string, "a b.dottie#Top")
    }

    func testDrawingLinksResolveNextToTheLinkingFile() {
        let base = URL(fileURLWithPath: "/tmp/plans/overview.dottie")
        XCTAssertEqual(OutsideLink("next.dottie")?.fileURL(relativeTo: base)?.path, "/tmp/plans/next.dottie")
        XCTAssertEqual(OutsideLink("../a.dottie")?.fileURL(relativeTo: base)?.path, "/tmp/a.dottie")
        XCTAssertEqual(OutsideLink("/x/b.dottie")?.fileURL(relativeTo: nil)?.path, "/x/b.dottie")
        XCTAssertNil(OutsideLink("next.dottie")?.fileURL(relativeTo: nil), "an unsaved drawing has nowhere to start from")
        XCTAssertNil(OutsideLink("https://example.com")?.fileURL(relativeTo: base))
    }

    func testLinksToDrawingsAreRelativeWhenTheyLiveTogether() {
        let base = URL(fileURLWithPath: "/Users/me/plans/overview.dottie")
        XCTAssertEqual(OutsideLink.drawing(at: URL(fileURLWithPath: "/Users/me/plans/next.dottie"), from: base).string, "next.dottie")
        XCTAssertEqual(OutsideLink.drawing(at: URL(fileURLWithPath: "/Users/me/old/a b.dottie"), from: base, anchor: "Top").string,
                       "../old/a b.dottie#Top")
        XCTAssertEqual(OutsideLink.drawing(at: URL(fileURLWithPath: "/Users/me/plans/sub/c.dottie"), from: base).string, "sub/c.dottie")
        XCTAssertEqual(OutsideLink.drawing(at: URL(fileURLWithPath: "/Volumes/X/d.dottie"), from: base).string, "/Volumes/X/d.dottie",
                       "only the root in common: absolute")
        XCTAssertEqual(OutsideLink.drawing(at: URL(fileURLWithPath: "/Users/me/e.dottie"), from: nil, anchor: "").string, "/Users/me/e.dottie")
        // Written and read back, the link leads to the same file.
        let link = OutsideLink.drawing(at: URL(fileURLWithPath: "/Users/me/old/a b.dottie"), from: base)
        XCTAssertEqual(OutsideLink(link.string)?.fileURL(relativeTo: base)?.path, "/Users/me/old/a b.dottie")
    }

    func testURLAndLinkAreOneOrTheOther() throws {
        var doc = DottieDocument()
        let a = try box(&doc, 0, 0), b = try box(&doc, 200, 0, "B")
        try DiagramOps.update(&doc, id: a, link: .some(b))
        try DiagramOps.update(&doc, id: a, url: .some(" next.dottie#Top "))
        XCTAssertEqual(doc.elements[0].url, "next.dottie#Top")
        XCTAssertNil(doc.elements[0].link, "an outside link replaces a link to an element")
        XCTAssertEqual(DiagramOps.summarize(doc)[0].url, "next.dottie#Top")
        try DiagramOps.update(&doc, id: a, link: .some(b))
        XCTAssertNil(doc.elements[0].url, "and the other way round")
        try DiagramOps.update(&doc, id: a, url: .some("https://example.com"))
        try DiagramOps.update(&doc, id: a, url: .some(""))
        XCTAssertNil(doc.elements[0].url)
        XCTAssertThrowsError(try DiagramOps.update(&doc, id: a, url: .some("javascript:alert(1)")))
        let back = try DottieDocument.decode(try { var d = doc; try d.setURL([a], to: "x.dottie"); return try d.encoded() }())
        XCTAssertEqual(back.elements[0].url, "x.dottie")
    }

    func testDestinationsAreAnchorsThenPages() throws {
        var file = DottieFile()
        let a = try box(&file.pages[0], 0, 0)
        file.pages[0].elements[0].anchor = "Login"
        let second = file.addPage(name: "Billing")
        let b = try box(&file.pages[1], 0, 0)
        file.pages[1].elements[0].anchor = "login"   // the exact match wins over this one
        XCTAssertEqual(file.destination("Login"), .element(a))
        XCTAssertEqual(file.destination("LOGIN"), .element(a))
        XCTAssertEqual(file.destination("billing"), .page(second))
        XCTAssertEqual(file.destination("2"), .page(second))
        XCTAssertNil(file.destination("Nowhere"))
        XCTAssertEqual(file.anchors.map(\.element), [a, b])
        XCTAssertEqual(file.anchors.map(\.page), [file.pages[0].id, second])
    }

    func testWebPlayersOpenAWebURLWhenThereIsNoClick() throws {
        var doc = DottieDocument()
        let a = try box(&doc, 0, 0), b = try box(&doc, 100, 0), c = try box(&doc, 200, 0)
        try doc.setURL([a], to: "https://example.com/a")
        try doc.setURL([b], to: "next.dottie")
        try doc.setURL([c], to: "https://example.com/c")
        doc.elements[2].click = ClickAction(url: "https://example.com/click")
        XCTAssertEqual(doc.clickTargets[a], .url("https://example.com/a"))
        XCTAssertNil(doc.clickTargets[b], "a link to another drawing does nothing on the web")
        XCTAssertEqual(doc.clickTargets[c], .url("https://example.com/click"), "a click wins")
    }

    func testSVGWrapsWebLinksAndEscapesThem() throws {
        var doc = DottieDocument()
        let a = try box(&doc, 0, 0, "A"), b = try box(&doc, 200, 0, "B")
        try doc.setURL([a], to: "https://example.com/?q=\"x\"&y=<z>")
        try doc.setURL([b], to: "next.dottie")
        let svg = Exporter.svg(doc)
        XCTAssertTrue(svg.contains(#"<a href="https://example.com/?q=&quot;x&quot;&amp;y=&lt;z&gt;" target="_blank">"#), svg)
        XCTAssertEqual(svg.components(separatedBy: "<a ").count, 2, "only web links become links")
        XCTAssertFalse(Exporter.html(doc).isEmpty)
    }

    /// The link annotations on each page of a PDF, with where they lead.
    private func annotations(_ data: Data?) throws -> [[(bounds: CGRect, url: String?, page: Int?)]] {
        let pdf = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(data)))
        return (0..<pdf.pageCount).map { i in
            pdf.page(at: i)!.annotations.filter { $0.type == "Link" }.map { a in
                (a.bounds, a.url?.absoluteString ?? (a.action as? PDFActionURL)?.url?.absoluteString,
                 (a.destination?.page ?? (a.action as? PDFActionGoTo)?.destination.page).map { pdf.index(for: $0) })
            }
        }
    }

    func testPDFLinksOpenWebAddressesAndJumpBetweenPages() throws {
        var file = DottieFile()
        let a = try box(&file.pages[0], 0, 0, "A"), web = try box(&file.pages[0], 0, 100, "Web")
        try file.pages[0].setURL([web], to: "https://example.com/docs")
        file.addPage()
        let b = try box(&file.pages[1], 50, 50, "B")
        try file.pages[0].setLink([a], to: b, otherPages: file.pages)

        let pages = try annotations(Exporter.pdf(file))
        XCTAssertEqual(pages.count, 2)
        let jump = try XCTUnwrap(pages[0].first { $0.page != nil })
        XCTAssertEqual(jump.page, 1, "the link jumps to the second page")
        // The page shows the drawing's bounds (24 pt of padding around the shapes), y up.
        XCTAssertEqual(jump.bounds.minX, 24, accuracy: 1)
        XCTAssertEqual(jump.bounds.width, 80, accuracy: 1)
        let link = try XCTUnwrap(pages[0].first { $0.url != nil })
        XCTAssertEqual(link.url, "https://example.com/docs")
        XCTAssertEqual(link.bounds.minY, 24, accuracy: 1, "the lower box is near the bottom of the page")
        XCTAssertTrue(pages[1].isEmpty)
    }

    func testOnePagePDFKeepsLinksOnThatPage() throws {
        var file = DottieFile()
        let a = try box(&file.pages[0], 0, 0), b = try box(&file.pages[0], 200, 0)
        try file.pages[0].setLink([a], to: b)
        file.addPage()
        let elsewhere = try box(&file.pages[1], 0, 0)
        let c = try box(&file.pages[0], 0, 100)
        try file.pages[0].setLink([c], to: elsewhere, otherPages: file.pages)
        let pages = try annotations(Exporter.pdf(file.pages[0]))
        XCTAssertEqual(pages[0].count, 1, "a link to another page has nowhere to go in a one-page PDF")
        XCTAssertEqual(pages[0][0].page, 0)
    }
}
