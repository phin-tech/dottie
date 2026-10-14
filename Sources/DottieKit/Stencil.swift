import Foundation
import CoreGraphics

/// One reusable piece of artwork in a library: some elements positioned with their top-left corner at
/// the origin. Stored at original fidelity, so how it looks on a canvas is decided when it is placed.
public struct StencilItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var tags: [String]
    public var width: Double
    public var height: Double
    public var elements: [Element]
    /// True for art that came from outside Dottie (an SVG, a built-in shape): placing it can restyle it
    /// to the document's look. Items made from a selection already look the way their author styled them.
    public var imported: Bool

    public init(id: UUID = UUID(), name: String, tags: [String] = [], width: Double, height: Double,
                elements: [Element], imported: Bool) {
        self.id = id; self.name = name; self.tags = tags; self.width = width; self.height = height
        self.elements = elements; self.imported = imported
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    /// Scale that makes a tiny icon readable and a huge drawing manageable; 1 for anything in between.
    public var readableScale: Double {
        let longest = max(width, height)
        guard longest > 0 else { return 1 }
        if longest < 64 { return 96 / longest }
        if longest > 480 { return 480 / longest }
        return 1
    }

    /// The elements to place: restyled (ink strokes, `roughness`) unless `keepOriginalColors`, and
    /// scaled uniformly by `scale`. Fills are always kept.
    public func placed(keepOriginalColors: Bool, roughness: Double = Style().roughness, scale: Double = 1) -> [Element] {
        elements.map { src in
            var e = src
            if imported, !keepOriginalColors, e.kind == .connector {
                e.style.roughness = roughness // connectors keep their color, but share the drawing's look
            } else if imported, !keepOriginalColors, e.kind != .text {
                e.style.roughness = roughness
                e.style.stroke = .black
                let w = e.style.strokeWidth
                e.style.strokeWidth = w <= 0 ? 1.5 : min(max(w, 1), 4)
            }
            guard scale != 1 else { return e }
            e.x *= scale; e.y *= scale; e.width *= scale; e.height *= scale
            e.style.strokeWidth = max(0.25, e.style.strokeWidth * scale)
            e.style.fontSize *= scale
            if var c = e.connector {
                for isStart in [true, false] {
                    var ep = isStart ? c.start : c.end
                    if ep.elementID == nil { ep.x *= scale; ep.y *= scale }
                    if isStart { c.start = ep } else { c.end = ep }
                }
                e.connector = c
            }
            return e
        }
    }

    /// A one-item document, for rendering a thumbnail through the normal exporters.
    public func document(keepOriginalColors: Bool = false, roughness: Double = Style().roughness) -> DottieDocument {
        var doc = DottieDocument()
        let layer = doc.layers[0].id
        doc.elements = placed(keepOriginalColors: keepOriginalColors, roughness: roughness).map {
            var e = $0; e.layerID = layer; return e
        }
        return doc
    }
}

