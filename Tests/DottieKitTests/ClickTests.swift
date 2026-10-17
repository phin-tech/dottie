import XCTest
@testable import DottieKit

final class ClickTests: XCTestCase {
    /// Two boxes and a back button over a timeline with two scenes.
    private func tour() throws -> (doc: DottieDocument, auth: Element, docs: Element, back: Element) {
        var doc = DottieDocument()
        let auth = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 40), at: .zero,
                                           text: "Auth \"service\"", fill: nil, stroke: nil, roughness: 1)
        let docs = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 120, y: 0, width: 80, height: 40), at: .zero,
                                           text: "Docs", fill: nil, stroke: nil, roughness: 1)
        let back = try DiagramOps.addShape(&doc, kind: .ellipse, frame: CGRect(x: 0, y: 80, width: 40, height: 40), at: .zero,
                                           text: nil, fill: nil, stroke: nil, roughness: 1)
        var tl = Timeline(fps: 4, duration: 2)
        tl.setKey(Keyframe(t: 0, x: 0), for: back.id)
        tl.setKey(Keyframe(t: 2, x: 100), for: back.id)
        tl.addMarker(at: 0, name: "Overview")
        tl.addMarker(at: 1, name: "Login flow")
        doc.timeline = tl
        try DiagramOps.update(&doc, id: auth.id, click: .some(ClickAction(scene: "login flow")),
                              hover: .some(HoverLook(stroke: RGBA(r: 0, g: 0, b: 1))))
        try DiagramOps.update(&doc, id: docs.id, click: .some(ClickAction(url: "https://example.com/docs")))
        try DiagramOps.update(&doc, id: back.id, click: .some(ClickAction(scene: "Overview")))
        return (doc, auth, docs, back)
    }

    func testOnlyWebAndMailLinksAreKept() throws {
        let json = #"[{"url":"javascript:alert(1)"},{"url":" HTTPS://example.com "},{"url":"mailto:a@b.c"},{"url":"data:text/html,x"},{"scene":"S"}]"#
        let clicks = try JSONDecoder().decode([ClickAction].self, from: Data(json.utf8))
        XCTAssertEqual(clicks.map(\.url), [nil, "HTTPS://example.com", "mailto:a@b.c", nil, nil])
        XCTAssertTrue(clicks[0].isEmpty)
        XCTAssertEqual(clicks[4].scene, "S")
        var set = ClickAction(url: "https://ok.example")
        set.url = "javascript:void(0)"
        XCTAssertNil(set.url, "setting a link checks it too")
        XCTAssertThrowsError(try DiagramOps.click(scene: nil, url: "javascript:alert(1)"))
    }

    func testClickTargetsFindScenesByName() throws {
        var (doc, auth, docs, back) = try tour()
        XCTAssertEqual(doc.clickTargets, [auth.id: .scene(1), docs.id: .url("https://example.com/docs"), back.id: .scene(0)])
        // A scene that isn't there makes nothing clickable, unless there's a link to fall back on.
        try DiagramOps.update(&doc, id: back.id, click: .some(ClickAction(scene: "Nowhere")))
        try DiagramOps.update(&doc, id: docs.id, click: .some(ClickAction(scene: "Nowhere", url: "https://example.com")))
        XCTAssertNil(doc.clickTargets[back.id])
        XCTAssertEqual(doc.clickTargets[docs.id], .url("https://example.com"))
    }

    func testRenamingASceneKeepsItsClicksPlayingIt() throws {
        var (doc, auth, _, back) = try tour()
        doc.renameScene(at: 1, to: "  Sign in  ")
        XCTAssertEqual(doc.timeline?.markers?.map(\.name), ["Overview", "Sign in"])
        XCTAssertEqual(doc.elements.first { $0.id == auth.id }?.click?.scene, "Sign in", "\"login flow\" played it, in any case")
        XCTAssertEqual(doc.elements.first { $0.id == back.id }?.click?.scene, "Overview", "other scenes' clicks stay")
        XCTAssertEqual(doc.clickTargets[auth.id], .scene(1))
        let before = doc
        XCTAssertFalse(doc.renameScene(at: 1, to: "   "))
        XCTAssertFalse(doc.renameScene(at: 0.5, to: "Nowhere"))
        XCTAssertFalse(doc.renameScene(at: 1, to: "OVERVIEW"), "another scene's name, in any case, would steal its clicks")
        XCTAssertEqual(doc, before, "a blank name, a taken one or a time with no marker changes nothing")
        XCTAssertTrue(doc.renameScene(at: 1, to: "sign in"), "a change of case is fine")
    }

    func testRemovingScenesAndNamingNewOnes() {
        var tl = Timeline(duration: 3)
        XCTAssertEqual(tl.nextSceneName, "Scene 1")
        tl.addMarker(at: 0, name: tl.nextSceneName)
        tl.addMarker(at: 1, name: tl.nextSceneName)
        tl.addMarker(at: 2, name: tl.nextSceneName)
        tl.removeMarker(at: 1)
        XCTAssertEqual(tl.markers?.map(\.name), ["Scene 1", "Scene 3"])
        XCTAssertEqual(tl.nextSceneName, "Scene 4", "not a second Scene 3")
        tl.removeMarker(at: 0)
        tl.removeMarker(at: 2)
        XCTAssertNil(tl.markers, "the last one gone leaves no list")
        XCTAssertTrue(tl.addScene(at: 1))
        XCTAssertFalse(tl.addScene(at: 1), "a second at the same time would rename the first")
        XCTAssertEqual(tl.markers?.map(\.name), ["Scene 1"])
    }

    func testStillExportsIgnoreClicks() throws {
        let (doc, _, _, _) = try tour()
        var plain = doc
        for i in plain.elements.indices { plain.elements[i].click = nil; plain.elements[i].hover = nil }
        XCTAssertEqual(Exporter.svg(doc.still), Exporter.svg(plain.still))
        XCTAssertEqual(Exporter.svg(doc.resolved(at: 1)), Exporter.svg(plain.resolved(at: 1)))
    }

    func testThePlayerDrawsClickablesInPlaceWithTheirHoverLook() throws {
        let (doc, auth, _, back) = try tour()
        let html = try XCTUnwrap(Exporter.player(doc))
        XCTAssertTrue(html.contains(#"acts = [{"s":"1"},{"u":"https:\/\/example.com\/docs"},{"s":"0"}]"#)
                      || html.contains(#"acts = [{"s":"1"},{"u":"https://example.com/docs"},{"s":"0"}]"#), "actions back to front")
        XCTAssertTrue(html.contains(".dottie-a:hover .dottie-h"))
        XCTAssertTrue(html.contains(#"aria-label="Auth &quot;service&quot;""#))

        let plan = try XCTUnwrap(Exporter.animation(doc))
        let clickable = [auth.id.uuidString: 0, back.id.uuidString: 2]
        let (holder, frames) = Exporter.playerFrames(doc, plan: plan, clickable: clickable)
        XCTAssertFalse(holder.contains("Auth"), "a clickable element is never shared through <use>")
        for (i, frame) in frames.enumerated() {
            let opened = frame.components(separatedBy: "<g class=\"dottie-a\" data-a=\"").dropFirst().map { $0.prefix { $0 != "\"" } }
            XCTAssertEqual(opened, ["0", "2"], "frame \(i): each clickable in place, back to front")
            let auth = try XCTUnwrap(frame.components(separatedBy: "data-a=\"0\"").last?.components(separatedBy: "</g>\n</g>\n").first)
            XCTAssertTrue(auth.contains(">\n<g class=\"dottie-n\">\n"), "Auth has a hover look")
            XCTAssertTrue(auth.contains("<g class=\"dottie-h\">\n") && auth.contains("#0000ff"))
            XCTAssertFalse(auth.contains("<use"))
            let backButton = try XCTUnwrap(frame.components(separatedBy: "data-a=\"2\"").last)
            XCTAssertFalse(backButton.contains("dottie-h"), "the back button has none")
        }
    }

    func testScriptsSetAndReadClicks() throws {
        var (doc, auth, _, _) = try tour()
        let r = DottieScript.run("""
            dottie.update("\(auth.id.uuidString)", {click: {url: "mailto:team@example.com"}, hover: {fill: "#ffcc00", opacity: 0.8}});
            const e = dottie.get("\(auth.id.uuidString)");
            let refused = false;
            try { dottie.update("\(auth.id.uuidString)", {click: {url: "javascript:alert(1)"}}); } catch (err) { refused = true; }
            return {click: e.click, hover: e.hover, refused};
            """, on: &doc, selection: [], libraries: [.starter], timeLimit: 5)
        XCTAssertNil(r.error)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(r.value).utf8)) as? [String: Any])
        XCTAssertEqual(value["click"] as? [String: String], ["url": "mailto:team@example.com"])
        XCTAssertEqual((value["hover"] as? [String: Any])?["fill"] as? String, "#ffcc00")
        XCTAssertEqual(value["refused"] as? Bool, true)
        var cleared = doc
        _ = DottieScript.run(#"dottie.update("\#(auth.id.uuidString)", {click: null, hover: null})"#, on: &cleared, selection: [],
                             libraries: [.starter], timeLimit: 5)
        XCTAssertNil(cleared.elements.first { $0.id == auth.id }?.click)
        XCTAssertNil(cleared.elements.first { $0.id == auth.id }?.hover)
    }
}
