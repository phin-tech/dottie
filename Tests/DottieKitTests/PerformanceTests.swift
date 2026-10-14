import XCTest
import CoreGraphics
@testable import DottieKit

/// Big-document timings. Each prints its numbers (run with `swift test --filter Performance`) and
/// asserts a generous ceiling, so only a real regression, not machine noise, fails the suite.
final class PerformanceTests: XCTestCase {
    /// ~`n` shapes in a grid with a mix of looks, a connector between neighbours, and pen strokes.
    static func bigDocument(shapes n: Int, strokes: Int = 200) -> DottieDocument {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        let second = doc.addLayer(name: "Top")
        let kinds: [ElementKind] = [.rectangle, .ellipse, .diamond]
        var rng = SeededRNG(seed: 42)
        let cols = Int(Double(n).squareRoot().rounded(.up))
        var shapeIDs: [UUID] = []
        for i in 0..<n {
            var st = Style()
            st.fill = RGBA(r: rng.unit(), g: rng.unit(), b: rng.unit(), a: 1)
            st.fillStyle = FillStyle.allCases[i % 3]
            st.dash = DashStyle.allCases[i % 3]
            var e = Element(kind: kinds[i % 3], frame: CGRect(x: Double(i % cols) * 160, y: Double(i / cols) * 110, width: 120, height: 70),
                            style: st, seed: UInt32(i + 1), layerID: i % 5 == 0 ? second : layer, text: "n\(i)")
            if i % 7 == 0 { e.rotation = Double(i % 12) * .pi / 12 }
            doc.elements.append(e)
            shapeIDs.append(e.id)
        }
        for i in stride(from: 0, to: n - 1, by: 2) {
            var c = Element(kind: .connector, frame: .zero, layerID: layer, text: i % 10 == 0 ? "lbl" : nil,
                            connector: ConnectorData(start: .bound(shapeIDs[i]), end: .bound(shapeIDs[i + 1]),
                                                     routing: Routing.allCases[i % 3]))
            c.seed = UInt32(i + 7)
            doc.elements.append(c)
        }
        for s in 0..<strokes {
            let raw = (0...2000).map { k -> CGPoint in
                let t = Double(k) / 2000 * 6
                return CGPoint(x: Double(s % 20) * 300 + t * 40, y: Double(s / 20) * 200 + 40 * sin(t * 3 + Double(s)))
            }
            let xs = raw.map(\.x), ys = raw.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            var e = Element(kind: .freehand, frame: box, layerID: layer,
                            points: raw.map { StrokePoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) })
            e.fitStroke()
            doc.elements.append(e)
        }
        return doc
    }

    private func time<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, Double) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let v = try body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        print(String(format: "PERF %-34@ %9.1f ms", label as NSString, ms))
        return (v, ms)
    }

    func testFiveThousandElementDocument() throws {
        let (doc, _) = time("build 5000 shapes + 200 strokes") { Self.bigDocument(shapes: 5000) }
        let count = doc.elements.count
        print("PERF elements: \(count)")

        let (data, encMs) = try time("encode") { try doc.encoded() }
        print(String(format: "PERF file size: %.2f MB", Double(data.count) / 1e6))
        let (back, decMs) = try time("decode") { try DottieDocument.decode(data) }
        XCTAssertEqual(back.elements.count, count)

        let (_, orderMs) = time("orderedElements x10") { for _ in 0..<10 { _ = doc.orderedElements } }
        let (_, hitMs) = time("element(at:) x100") {
            for i in 0..<100 { _ = doc.element(at: CGPoint(x: Double(i) * 37, y: Double(i) * 23)) }
        }
        // encoded() rounds frames to 0.01, so compare documents that have both been through it.
        let normalised = try DottieDocument.decode(data)
        let (same, eqMs) = time("== (commit's old != new)") { normalised == back }
        XCTAssertTrue(same)
        let (_, inkMs) = time("resolvingInk") { _ = doc.resolvingInk(to: .inkOnDark) }

        // One frame of the canvas: everything drawn into a viewport-sized bitmap.
        let ctx = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let ink = doc.resolvingInk(to: .black)
        let (_, drawMs) = time("draw everything (one frame)") { Renderer.draw(ink, in: ctx, background: CGColor(gray: 1, alpha: 1)) }

        let (_, svgMs) = time("svg export") { _ = Exporter.svg(doc) }

        XCTAssertLessThan(encMs, 5_000); XCTAssertLessThan(decMs, 5_000)
        XCTAssertLessThan(orderMs, 1_000); XCTAssertLessThan(hitMs / 100, 150) // per click, debug build
        XCTAssertLessThan(eqMs, 2_000); XCTAssertLessThan(inkMs, 2_000)
        XCTAssertLessThan(drawMs, 20_000); XCTAssertLessThan(svgMs, 20_000)
    }

    func testLiveDragCostOnAMediumDocument() {
        // What a mouse move costs while dragging in a 1,000 shape drawing: copy the baseline, move
        // the selection, compare and snap against everything else.
        let base = Self.bigDocument(shapes: 1000, strokes: 20)
        let others = base.elements.filter { $0.kind != .connector }.map(\.rotatedBounds)
        let (_, ms) = time("1 drag step x50") {
            for k in 0..<50 {
                var next = base
                for i in next.elements.indices.prefix(3) { next.elements[i].x += Double(k) }
                _ = Snap.move(CGRect(x: 100 + Double(k), y: 100, width: 120, height: 70), others: others, threshold: 6)
                _ = next != base
            }
        }
        XCTAssertLessThan(ms / 50, 100) // under 100 ms a step even unoptimised debug
    }
}