/// A named collection of stencil items, stored as a `.dottielib` JSON file.
public struct StencilLibrary: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var name: String
    public var items: [StencilItem]

    public init(name: String, items: [StencilItem] = []) { self.name = name; self.items = items }

    public func encoded() throws -> Data {
        var copy = self
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        for i in copy.items.indices {
            copy.items[i].width = r(copy.items[i].width)
            copy.items[i].height = r(copy.items[i].height)
            for j in copy.items[i].elements.indices {
                copy.items[i].elements[j].x = r(copy.items[i].elements[j].x)
                copy.items[i].elements[j].y = r(copy.items[i].elements[j].y)
                copy.items[i].elements[j].width = r(copy.items[i].elements[j].width)
                copy.items[i].elements[j].height = r(copy.items[i].elements[j].height)
            }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(copy)
    }

    public static func decode(_ data: Data) throws -> StencilLibrary {
        try JSONDecoder().decode(StencilLibrary.self, from: data)
    }

    /// ~/Library/Application Support/Dottie/Libraries, where the app keeps user libraries.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dottie/Libraries", isDirectory: true)
    }

    /// Every readable `.dottielib` in `directory`, sorted by file name.
    public static func load(directory: URL) -> [(url: URL, library: StencilLibrary)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "dottielib" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decode($0) }.map { (url, $0) } }
    }

    /// An item holding `ids` of `doc`. Connectors bound to shapes outside the set are frozen in place.
    public static func item(from doc: DottieDocument, ids: Set<UUID>, name: String, tags: [String] = []) -> StencilItem? {
        guard let data = doc.clipboardData(for: ids),
              var items = try? JSONDecoder().decode([Element].self, from: data), !items.isEmpty else { return nil }
        let box = normalizeToOrigin(&items)
        return StencilItem(name: name, tags: tags, width: box.width, height: box.height, elements: items, imported: false)
    }

    /// A library from an Excalidraw library (or scene, as one item). Items keep their authored look.
    public static func fromExcalidraw(name: String, data: Data) throws -> StencilLibrary {
        let items = try ExcalidrawImporter.importItems(from: data, layerID: UUID())
        return StencilLibrary(name: name, items: items.enumerated().map { i, it in
            StencilItem(name: it.name ?? "Item \(i + 1)", width: it.size.width, height: it.size.height,
                        elements: it.elements, imported: false)
        })
    }

    /// A library with one item per page of a draw.io file. Items are restyled to the drawing's look when
    /// placed, like SVGs.
    public static func fromDrawio(name: String, data: Data) throws -> StencilLibrary {
        let items = try DrawioImporter.importItems(from: data, layerID: UUID())
        return StencilLibrary(name: name, items: items.map {
            StencilItem(name: $0.name, width: $0.size.width, height: $0.size.height, elements: $0.elements, imported: true)
        })
    }

    /// Moves `items` so their joint bounds start at the origin (free connector ends move with them).
    /// Returns the bounds the items had.
    @discardableResult
    static func normalizeToOrigin(_ items: inout [Element]) -> CGRect {
        var holder = DottieDocument()
        holder.elements = items
        let box = Exporter.bounds(of: holder, padding: 0)
        for i in items.indices {
            if var c = items[i].connector {
                for isStart in [true, false] {
                    var ep = isStart ? c.start : c.end
                    if ep.elementID == nil { ep.x -= box.minX; ep.y -= box.minY }
                    if isStart { c.start = ep } else { c.end = ep }
                }
                items[i].connector = c
            } else {
                items[i].x -= box.minX; items[i].y -= box.minY
            }
        }
        return CGRect(origin: .zero, size: box.size)
    }

    /// One item per readable SVG, named for its file. `failed` lists the names that had nothing to draw.
    public static func fromSVGs(name: String, files: [(name: String, data: Data)]) -> (library: StencilLibrary, failed: [String]) {
        var lib = StencilLibrary(name: name)
        var failed: [String] = []
        let layer = UUID()
        for f in files {
            guard let art = try? SVGImporter.importElements(from: f.data, layerID: layer) else { failed.append(f.name); continue }
            lib.items.append(StencilItem(name: f.name, width: art.size.width, height: art.size.height,
                                         elements: art.elements, imported: true))
        }
        return (lib, failed)
    }
}

extension DottieDocument {
    /// Places a stencil with its center at `center`. Returns the new element ids.
    @discardableResult
    public mutating func place(_ item: StencilItem, center: CGPoint, layerID: UUID, keepOriginalColors: Bool,
                               roughness: Double = Style().roughness) -> Set<UUID> {
        let k = item.readableScale
        return insert(item.placed(keepOriginalColors: keepOriginalColors, roughness: roughness, scale: k),
                      size: CGSize(width: item.width * k, height: item.height * k), center: center, layerID: layerID)
    }
}

// MARK: - Built-in shapes

extension StencilLibrary {
    /// The shapes every diagram wants, drawn in code so there is nothing to bundle or keep in sync.
    public static var starter: StencilLibrary {
        let layer = UUID()
        func item(_ name: String, _ tags: [String], _ w: Double, _ h: Double, _ paths: [CGPath]) -> StencilItem {
            var st = Style()
            st.roughness = 0; st.fill = .clear; st.strokeWidth = 2
            let elements = paths.compactMap { Element.shape($0, style: st, seed: 1, layerID: layer) }
            return StencilItem(id: stableID(name), name: name, tags: tags, width: w, height: h, elements: elements, imported: true)
        }
        func poly(_ pts: [(Double, Double)]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts.map { CGPoint(x: $0.0, y: $0.1) })
            p.closeSubpath()
            return p
        }
        func segment(_ a: (Double, Double), _ b: (Double, Double)) -> CGPath {
            let p = CGMutablePath(); p.move(to: CGPoint(x: a.0, y: a.1)); p.addLine(to: CGPoint(x: b.0, y: b.1)); return p
        }

        var out: [StencilItem] = []
        out.append(item("Process", ["flowchart"], 120, 70,
                        [CGPath(roundedRect: CGRect(x: 0, y: 0, width: 120, height: 70), cornerWidth: 12, cornerHeight: 12, transform: nil)]))
        out.append(item("Terminator", ["flowchart"], 130, 50,
                        [CGPath(roundedRect: CGRect(x: 0, y: 0, width: 130, height: 50), cornerWidth: 25, cornerHeight: 25, transform: nil)]))
        out.append(item("Decision", ["flowchart"], 130, 90, [poly([(65, 0), (130, 45), (65, 90), (0, 45)])]))
        out.append(item("Input / Output", ["flowchart"], 140, 60, [poly([(25, 0), (140, 0), (115, 60), (0, 60)])]))
        out.append(item("Preparation", ["flowchart"], 130, 70, [poly([(30, 0), (100, 0), (130, 35), (100, 70), (30, 70), (0, 35)])]))

