import XCTest
@testable import DottieKit

final class SymbolTests: XCTestCase {
    /// A 100 × 50 symbol: a box that slides right over 2 s, and a dot that appears halfway.
    private func gear() -> (page: DottieDocument, symbol: Symbol, box: Element, dot: Element) {
        let layer = Layer(name: "L")
        var box = Element(kind: .rectangle, frame: CGRect(x: 10, y: 10, width: 20, height: 20), layerID: layer.id)
        box.style.roughness = 0
        var dot = Element(kind: .ellipse, frame: CGRect(x: 60, y: 10, width: 10, height: 10), layerID: layer.id)
        dot.style.roughness = 0
        var tl = Timeline(fps: 10, duration: 2)
        tl.setKey(Keyframe(t: 0, x: 10), for: box.id)
        tl.setKey(Keyframe(t: 2, x: 70), for: box.id)
        tl.setKey(Keyframe(t: 1, visible: true), for: dot.id)
        let symbol = Symbol(name: "Gear", width: 100, height: 50, layers: [layer], elements: [box, dot], timeline: tl)
        var page = DottieDocument()
        page.symbols = [symbol]
        page.timeline = Timeline(fps: 10, duration: 4)
        return (page, symbol, box, dot)
    }

    func testLoopsLandOnTheEndPose() {
        let s = gear().symbol
        XCTAssertEqual(s.localTime(0, playback: nil, offset: nil), 0)
        XCTAssertEqual(s.localTime(0.5, playback: nil, offset: nil), 0.5)
        XCTAssertEqual(s.localTime(2, playback: nil, offset: nil), 2, "a whole loop shows the end, as the last frame does")
        XCTAssertEqual(s.localTime(0.1 * 40, playback: nil, offset: nil), 2, "even with rounding error")
        XCTAssertEqual(s.localTime(2.5, playback: nil, offset: nil), 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.localTime(0.5, playback: nil, offset: 1), 1.5)
        XCTAssertEqual(s.localTime(0.5, playback: nil, offset: -1), 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.localTime(5, playback: .once, offset: nil), 2)
        XCTAssertEqual(s.localTime(0.5, playback: .still, offset: nil), 2)
    }

    func testInstancesPlaceScaleAndTurnTheirSymbol() throws {
        var (page, symbol, box, _) = gear()
        let a = try XCTUnwrap(page.placeSymbol(symbol.id, at: CGPoint(x: 200, y: 100), size: CGSize(width: 200, height: 100)))
        var b = try XCTUnwrap(page.placeSymbol(symbol.id, at: CGPoint(x: 0, y: 300)))
        b.rotation = .pi / 2
        page.elements[1] = b
        let f = page.resolved(at: 0)
        XCTAssertFalse(f.hasInstances)
        let inA = try XCTUnwrap(f.elements.first { $0.id == DottieDocument.derivedID(a.id, box.id) })
        XCTAssertEqual(inA.frame, CGRect(x: 220, y: 120, width: 40, height: 40), "scaled ×2 into the frame")
        XCTAssertEqual(inA.style.strokeWidth, 4, "lines scale with it")
        let inB = try XCTUnwrap(f.elements.first { $0.id == DottieDocument.derivedID(b.id, box.id) })
        // Box center (20, 20) in a 100 × 50 frame centered at (50, 325), turned a quarter.
        XCTAssertEqual(inB.frame.midX, 50 + 5, accuracy: 1e-9)
        XCTAssertEqual(inB.frame.midY, 325 - 30, accuracy: 1e-9)
        XCTAssertEqual(inB.angle, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(f.elements.count, 2, "the dot hasn't appeared yet in either")
        XCTAssertEqual(page.resolved(at: 1.5).elements.count, 4)
        XCTAssertNotEqual(inA.seed, inB.seed, "copies differ a little, as hand-drawn copies do")
        XCTAssertEqual(page.resolved(at: 0).elements.map(\.id), f.elements.map(\.id), "the same ids every time")
    }

    func testConnectorsInsideAndOutsideFollowTheInstance() throws {
        var (page, symbol, box, dot) = gear()
        var inner = page.symbols![0]
        inner.elements.append(Element(kind: .connector, frame: .zero, layerID: inner.layers[0].id,
                                      connector: ConnectorData(start: .bound(box.id), end: .bound(dot.id))))
        page.symbols = [inner]
        let inst = try XCTUnwrap(page.placeSymbol(symbol.id, at: CGPoint(x: 300, y: 0)))
        let other = try DiagramOps.addShape(&page, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 50, height: 50), at: .zero,
                                            text: nil, fill: nil, stroke: nil, roughness: 0)
        let line = try DiagramOps.addConnector(&page, from: other.id, to: inst.id)
        let f = page.resolved(at: 1.5)
        let c = try XCTUnwrap(f.elements.first { $0.id == DottieDocument.derivedID(inst.id, inner.elements[2].id) }?.connector)
        XCTAssertEqual(c.start.elementID, DottieDocument.derivedID(inst.id, box.id))
        XCTAssertEqual(c.end.elementID, DottieDocument.derivedID(inst.id, dot.id))
        let pinned = try XCTUnwrap(f.elements.first { $0.id == line.id }?.connector)
        XCTAssertEqual(pinned.end.elementID, nil, "pinned where it met the instance")
        XCTAssertEqual(pinned.end.x, 300, accuracy: 1, "at the instance's left edge")
        XCTAssertNotNil(Exporter.png(page.still, scale: 1))
    }

