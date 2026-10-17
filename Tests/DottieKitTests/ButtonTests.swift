import XCTest
@testable import DottieKit

final class ButtonTests: XCTestCase {
    /// A button: a box whose fill is grey up, blue over and dark blue down, with a small hit circle; placed twice
    /// on a page with two scenes, one copy playing a scene when clicked.
    private func page() throws -> (page: DottieDocument, button: Symbol, play: Element, idle: Element) {
        let layer = Layer(name: "L")
        var box = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 30), layerID: layer.id, text: "Go")
        box.style.roughness = 0
        box.style.fill = RGBA(r: 0.8, g: 0.8, b: 0.8)
        var dot = Element(kind: .ellipse, frame: CGRect(x: 30, y: 5, width: 20, height: 20), layerID: layer.id)
        dot.style.roughness = 0
        var tl = Timeline(fps: 10, duration: 1.5)
        tl.setKey(Keyframe(t: 0, fill: RGBA(r: 0.8, g: 0.8, b: 0.8), ease: .hold), for: box.id)
        tl.setKey(Keyframe(t: 0.5, fill: RGBA(r: 0.4, g: 0.6, b: 1), ease: .hold), for: box.id)
        tl.setKey(Keyframe(t: 1, fill: RGBA(r: 0.1, g: 0.2, b: 0.6), ease: .hold), for: box.id)
        tl.setKey(Keyframe(t: 0, visible: false), for: dot.id)
        tl.setKey(Keyframe(t: 1.5, visible: true), for: dot.id)
        for (t, name) in [(0.0, "up"), (0.5, "over"), (1.0, "down"), (1.5, "Hit")] { tl.addMarker(at: t, name: name) }
        let button = Symbol(name: "Go button", width: 80, height: 30, layers: [layer], elements: [box, dot], timeline: tl, button: true)
        var page = DottieDocument()
        page.symbols = [button]
        var pageTL = Timeline(fps: 10, duration: 2)
        pageTL.addMarker(at: 0, name: "Start")
        pageTL.addMarker(at: 1, name: "Next")
        page.timeline = pageTL
        var play = try XCTUnwrap(page.placeSymbol(button.id, at: CGPoint(x: 10, y: 10), playback: .loop))
        play.click = ClickAction(scene: "Next")
        page.elements[0] = play
        let idle = try XCTUnwrap(page.placeSymbol(button.id, at: CGPoint(x: 10, y: 60), playback: .click))
        return (page, button, play, idle)
    }

    func testAButtonRestsUpWhateverItsPlayback() throws {
        let (page, button, play, _) = try page()
        for t in [0.0, 0.7, 2.0] { XCTAssertEqual(button.localTime(t, playback: .loop, offset: 0.3), 0, "t = \(t)") }
        XCTAssertEqual(button.buttonTime(.over), 0.5)
        XCTAssertEqual(button.buttonTime(.down), 1)
        XCTAssertEqual(button.buttonTime(.hit), 1.5, "scene names match in any case")
        let fill = page.resolved(at: 1.3).elements.first { $0.id == DottieDocument.derivedID(play.id, button.elements[0].id) }?.style.fill
        XCTAssertEqual(fill, RGBA(r: 0.8, g: 0.8, b: 0.8), "up, in every export")
        // A copy can be put at any moment of its symbol, which is how the players draw the other states.
        let over = page.posed(at: 1.3).expandingSymbols(at: 1.3, times: [play.id: 0.5])
        XCTAssertEqual(over.elements.first { $0.id == DottieDocument.derivedID(play.id, button.elements[0].id) }?.style.fill,
                       RGBA(r: 0.4, g: 0.6, b: 1))
    }

    func testClickPlaybackRestsAtTheStart() {
        let s = Symbol(name: "Clip", width: 10, height: 10, timeline: Timeline(duration: 2))
        XCTAssertEqual(s.localTime(1.5, playback: .click, offset: nil), 0)
        XCTAssertEqual(s.localTime(1.5, playback: .click, offset: 0.5), 0.5)
        XCTAssertEqual(try JSONDecoder().decode(SymbolPlayback.self, from: Data(#""click""#.utf8)), .click)
    }

    func testMakingAButtonTakesItsStateScenes() throws {
        var doc = DottieDocument()
        let box = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 10, y: 10, width: 60, height: 30), at: .zero,
                                          text: "B", fill: nil, stroke: nil, roughness: 0)
        var tl = Timeline(duration: 2)
        tl.addMarker(at: 0, name: "Intro")
        tl.addMarker(at: 0.5, name: "over")
        tl.addMarker(at: 1, name: "DOWN")
        doc.timeline = tl
        let made = try XCTUnwrap(doc.makeSymbol(of: [box.id], name: "B", button: true))
        XCTAssertTrue(made.symbol.isButton)
        XCTAssertEqual(made.symbol.timeline?.markers?.map(\.name), ["over", "DOWN"])
        XCTAssertEqual(doc.timeline?.markers?.map(\.name), ["Intro"], "other scenes stay on the page")

        var plain = DottieDocument()
        let other = try DiagramOps.addShape(&plain, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), at: .zero,
                                            text: nil, fill: nil, stroke: nil, roughness: 0)
        let s = try XCTUnwrap(plain.makeSymbol(of: [other.id], name: "S")).symbol
        plain.makeButton(s.id)
        let b = try XCTUnwrap(plain.symbols?.first)
        XCTAssertTrue(b.isButton)
        XCTAssertEqual(b.timeline?.markers?.map(\.name), ["up", "over", "down"])
        XCTAssertEqual(b.timeline?.markers?.map(\.t), [0, 0.5, 1])
    }

    func testTheExportDrawsEachClickableCopyAsOneButton() throws {
        let (doc, button, play, idle) = try page()
        let html = try XCTUnwrap(Exporter.player(doc))
        XCTAssertTrue(html.contains(#"aria-label="Go button""#), "labelled by its symbol's name")
        let plan = try XCTUnwrap(Exporter.animation(doc))
        let (holder, frames) = Exporter.playerFrames(doc, plan: plan, clickable: [play.id.uuidString: 0])
        let parts = Set(button.elements.map { DottieDocument.derivedID(play.id, $0.id).uuidString })
        XCTAssertFalse(parts.contains { holder.contains($0) }, "never shared")
        _ = idle
        for (i, frame) in frames.enumerated() {
            let groups = frame.components(separatedBy: "<g class=\"dottie-a").count - 1
            XCTAssertEqual(groups, 1, "frame \(i): one button, the clickable copy; the click-to-play copy isn't one here")
            let inside = try XCTUnwrap(frame.components(separatedBy: "<g class=\"dottie-a").last)
            XCTAssertTrue(inside.hasPrefix(" dottie-b\""), "it has a down state")
            for state in ["dottie-n", "dottie-h", "dottie-d", "dottie-hit"] { XCTAssertTrue(inside.contains("class=\"\(state)\""), "\(state), frame \(i)") }
            XCTAssertTrue(inside.contains("#6699ff"), "over is blue")
            XCTAssertTrue(inside.contains("#1a3399"), "down is dark blue")
        }
        XCTAssertTrue(html.contains(".dottie-b:active .dottie-d { display: inline; }"))
    }

    func testAPlainCopyTakesClicksOnItsFrame() throws {
        var (page, symbol, _, _) = try plainGear()
        var inst = try XCTUnwrap(page.placeSymbol(symbol.id, at: CGPoint(x: 0, y: 0)))
        inst.click = ClickAction(url: "https://example.com")
        page.elements[0] = inst
        let frames = Exporter.playerFrames(page, plan: try XCTUnwrap(Exporter.animation(page)), clickable: [inst.id.uuidString: 0]).frames
        XCTAssertTrue(frames[0].contains("<path class=\"dottie-hit\""), "its frame takes the clicks")
        XCTAssertFalse(frames[0].contains("dottie-b"), "no down state: it nudges instead")
    }

    private func plainGear() throws -> (DottieDocument, Symbol, Element, Element) {
        let layer = Layer(name: "L")
        let a = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 20, height: 20), layerID: layer.id)
        let b = Element(kind: .ellipse, frame: CGRect(x: 30, y: 0, width: 20, height: 20), layerID: layer.id)
        let s = Symbol(name: "Plain", width: 50, height: 20, layers: [layer], elements: [a, b], timeline: Timeline(duration: 1))
        var page = DottieDocument()
        page.symbols = [s]
        return (page, s, a, b)
    }
}