        let doc = CGMutablePath()
        doc.move(to: .zero); doc.addLine(to: CGPoint(x: 110, y: 0)); doc.addLine(to: CGPoint(x: 110, y: 64))
        doc.addCurve(to: CGPoint(x: 55, y: 64), control1: CGPoint(x: 90, y: 50), control2: CGPoint(x: 75, y: 50))
        doc.addCurve(to: CGPoint(x: 0, y: 64), control1: CGPoint(x: 35, y: 78), control2: CGPoint(x: 20, y: 78))
        doc.closeSubpath()
        out.append(item("Document", ["flowchart"], 110, 76, [doc]))

        let k = 0.5523
        let w = 80.0, h = 100.0, ry = 14.0
        let top = CGMutablePath(); top.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: 2 * ry))
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 0, y: ry)); body.addLine(to: CGPoint(x: 0, y: h - ry))
        body.addCurve(to: CGPoint(x: w / 2, y: h), control1: CGPoint(x: 0, y: h - ry + k * ry), control2: CGPoint(x: w / 2 - k * w / 2, y: h))
        body.addCurve(to: CGPoint(x: w, y: h - ry), control1: CGPoint(x: w / 2 + k * w / 2, y: h), control2: CGPoint(x: w, y: h - ry + k * ry))
        body.addLine(to: CGPoint(x: w, y: ry))
        out.append(item("Database", ["flowchart", "data"], w, h, [top, body]))

        let cloud = CGMutablePath()
        let n = 9, cx = 70.0, cy = 45.0, rx = 58.0, rcy = 30.0
        func onEllipse(_ i: Int) -> CGPoint {
            let t = 2 * Double.pi * Double(i) / Double(n)
            return CGPoint(x: cx + rx * cos(t), y: cy + rcy * sin(t))
        }
        cloud.move(to: onEllipse(0))
        for i in 0..<n {
            let a = onEllipse(i), b = onEllipse(i + 1)
            let t = 2 * Double.pi * (Double(i) + 0.5) / Double(n)
            let c = CGPoint(x: cx + (rx + 26) * cos(t), y: cy + (rcy + 26) * sin(t))
            cloud.addQuadCurve(to: b, control: c)
            _ = a
        }
        cloud.closeSubpath()
        out.append(item("Cloud", ["shape"], 140, 90, [cloud]))

        out.append(item("Block Arrow", ["shape", "arrow"], 140, 70,
                        [poly([(0, 20), (90, 20), (90, 0), (140, 35), (90, 70), (90, 50), (0, 50)])]))
        out.append(item("Triangle", ["shape"], 100, 90, [poly([(50, 0), (100, 90), (0, 90)])]))

        var star: [(Double, Double)] = []
        for i in 0..<10 {
            let r = i % 2 == 0 ? 50.0 : 21.0
            let t = -Double.pi / 2 + Double(i) * Double.pi / 5
            star.append((50 + r * cos(t), 50 + r * sin(t)))
        }
        out.append(item("Star", ["shape"], 100, 95, [poly(star)]))

        let bubble = CGMutablePath()
        let bw = 130.0, bh = 70.0, r = 12.0
        bubble.move(to: CGPoint(x: r, y: 0))
        bubble.addArc(tangent1End: CGPoint(x: bw, y: 0), tangent2End: CGPoint(x: bw, y: bh), radius: r)
        bubble.addArc(tangent1End: CGPoint(x: bw, y: bh), tangent2End: CGPoint(x: 0, y: bh), radius: r)
        bubble.addLine(to: CGPoint(x: 70, y: bh)); bubble.addLine(to: CGPoint(x: 35, y: bh + 24)); bubble.addLine(to: CGPoint(x: 45, y: bh))
        bubble.addArc(tangent1End: CGPoint(x: 0, y: bh), tangent2End: CGPoint(x: 0, y: 0), radius: r)
        bubble.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: bw, y: 0), radius: r)
        bubble.closeSubpath()
        out.append(item("Speech Bubble", ["shape"], bw, bh + 24, [bubble]))

        out.append(item("Note", ["shape"], 110, 80,
                        [poly([(0, 0), (90, 0), (110, 20), (110, 80), (0, 80)]),
                         { let p = CGMutablePath(); p.move(to: CGPoint(x: 90, y: 0)); p.addLine(to: CGPoint(x: 90, y: 20))
                           p.addLine(to: CGPoint(x: 110, y: 20)); return p }()]))

        let head = CGMutablePath(); head.addEllipse(in: CGRect(x: 15, y: 0, width: 20, height: 20))
        out.append(item("Actor", ["shape", "people"], 50, 85,
                        [head, segment((25, 20), (25, 55)), segment((3, 33), (47, 33)),
                         segment((25, 55), (5, 85)), segment((25, 55), (45, 85))]))

        return StencilLibrary(name: "Basics", items: out)
    }

    /// The same id for the same built-in name on every launch.
    private static func stableID(_ name: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in Array(("dottie.starter." + name).utf8).enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b &+ UInt8(i & 0xff) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