    func testCyclesAndFloodsAreCut() throws {
        var page = DottieDocument()
        let layer = page.layers[0].id
        // A symbol that contains itself draws its own box, once.
        var loop = Symbol(name: "Loop", width: 10, height: 10, elements: [])
        var me = Element(kind: .symbol, frame: CGRect(x: 0, y: 0, width: 10, height: 10), layerID: loop.layers[0].id)
        me.symbol = loop.id
        loop.elements = [Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), layerID: loop.layers[0].id), me]
        // Ten symbols of ten instances of the next: 10^10 elements, unless capped.
        var chain: [Symbol] = []
        var next: UUID?
        for i in 0..<10 {
            var s = Symbol(name: "S\(i)", width: 10, height: 10)
            s.elements = (0..<10).map { k in
                if let next {
                    var e = Element(kind: .symbol, frame: CGRect(x: Double(k), y: 0, width: 1, height: 1), layerID: s.layers[0].id)
                    e.symbol = next
                    return e
                }
                return Element(kind: .rectangle, frame: CGRect(x: Double(k), y: 0, width: 1, height: 1), layerID: s.layers[0].id)
            }
            chain.append(s); next = s.id
        }
        page.symbols = [loop] + chain
        page.placeSymbol(loop.id, at: .zero)
        page.placeSymbol(next!, at: CGPoint(x: 50, y: 0))
        _ = layer
        let start = Date()
        let f = page.resolved(at: 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertLessThanOrEqual(f.elements.count, Symbol.maxElements)
        XCTAssertEqual(f.elements.filter { $0.kind == .rectangle && $0.width == 10 }.count, 1, "the loop's own box, once")
    }

    func testMakingASymbolKeepsEveryFrame() throws {
        var page = DottieDocument()
        let a = try DiagramOps.addShape(&page, kind: .rectangle, frame: CGRect(x: 40, y: 40, width: 80, height: 40), at: .zero,
                                        text: "A", fill: RGBA(r: 1, g: 0.8, b: 0.3), stroke: nil, roughness: 0)
        let b = try DiagramOps.addShape(&page, kind: .ellipse, frame: CGRect(x: 200, y: 60, width: 40, height: 40), at: .zero,
                                        text: nil, fill: nil, stroke: nil, roughness: 0)
        let line = try DiagramOps.addConnector(&page, from: a.id, to: b.id, roughness: 0)
        let outside = try DiagramOps.addShape(&page, kind: .diamond, frame: CGRect(x: 40, y: 200, width: 60, height: 60), at: .zero,
                                              text: "out", fill: nil, stroke: nil, roughness: 0)
        let toB = try DiagramOps.addConnector(&page, from: outside.id, to: b.id, roughness: 0)
        page.elements[page.elements.firstIndex { $0.id == outside.id }!].link = a.id
        var tl = Timeline(fps: 8, duration: 2)
        tl.setKey(Keyframe(t: 0, x: 200, rotation: 0), for: b.id)
        tl.setKey(Keyframe(t: 2, x: 320, rotation: 1), for: b.id)
        page.timeline = tl
        try page.addTransition(.popIn, to: a.id, at: 0.25)
        let before = page

        let made = try XCTUnwrap(page.makeSymbol(of: [a.id, b.id, line.id], name: "Pair"))
        XCTAssertEqual(page.elements.map(\.id), [made.instance.id, outside.id, toB.id])
        XCTAssertEqual(made.symbol.elements.count, 3)
        XCTAssertEqual(page.elements.first { $0.id == toB.id }?.connector?.end.elementID, made.instance.id)
        XCTAssertEqual(page.elements.first { $0.id == outside.id }?.link, made.instance.id)
        XCTAssertTrue(page.timeline!.tracks.isEmpty)
        for t in before.timeline!.frameTimes where t != 0 {
            // The arrow from outside now meets the instance's frame rather than the ellipse.
            func svg(_ d: DottieDocument) -> String {
                var f = d.resolved(at: t)
                f.elements.removeAll { $0.id == toB.id }
                return Exporter.svg(f)
            }
            XCTAssertEqual(svg(page), svg(before), "t = \(t)")
        }
    }

    func testBreakingApartLeavesPlainShapes() throws {
        var (page, symbol, _, _) = gear()
        let inst = try XCTUnwrap(page.placeSymbol(symbol.id, at: CGPoint(x: 100, y: 100)))
        let ids = page.breakApart(inst.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertFalse(page.hasInstances)
        XCTAssertEqual(page.elements.first { $0.kind == .rectangle }?.frame, CGRect(x: 110, y: 110, width: 20, height: 20))
        page.pruneSymbols()
        XCTAssertNil(page.symbols)
    }

    func testPosingAnInstanceKeysTheInstance() throws {
        var (page, symbol, _, _) = gear()
        let inst = try XCTUnwrap(page.placeSymbol(symbol.id, at: CGPoint(x: 0, y: 0)))
        var edited = page.posed(at: 1)
        XCTAssertTrue(edited.hasInstances, "the editor sees instances, not what they expand to")
        edited.elements[0].x = 50
        let next = page.applyingPose(edited, at: 1)
        XCTAssertEqual(next.timeline?.track(for: inst.id)?.keys.last?.x, 50)
        XCTAssertEqual(next.elements.count, 1)
    }

    func testFilesKeepSymbolsAndInstances() throws {
        var (page, symbol, _, _) = gear()
        var inst = try XCTUnwrap(page.placeSymbol(symbol.id, at: CGPoint(x: 5, y: 5), playback: .once, offset: 0.5))
        inst.style.opacity = 0.5
        page.elements[0] = inst
        let back = try DottieFile.decode(DottieFile(pages: [page]).encoded()).pages[0]
        XCTAssertEqual(back.symbols?.first?.name, "Gear")
        XCTAssertEqual(back.elements[0].playback, .once)
        XCTAssertEqual(back.elements[0].offset, 0.5)
        XCTAssertEqual(back.resolved(at: 1.2).elements.map(\.id), page.resolved(at: 1.2).elements.map(\.id))
    }
}

