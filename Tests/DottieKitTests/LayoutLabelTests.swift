import XCTest
import CoreGraphics
@testable import DottieKit

/// Laid-out diagrams keep connector labels off the shapes (issue #3, item 7).
final class LayoutLabelTests: XCTestCase {
    /// An architecture-ish graph: fan-out, fan-in, an edge that skips a rank, a loop back, and labels wider
    /// than the default gap between ranks.
    private func graph(_ direction: LayoutDirection, routing: Routing? = nil) throws -> DottieDocument {
        var doc = DottieDocument()
        let n: [DiagramOps.NodeSpec] = [
            .init(key: "client", text: "Client"), .init(key: "lb", text: "Load balancer"),
            .init(key: "east", text: "us-east-1"), .init(key: "west", text: "us-west-2"),
            .init(key: "api", text: "API"), .init(key: "db", text: "Database"), .init(key: "cache", text: "Cache"),
            .init(key: "queue", text: "Queue"),
        ]
        let e: [DiagramOps.EdgeSpec] = [
            .init(from: "client", to: "lb", routing: routing, label: "HTTPS requests"),
            .init(from: "lb", to: "east", routing: routing, label: "primary traffic"),
            .init(from: "lb", to: "west", routing: routing, label: "failover"),
            .init(from: "east", to: "api", routing: routing, label: "gRPC calls"),
            .init(from: "west", to: "api", routing: routing, label: "gRPC calls"),
            .init(from: "api", to: "db", routing: routing, label: "reads and writes"),
            .init(from: "api", to: "cache", routing: routing, label: "lookups"),
            .init(from: "lb", to: "api", routing: routing, label: "health checks"),
            .init(from: "client", to: "queue", routing: routing, label: "async jobs"),
            .init(from: "queue", to: "api", routing: routing, label: "drain"),
            .init(from: "db", to: "lb", routing: routing, label: "replication lag alerts"),
        ]
        try DiagramOps.build(&doc, nodes: n, edges: e, direction: direction)
        return doc
    }

    /// Each label that overlaps a shape, as "label over shape".
    private func collisions(_ doc: DottieDocument) -> [String] {
        let index = doc.elementIndex
        let shapes = doc.elements.filter { $0.kind != .connector }
        var out: [String] = []
        for c in doc.elements where c.kind == .connector && !(c.text ?? "").isEmpty {
            let r = Renderer.labelRect(for: c, in: doc, index: index)
            for s in shapes where s.frame.intersects(r) { out.append("\(c.text!) over \(s.text ?? "?")") }
        }
        return out
    }

    func testTopToBottomLabelsClearTheShapes() throws {
        for routing in [Routing.elbow, .straight, .curved] {
            XCTAssertEqual(collisions(try graph(.topToBottom, routing: routing)), [], "\(routing)")
        }
    }

    func testLeftToRightLabelsClearTheShapes() throws {
        for routing in [Routing.elbow, .straight, .curved] {
            XCTAssertEqual(collisions(try graph(.leftToRight, routing: routing)), [], "\(routing)")
        }
    }

    /// Each shape a connector's line runs through other than its own two ends, as "label through shape".
    private func crossings(_ doc: DottieDocument) -> [String] {
        let index = doc.elementIndex
        var out: [String] = []
        for c in doc.elements where c.kind == .connector {
            let pts = Connector.route(of: c, in: doc, index: index).points
            let ends = [c.connector?.start.elementID, c.connector?.end.elementID]
            for s in doc.elements where s.kind != .connector && !ends.contains(s.id) {
                let r = s.frame.insetBy(dx: 1, dy: 1)
                let hit = zip(pts, pts.dropFirst()).contains { a, b in
                    (0...20).contains { k in
                        let t = Double(k) / 20
                        return r.contains(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    }
                }
                if hit { out.append("\(c.text ?? "?") through \(s.text ?? "?")") }
            }
        }
        return out
    }

    func testEdgesThatSkipRanksRunThroughTheirOwnLane() throws {
        for direction in [LayoutDirection.topToBottom, .leftToRight] {
            for routing in [Routing.elbow, .straight] {
                XCTAssertEqual(crossings(try graph(direction, routing: routing)), [], "\(direction) \(routing)")
            }
        }
    }

    /// Random graphs, each with every edge labelled.
    func testRandomGraphsKeepLabelsOffTheShapes() throws {
        var rng = SeededRNG(seed: 7)
        for g in 0..<40 {
            let count = 4 + Int(rng.next() % 8)
            let nodes = (0..<count).map { DiagramOps.NodeSpec(key: "n\($0)", text: String(repeating: "Node ", count: 1 + Int(rng.next() % 3)) + "\($0)") }
            var edges: [DiagramOps.EdgeSpec] = []
            for _ in 0..<(count + Int(rng.next() % UInt64(count))) {
                let a = Int(rng.next() % UInt64(count)), b = Int(rng.next() % UInt64(count))
                guard a != b else { continue }
                edges.append(.init(from: "n\(a)", to: "n\(b)", label: String(repeating: "label ", count: 1 + Int(rng.next() % 3))))
            }
            for direction in [LayoutDirection.topToBottom, .leftToRight] {
                var doc = DottieDocument()
                try DiagramOps.build(&doc, nodes: nodes, edges: edges, direction: direction)
                XCTAssertEqual(collisions(doc), [], "graph \(g) \(direction)")
            }
        }
    }

    func testAutoLayoutLabelsClearTheShapes() throws {
        for direction in [LayoutDirection.topToBottom, .leftToRight] {
            var doc = try graph(direction == .topToBottom ? .leftToRight : .topToBottom)
            DiagramOps.autoLayout(&doc, direction: direction)
            XCTAssertEqual(collisions(doc), [], "\(direction)")
        }
    }
}
