import XCTest
@testable import DottieKit

final class LottieExportTests: XCTestCase {
    /// A box sliding 300 pt to the right over a second at 10 fps, with a label and an arrow to a still box.
    private func sliding(roughness: Double = 0) throws -> (DottieDocument, Element) {
        var doc = DottieDocument()
        let a = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 40), at: .zero,
                                        text: "A", fill: nil, stroke: nil, roughness: roughness)
        let b = try DiagramOps.addShape(&doc, kind: .ellipse, frame: CGRect(x: 0, y: 200, width: 60, height: 60), at: .zero,
                                        text: nil, fill: nil, stroke: nil, roughness: roughness)
        _ = try DiagramOps.addConnector(&doc, from: a.id, to: b.id)
        var tl = Timeline(fps: 10, duration: 1)
        tl.setKey(Keyframe(t: 0, x: 0), for: a.id)
        tl.setKey(Keyframe(t: 1, x: 300), for: a.id)
        doc.timeline = tl
        return (doc, a)
    }

    private func decode(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    /// A property's value at `frame`: held from key to key, or tweened linearly between them.
    private func value(_ prop: [String: Any], at frame: Double) -> [Double] {
        func nums(_ v: Any?) -> [Double] { (v as? [Double]) ?? (v as? Double).map { [$0] } ?? [] }
        guard prop["a"] as? Int == 1, let keys = prop["k"] as? [[String: Any]] else { return nums(prop["k"]) }
        let t = keys.map { $0["t"] as! Double }
        guard let i = t.lastIndex(where: { $0 <= frame }) else { return nums(keys[0]["s"]) }
        let a = nums(keys[i]["s"])
        guard i + 1 < keys.count, keys[i]["h"] as? Int != 1 else { return a }
        let b = nums(keys[i + 1]["s"]), u = (frame - t[i]) / (t[i + 1] - t[i])
        return zip(a, b).map { $0 + ($1 - $0) * u }
    }

    private func layers(_ json: [String: Any], named name: String) -> [[String: Any]] {
        (json["layers"] as! [[String: Any]]).filter { $0["nm"] as? String == name }
    }

    func testExactModeHoldsEachFrameWhereDottieDrawsIt() throws {
        let (doc, a) = try sliding()
        let json = try decode(Exporter.lottie(doc, mode: .exact))
        XCTAssertEqual(json["fr"] as? Double, 10)
        XCTAssertEqual(json["op"] as? Double ?? 0, 11, accuracy: 1e-9, "ten frames, the end pose, held a frame")
        let box = layers(json, named: "e-\(a.id.uuidString)")
        XCTAssertEqual(box.count, 1, "a box that only slides is one layer")
        let p = try XCTUnwrap((box[0]["ks"] as? [String: Any])?["p"] as? [String: Any])
        for f in [0.0, 3, 3.5, 7, 10] {
            let expected = doc.resolved(at: floor(f) / 10).elements.first { $0.id == a.id }!.x
            XCTAssertEqual(value(p, at: f)[0], expected, accuracy: 0.01, "frame \(f) holds frame \(floor(f))")
        }
    }

    func testSmoothModeTweensBetweenSamples() throws {
        let (doc, a) = try sliding(roughness: 1)
        let json = try decode(Exporter.lottie(doc, mode: .smooth))
        XCTAssertEqual(json["fr"] as? Double, 30)
        let box = layers(json, named: "e-\(a.id.uuidString)")
        XCTAssertEqual(box.count, 1)
        let ks = try XCTUnwrap(box[0]["ks"] as? [String: Any])
        let p = try XCTUnwrap(ks["p"] as? [String: Any]), anchor = value(try XCTUnwrap(ks["a"] as? [String: Any]), at: 0)
        for f in [0.0, 7.5, 15, 30] {
            let e = doc.resolved(at: f / 30).elements.first { $0.id == a.id }!
            XCTAssertEqual(value(p, at: f)[0] - anchor[0], e.x, accuracy: 0.05, "frame \(f)")
        }
        XCTAssertLessThan((p["k"] as? [Any])?.count ?? 99, 5, "a linear slide needs only its ends")
    }

    func testCameraParentsEveryDrawnLayerAndTextIsOutlined() throws {
        let (doc, a) = try sliding()
        let json = try decode(Exporter.lottie(doc))
        let all = json["layers"] as! [[String: Any]]
        let camera = try XCTUnwrap(all.first)
        XCTAssertEqual(camera["ty"] as? Int, 3)
        XCTAssertNil(camera["parent"], "the camera has no parent of its own")
        XCTAssertEqual(all.last?["ty"] as? Int, 1, "the page color is the bottom layer")
        for l in all.dropFirst().dropLast() { XCTAssertEqual(l["parent"] as? Int, 1) }
        // The box's label is drawn as filled glyph outlines.
        let groups = try XCTUnwrap(layers(json, named: "e-\(a.id.uuidString)").first?["shapes"] as? [[String: Any]])
        let fills = groups.filter { ($0["it"] as! [[String: Any]]).contains { $0["ty"] as? String == "fl" } }
        XCTAssertFalse(fills.isEmpty)
        XCTAssertNil(try decode(Exporter.lottie(doc, transparent: true))["layers"].flatMap { ($0 as? [[String: Any]])?.first { $0["ty"] as? Int == 1 } })
    }

    func testDrawingOnIsATrimAndPicturesAreEmbedded() throws {
        var doc = DottieDocument()
        let e = try DiagramOps.addShape(&doc, kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 80, height: 40), at: .zero,
                                        text: nil, fill: nil, stroke: nil, roughness: 1)
        try doc.addTransition(.drawIn, to: e.id, at: 0)
        let json = try decode(Exporter.lottie(doc, mode: .exact))
        let drawing = layers(json, named: "e-\(e.id.uuidString)").first { l in
            (l["shapes"] as? [[String: Any]])?.contains { ($0["it"] as! [[String: Any]]).contains { $0["ty"] as? String == "tm" } } == true
        }
        XCTAssertNotNil(drawing, "the draw-on is one layer with a keyed trim, not a layer per frame")

        let png = try XCTUnwrap(Exporter.png({ var d = DottieDocument(); _ = try? DiagramOps.addShape(&d, kind: .rectangle,
            frame: CGRect(x: 0, y: 0, width: 10, height: 10), at: .zero, text: nil, fill: nil, stroke: nil, roughness: 0); return d }(), scale: 1))
        var pic = DottieDocument()
        var img = Element(kind: .image, frame: CGRect(x: 0, y: 0, width: 50, height: 30), layerID: pic.layers[0].id)
        img.image = EmbeddedImage(data: png, format: "png")
        pic.elements.append(img)
        let withPicture = try decode(Exporter.lottie(pic))
        XCTAssertEqual((withPicture["assets"] as? [[String: Any]])?.count, 1)
        let picture = layers(withPicture, named: "e-\(img.id.uuidString)").map { $0["ty"] as? Int }
        XCTAssertEqual(picture, [4, 2], "its border over the image itself")
    }

    func testContoursKeepCurvesAndCloseCleanly() {
        let rect = LottieWriter.contours(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 5), transform: nil))
        XCTAssertEqual(rect.count, 1)
        XCTAssertTrue(rect[0].closed)
        XCTAssertEqual(rect[0].v.count, 4)
        let ellipse = LottieWriter.contours(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil))
        XCTAssertEqual(ellipse[0].v.count, 4, "the closing curve lands back on the start, which isn't repeated")
        XCTAssertNotEqual(ellipse[0].i[0], .zero, "and keeps its tangent")
    }
}