extension SymbolTests {
    func testMagicMoveBringsTheSymbolsItCopiesIn() throws {
        var (there, symbol, _, _) = gear()
        there.placeSymbol(symbol.id, at: CGPoint(x: 10, y: 10))
        var here = DottieDocument()
        _ = try DiagramOps.addShape(&here, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), at: .zero,
                                    text: "x", fill: nil, stroke: nil, roughness: 0)
        _ = try here.magicMove(to: there, at: 0, duration: 1, ease: .linear)
        XCTAssertEqual(here.symbols?.map(\.id), [symbol.id])
        XCTAssertTrue(here.resolved(at: 1).elements.contains { $0.kind == .rectangle && $0.width == 20 })
    }

    func testScriptsMakeAndPlaceSymbols() throws {
        var doc = DottieDocument()
        let r = DottieScript.run("""
            dottie.timeline({duration: 1, fps: 10});
            const g = dottie.rect({x: 0, y: 0, width: 40, height: 20, text: "g"});
            dottie.key(g, 0, {rotation: 0}); dottie.key(g, 1, {rotation: 6.28});
            const made = dottie.symbol([g], {name: "Gear"});
            dottie.timeline({duration: 4});
            const copy = dottie.place("Gear", {x: 100, y: 0, width: 80, offset: 0.5, playback: "once"});
            dottie.update(made.instance, {playback: "still"});
            return {symbols: dottie.symbols(), copy, broken: dottie.breakApart(made.instance).length};
            """, on: &doc, selection: [], libraries: [.starter], timeLimit: 5)
        XCTAssertNil(r.error)
        let v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(r.value).utf8)) as? [String: Any])
        let symbols = try XCTUnwrap(v["symbols"] as? [[String: Any]])
        XCTAssertEqual(symbols.first?["name"] as? String, "Gear")
        XCTAssertEqual(symbols.first?["duration"] as? Double, 1)
        XCTAssertEqual((v["copy"] as? [String: Any])?["playback"] as? String, "once")
        XCTAssertEqual((v["copy"] as? [String: Any])?["height"] as? Double, 40, "keeps the symbol's shape")
        XCTAssertEqual(v["broken"] as? Int, 1)
        XCTAssertEqual(doc.elements.filter { $0.kind == .symbol }.count, 1)
    }
}

