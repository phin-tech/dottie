import XCTest
@testable import DottieKit

final class MagicMoveTests: XCTestCase {
    private func box(_ doc: inout DottieDocument, _ r: CGRect, text: String? = nil, anchor: String? = nil) throws -> Element {
        let e = try DiagramOps.addShape(&doc, kind: .rectangle, frame: r, at: .zero, text: text, fill: nil, stroke: nil, roughness: 1)
        if let anchor { doc.elements[doc.elements.firstIndex { $0.id == e.id }!].anchor = anchor }
        return doc.elements.first { $0.id == e.id }!
    }

    /// Three anchored boxes in a row, then the same three in a column, with new ids and seeds.
    private func twoPages() throws -> (DottieDocument, DottieDocument) {
        var a = DottieDocument(), b = DottieDocument()
        for (i, n) in ["one", "two", "three"].enumerated() {
            _ = try box(&a, CGRect(x: 40 + Double(i) * 160, y: 40, width: 100, height: 60), anchor: n)
            _ = try box(&b, CGRect(x: 300, y: 40 + Double(i) * 120, width: 140, height: 80), anchor: n)
        }
        return (a, b)
    }

    func testAnchoredBoxesEndWhereTheSecondPageHasThem() throws {
        var (a, b) = try twoPages()
        let s = try a.magicMove(to: b, duration: 1.5)
        XCTAssertEqual(s, MagicMoveSummary(moved: 3, entering: 0, leaving: 0))
        XCTAssertEqual(a.timeline?.duration ?? 0, 1.5, accuracy: 1e-9)
        let start = a.resolved(at: 0), end = a.resolved(at: 1.5)
        for n in ["one", "two", "three"] {
            let mine = a.elements.first { $0.anchor == n }!, theirs = b.elements.first { $0.anchor == n }!
            XCTAssertEqual(start.elements.first { $0.id == mine.id }?.frame, mine.frame, "\(n) starts where it was")
            XCTAssertEqual(end.elements.first { $0.id == mine.id }?.frame, theirs.frame, "\(n) ends where the second page has it")
        }
        let mid = a.resolved(at: 0.75).elements.first { $0.anchor == "two" }!
        XCTAssertNotEqual(mid.frame, a.elements.first { $0.anchor == "two" }!.frame, "and moves in between")
    }

    func testExtrasFadeOutAndInAndConnectorsFollow() throws {
        var (a, b) = try twoPages()
        let gone = try box(&a, CGRect(x: 40, y: 300, width: 80, height: 40), text: "only here")
        let new = try box(&b, CGRect(x: 600, y: 300, width: 80, height: 40), text: "only there")
        let one = { (d: DottieDocument) in d.elements.first { $0.anchor == "one" }!.id }
        let two = { (d: DottieDocument) in d.elements.first { $0.anchor == "two" }!.id }
        _ = try DiagramOps.addConnector(&a, from: one(a), to: two(a))       // on both pages: stays
        _ = try DiagramOps.addConnector(&a, from: one(a), to: gone.id)      // only here: fades out
        _ = try DiagramOps.addConnector(&b, from: one(b), to: two(b))
        _ = try DiagramOps.addConnector(&b, from: two(b), to: new.id)       // only there: copied in
        let s = try a.magicMove(to: b, at: 0.5, duration: 1)
        XCTAssertEqual(s, MagicMoveSummary(moved: 3, entering: 2, leaving: 2))

        let before = a.resolved(at: 0.4), after = a.resolved(at: 1.5)
        XCTAssertTrue(before.elements.contains { $0.id == gone.id })
        XCTAssertFalse(before.elements.contains { $0.text == "only there" }, "the copy waits, hidden")
        XCTAssertFalse(after.elements.contains { $0.id == gone.id })
        let copy = try XCTUnwrap(after.elements.first { $0.text == "only there" })
        XCTAssertEqual(copy.frame, new.frame)
        XCTAssertNotEqual(copy.id, new.id, "a copy gets its own id")
        let links = after.elements.compactMap(\.connector)
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(links.contains { $0.start.elementID == one(a) && $0.end.elementID == two(a) })
        XCTAssertTrue(links.contains { $0.start.elementID == two(a) && $0.end.elementID == copy.id }, "bound to this page's shapes")
        let halfway = a.resolved(at: 1).elements.first { $0.text == "only there" }?.style.opacity ?? 1
        XCTAssert(halfway > 0 && halfway < 1, "fading in halfway through")
    }

    func testMatchesADuplicatedPageBySeedAndRunsTwiceWithoutCopyingTwice() throws {
        var file = DottieFile(pages: [DottieDocument()])
        var first = file.pages[0]
        let plain = try box(&first, CGRect(x: 0, y: 0, width: 50, height: 50))
        file.pages[0] = first
        let id = try XCTUnwrap(file.duplicatePage(first.id))
        var second = file.page(id)!
        second.elements[0].x = 400
        let s = try first.magicMove(to: second)
        XCTAssertEqual(s, MagicMoveSummary(moved: 1, entering: 0, leaving: 0))
        XCTAssertEqual(first.resolved(at: 1).elements.first { $0.id == plain.id }?.x, 400)

        _ = try box(&second, CGRect(x: 0, y: 200, width: 50, height: 50), text: "late")
        _ = try first.magicMove(to: second)
        let again = try first.magicMove(to: second)
        XCTAssertEqual(again.entering, 0, "the copy from last time is matched, not copied again")
        XCTAssertEqual(first.elements.filter { $0.text == "late" }.count, 1)
    }

    func testTweensColorAndRotationAndRefusesItself() throws {
        var a = DottieDocument(), b = DottieDocument()
        var e = try box(&a, CGRect(x: 0, y: 0, width: 50, height: 50), text: "x")
        e = try box(&b, CGRect(x: 0, y: 0, width: 50, height: 50), text: "x")
        let i = b.elements.firstIndex { $0.id == e.id }!
        b.elements[i].rotation = 1
        b.elements[i].style.fill = RGBA(r: 1, g: 0, b: 0)
        try a.magicMove(to: b, ease: .spring)
        let end = a.resolved(at: 1).elements[0]
        XCTAssertEqual(end.rotation ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(end.style.fill, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(a.timeline?.tracks[0].keys.first?.ease, .spring)
        XCTAssertThrowsError(try a.magicMove(to: a))
    }

    func testScriptMagicMoveByPageName() throws {
        var (a, b) = try twoPages()
        b.name = "After"
        let file = DottieFile(pages: [a, b])
        let r = DottieScript.run(#"return dottie.magicMove("After", {duration: 2})"#, on: &a, in: file, libraries: [.starter])
        XCTAssertNil(r.error)
        let value = try JSONSerialization.jsonObject(with: Data((r.value ?? "").utf8)) as? [String: Int]
        XCTAssertEqual(value, ["moved": 3, "entering": 0, "leaving": 0])
        XCTAssertEqual(a.timeline?.duration, 2)
        let r2 = DottieScript.run(#"dottie.magicMove(2)"#, on: &a, in: file, libraries: [.starter])
        XCTAssertNil(r2.error, "by number too")
        let r3 = DottieScript.run(#"dottie.magicMove("Nowhere")"#, on: &a, in: file, libraries: [.starter])
        XCTAssertNotNil(r3.error)
    }
}