extension SymbolTests {
    func testCopiesAndLibraryItemsBringTheirSymbols() throws {
        var (page, symbol, _, _) = gear()
        let inst = try XCTUnwrap(page.placeSymbol(symbol.id, at: CGPoint(x: 10, y: 10)))
        let plain = try DiagramOps.addShape(&page, kind: .rectangle, frame: CGRect(x: 300, y: 0, width: 10, height: 10), at: .zero,
                                            text: nil, fill: nil, stroke: nil, roughness: 0)
        // Plain shapes copy as they always did: a bare list.
        let bare = try XCTUnwrap(page.clipboardData(for: [plain.id]))
        XCTAssertNoThrow(try JSONDecoder().decode([Element].self, from: bare))

        var other = DottieDocument()
        let pasted = other.paste(try XCTUnwrap(page.clipboardData(for: [inst.id])))
        XCTAssertEqual(pasted.count, 1)
        XCTAssertEqual(other.symbols?.map(\.id), [symbol.id])
        XCTAssertEqual(other.resolved(at: 1.5).elements.count, 2, "it plays on the other page")

        let item = try XCTUnwrap(StencilLibrary.item(from: page, ids: [inst.id], name: "Gear"))
        XCTAssertEqual(item.symbols?.map(\.id), [symbol.id])
        let back = try JSONDecoder().decode(StencilItem.self, from: JSONEncoder().encode(item))
        var fresh = DottieDocument()
        let ids = fresh.place(back, center: CGPoint(x: 200, y: 200), layerID: fresh.layers[0].id, keepOriginalColors: true)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(fresh.symbols?.count, 1)
        XCTAssertGreaterThan(fresh.resolved(at: 0).elements.count, 0)
        XCTAssertEqual(StencilLibrary(name: "L", items: [back]).sheet().symbols?.count, 1)
    }
}
