import Foundation
import CoreGraphics

/// A drawing defined once on a page and placed any number of times by `.symbol` elements (instances), like a
/// Flash movie clip. It has its own timeline, which each instance plays on its own clock (`SymbolPlayback`).
/// Its elements are drawn in a box at the origin, `width` by `height`, which each instance scales into its frame.
public struct Symbol: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var width, height: Double
    public var layers: [Layer]
    public var elements: [Element]
    public var timeline: Timeline?

    public init(id: UUID = UUID(), name: String, width: Double, height: Double, layers: [Layer]? = nil,
                elements: [Element] = [], timeline: Timeline? = nil) {
        self.id = id; self.name = name; self.width = width; self.height = height
        self.layers = layers ?? [Layer(name: "Layer 1")]
        self.elements = elements; self.timeline = timeline
    }

    private enum CodingKeys: String, CodingKey { case id, name, width, height, layers, elements, timeline }

    /// Lenient, as pages are: a symbol with no layers gets one, and a box is never empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Symbol"
        width = max(1, (try c.decodeIfPresent(Double.self, forKey: .width)).flatMap { $0.isFinite ? $0 : nil } ?? 100)
        height = max(1, (try c.decodeIfPresent(Double.self, forKey: .height)).flatMap { $0.isFinite ? $0 : nil } ?? 100)
        let layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        self.layers = layers.isEmpty ? [Layer(name: "Layer 1")] : layers
        elements = try c.decodeIfPresent([Element].self, forKey: .elements) ?? []
        timeline = try c.decodeIfPresent(Timeline.self, forKey: .timeline)
    }

    /// The symbol as a page of its own, for resolving its animation and for editing it.
    public var page: DottieDocument {
        var p = DottieDocument(id: id, name: name, layers: layers, elements: elements)
        p.timeline = timeline
        return p
    }

    /// The box its elements are drawn in.
    public var box: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// Where an instance playing it `playback`, started `offset` seconds in, is at page time `t`. Looping, a
    /// whole number of loops lands on the end pose rather than the start, as the last frame of an animation does.
    public func localTime(_ t: Double, playback: SymbolPlayback?, offset: Double?) -> Double {
        let d = Timeline.clampTime(timeline?.duration ?? 0)
        let o = offset.flatMap { $0.isFinite ? $0 : nil } ?? 0
        switch playback ?? .loop {
        case .still: return min(timeline?.poster ?? d, d)
        case .once: return min(max(t + o, 0), d)
        case .loop:
            guard d > 0 else { return 0 }
            let x = t + o
            var r = x.truncatingRemainder(dividingBy: d)
            if r < 0 { r += d }
            if x > Symbol.epsilon, r < Symbol.epsilon || d - r < Symbol.epsilon { return d }
            return r
        }
    }

    static let epsilon = 1e-9

    /// The deepest instances nest, and the most elements expanding one page may make: a crafted file can't
    /// make drawing it take forever.
    public static let maxDepth = 8
    public static let maxElements = 20_000
}

extension DottieDocument {
    /// The page's symbols by id; with duplicate ids the first wins.
    public var symbolIndex: [UUID: Symbol] {
        Dictionary((symbols ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Whether any element is an instance of a symbol.
    public var hasInstances: Bool { elements.contains { $0.kind == .symbol } }

    /// The page with every instance replaced by its symbol's elements as they are at page time `t`, placed in the
    /// instance's frame. Instances of a symbol that isn't on the page, or that contains itself, draw nothing.
    /// What every renderer draws; the editor works on the instances themselves. With `posing` false, each symbol's
    /// elements are taken as they are, unanimated and none hidden: every element the expansion can ever have.
    public func expandingSymbols(at t: Double, posing: Bool = true) -> DottieDocument {
        guard hasInstances else { return self }
        var copy = self
        var budget = Symbol.maxElements
        copy.elements = Self.expand(elements, in: self, at: t, symbols: symbolIndex, stack: [], posing: posing, budget: &budget)
        return copy
    }

    /// `elements` (of `page`) with their instances expanded. Connectors attached to an instance are pinned
    /// where they meet it, since the instance itself is gone.
    private static func expand(_ elements: [Element], in page: DottieDocument, at t: Double, symbols: [UUID: Symbol],
                               stack: [UUID], posing: Bool, budget: inout Int) -> [Element] {
        let instances = Set(elements.filter { $0.kind == .symbol }.map(\.id))
        guard !instances.isEmpty else { budget -= elements.count; return elements }
        let index = page.elementIndex
        var out: [Element] = []
        for e in elements {
            guard budget > 0 else { break }
            if e.kind == .connector, var c = e.connector,
               [c.start.elementID, c.end.elementID].contains(where: { $0.map(instances.contains) ?? false }) {
                let (a, b) = Connector.endpoints(of: e, in: page, index: index)
                if let id = c.start.elementID, instances.contains(id) { c.start = Endpoint(elementID: nil, port: c.start.port, x: a.x, y: a.y) }
                if let id = c.end.elementID, instances.contains(id) { c.end = Endpoint(elementID: nil, port: c.end.port, x: b.x, y: b.y) }
                var pinned = e
                pinned.connector = c
                out.append(pinned)
                budget -= 1
                continue
            }
            guard e.kind == .symbol else { out.append(e); budget -= 1; continue }
            // An instance costs one of the budget even when it draws nothing, so deep nests of empty ones stop too.
            budget -= 1
            guard let id = e.symbol, let symbol = symbols[id], !stack.contains(id), stack.count < Symbol.maxDepth else { continue }
            let u = symbol.localTime(t, playback: e.playback, offset: e.offset)
            let inner = posing ? symbol.page.posed(at: u) : symbol.page
            let visible = Set(inner.layers.filter(\.visible).map(\.id))
            var drawn = inner
            drawn.elements = inner.orderedElements.filter { visible.contains($0.layerID) }
            drawn.layers = [Layer(id: e.layerID, name: "")]
            let expanded = expand(drawn.elements, in: drawn, at: u, symbols: symbols, stack: stack + [id], posing: posing, budget: &budget)
            out += expanded.map { placed($0, in: e, symbol: symbol) }
        }
        return out
    }

    /// An element of `symbol` (already expanded) as it appears in `instance`: its box scaled into the instance's
    /// frame, then turned with it about its center; ids derived from the instance's, line widths and type scaled.
    private static func placed(_ inner: Element, in instance: Element, symbol: Symbol) -> Element {
        let f = instance.frame
        let sx = f.width / symbol.width, sy = f.height / symbol.height
        let s = (abs(sx * sy)).squareRoot()
        let center = CGPoint(x: f.midX, y: f.midY)
        let angle = instance.angle
        func point(_ p: CGPoint) -> CGPoint {
            Element.rotate(CGPoint(x: f.minX + p.x * sx, y: f.minY + p.y * sy), about: center, by: angle)
        }
        var e = inner
        e.id = derivedID(instance.id, inner.id)
        e.layerID = instance.layerID
        e.groupID = nil
        e.link = inner.link.map { derivedID(instance.id, $0) }
        e.seed = boiled(inner.seed, instance.seed)
        e.click = nil; e.hover = nil
        let scaled = CGRect(x: f.minX + inner.x * sx, y: f.minY + inner.y * sy, width: inner.width * sx, height: inner.height * sy)
        let moved = Element.rotate(CGPoint(x: scaled.midX, y: scaled.midY), about: center, by: angle)
        e.frame = CGRect(x: moved.x - scaled.width / 2, y: moved.y - scaled.height / 2, width: scaled.width, height: scaled.height)
        if angle != 0 || inner.rotation != nil { e.rotation = inner.angle + angle }
        e.style.strokeWidth = inner.style.strokeWidth * s
        e.style.fontSize = inner.style.fontSize * s
        if let g = inner.style.gridSize { e.style.gridSize = g * s }
        if let o = instance.style.opacity { e.style.opacity = (inner.style.opacity ?? 1) * o }
        if var c = inner.connector {
            func end(_ p: Endpoint) -> Endpoint {
                if let id = p.elementID { return Endpoint(elementID: derivedID(instance.id, id), port: p.port, x: p.x, y: p.y) }
                let q = point(CGPoint(x: p.x, y: p.y))
                return Endpoint(elementID: nil, port: p.port, x: q.x, y: q.y)
            }
            c.start = end(c.start); c.end = end(c.end)
            e.connector = c
        }
        return e
    }

    /// The id an element of a symbol has inside instance `instance`: both ids hashed together (SplitMix64 over
    /// their four halves), so each copy's elements are distinct even when a file numbers its ids, and the same in
    /// every frame and in dottie.js.
    static func derivedID(_ instance: UUID, _ inner: UUID) -> UUID {
        func halves(_ u: UUID) -> (UInt64, UInt64) {
            withUnsafeBytes(of: u.uuid) { b in
                (b.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }, b.suffix(8).reduce(0) { $0 << 8 | UInt64($1) })
            }
        }
        func mix(_ x: UInt64) -> UInt64 {
            var z = x &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let (a, b) = halves(instance), (c, d) = halves(inner)
        let hi = mix(mix(mix(mix(a) ^ b) ^ c) ^ d)
        let lo = mix(hi ^ 0x6A09_E667_F3BC_C909)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: hi >> (56 - 8 * i)); bytes[8 + i] = UInt8(truncatingIfNeeded: lo >> (56 - 8 * i)) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: Making, placing and breaking apart

extension DottieDocument {
    /// Turns the elements `ids` into a new symbol, put back as one instance where they were: same place, same
    /// look, same animation. Their keys move into the symbol's timeline, which runs as long as the page's, so the
    /// loop keeps time with it. Connectors between them go too; ones from outside attach to the instance instead,
    /// as do links to them. Returns the symbol and the instance, or nil when nothing drawable was chosen.
    @discardableResult
    public mutating func makeSymbol(of ids: Set<UUID>, name: String) -> (symbol: Symbol, instance: Element)? {
        let chosen = Set(elements.filter { ids.contains($0.id) && $0.kind != .connector }.map(\.id))
        guard !chosen.isEmpty else { return nil }
        // Connectors go in when both ends are chosen or loose (a loose one only if it was chosen itself).
        func inside(_ p: Endpoint, _ c: Element) -> Bool { p.elementID.map(chosen.contains) ?? ids.contains(c.id) }
        let moving = Set(elements.filter { e in
            if chosen.contains(e.id) { return true }
            guard let c = e.connector else { return false }
            return inside(c.start, e) && inside(c.end, e) && (ids.contains(e.id) || c.start.elementID != nil && c.end.elementID != nil)
        }.map(\.id))
        let index = elementIndex
        let parts = elements.filter { moving.contains($0.id) }
        let box = parts.map { $0.kind == .connector ? Connector.bounds(of: $0, in: self, index: index) : $0.rotatedBounds }
            .reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
        let layer = Layer(name: "Layer 1")
        let dx = box.minX, dy = box.minY

        var inner = parts.map { e -> Element in
            var e = e
            e.layerID = layer.id
            e.x -= dx; e.y -= dy
            if var c = e.connector {
                if c.start.elementID == nil { c.start.x -= dx; c.start.y -= dy }
                if c.end.elementID == nil { c.end.x -= dx; c.end.y -= dy }
                e.connector = c
            }
            return e
        }
        // Links inside the symbol to elements left on the page would dangle in each copy.
        for i in inner.indices where inner[i].link.map({ !moving.contains($0) }) ?? false { inner[i].link = nil }
        var symbolTimeline: Timeline?
        if var tl = timeline {
            let moved = tl.tracks.filter { moving.contains($0.element) }.map { t -> Track in
                var t = t
                t.keys = t.keys.map { k in var k = k; k.x = k.x.map { $0 - dx }; k.y = k.y.map { $0 - dy }; return k }
                t.follow = t.follow?.filter { moving.contains($0.path) }
                return t
            }
            if !moved.isEmpty {
                var own = Timeline(fps: tl.fps, duration: tl.duration, boil: tl.boil, settle: tl.settle, tracks: moved)
                own.poster = tl.poster
                symbolTimeline = own
            }
            tl.tracks.removeAll { moving.contains($0.element) }
            timeline = tl
        }
        let symbol = Symbol(name: name, width: box.width, height: box.height, layers: [layer], elements: inner,
                            timeline: symbolTimeline)
        var instance = Element(kind: .symbol, frame: box, layerID: parts[0].layerID)
        instance.symbol = symbol.id
        instance.style.roughness = 0
        let at = elements.firstIndex { moving.contains($0.id) } ?? elements.count
        elements.removeAll { moving.contains($0.id) }
        elements.insert(instance, at: min(at, elements.count))
        // What pointed at a moved element now points at the instance.
        for i in elements.indices {
            if let l = elements[i].link, moving.contains(l) { elements[i].link = instance.id }
            if var c = elements[i].connector {
                if let id = c.start.elementID, moving.contains(id) { c.start.elementID = instance.id }
                if let id = c.end.elementID, moving.contains(id) { c.end.elementID = instance.id }
                elements[i].connector = c
            }
        }
        if let tl = timeline {
            for ti in tl.tracks.indices {
                timeline!.tracks[ti].follow = tl.tracks[ti].follow?.map { f in
                    var f = f
                    if moving.contains(f.path) { f.path = instance.id }
                    return f
                }
            }
        }
        symbols = (symbols ?? []) + [symbol]
        return (symbol, instance)
    }

    /// Adds an instance of symbol `id` with its top-left corner at `origin`, at the symbol's own size unless
    /// `size` says otherwise. An animated symbol on a still page gives the page a timeline as long as the symbol's,
    /// so it plays in exports.
    @discardableResult
    public mutating func placeSymbol(_ id: UUID, at origin: CGPoint, size: CGSize? = nil, playback: SymbolPlayback? = nil,
                                     offset: Double? = nil, layerID: UUID? = nil) -> Element? {
        guard let symbol = symbolIndex[id] else { return nil }
        let size = size ?? CGSize(width: symbol.width, height: symbol.height)
        let layer = layerID ?? layers.first { !$0.locked && $0.visible }?.id ?? layers[0].id
        var e = Element(kind: .symbol, frame: CGRect(origin: origin, size: CGSize(width: max(1, size.width), height: max(1, size.height))),
                        layerID: layer)
        e.symbol = id
        e.style.roughness = 0
        e.playback = playback == .loop ? nil : playback
        e.offset = offset.flatMap { $0 == 0 || !$0.isFinite ? nil : $0 }
        elements.append(e)
        if let d = symbol.timeline?.duration, d > 0 {
            if timeline == nil { timeline = Timeline(fps: symbol.timeline?.fps ?? 12, duration: d) }
            else if timeline!.duration < d { timeline!.duration = d }
        }
        return e
    }

    /// Replaces instance `id` with plain copies of what it shows at rest, new ids each. Returns their ids.
    @discardableResult
    public mutating func breakApart(_ id: UUID) -> Set<UUID> {
        guard let at = elements.firstIndex(where: { $0.id == id && $0.kind == .symbol }) else { return [] }
        var alone = DottieDocument(id: self.id, layers: layers, elements: [elements[at]])
        alone.symbols = symbols
        var parts = alone.expandingSymbols(at: 0, posing: false).elements
        var fresh: [UUID: UUID] = [:]
        for p in parts { fresh[p.id] = UUID() }
        for i in parts.indices {
            parts[i].id = fresh[parts[i].id]!
            parts[i].link = parts[i].link.map { fresh[$0] ?? $0 }
            if var c = parts[i].connector {
                c.start.elementID = c.start.elementID.map { fresh[$0] ?? $0 }
                c.end.elementID = c.end.elementID.map { fresh[$0] ?? $0 }
                parts[i].connector = c
            }
        }
        // Connectors from the page that met the instance keep their place, now free.
        let index = elementIndex
        for i in elements.indices where elements[i].kind == .connector {
            guard var c = elements[i].connector, c.start.elementID == id || c.end.elementID == id else { continue }
            let (a, b) = Connector.endpoints(of: elements[i], in: self, index: index)
            if c.start.elementID == id { c.start = Endpoint(elementID: nil, port: c.start.port, x: a.x, y: a.y) }
            if c.end.elementID == id { c.end = Endpoint(elementID: nil, port: c.end.port, x: b.x, y: b.y) }
            elements[i].connector = c
        }
        elements.remove(at: at)
        elements.insert(contentsOf: parts, at: at)
        timeline?.tracks.removeAll { $0.element == id }
        return Set(parts.map(\.id))
    }

    /// Copies in the symbols `other` defines that instances here use, directly or nested, and this page lacks, so
    /// instances brought over from another page (pasted, Magic Moved) still show something.
    public mutating func adoptSymbols(from other: DottieDocument) {
        let theirs = other.symbolIndex
        guard !theirs.isEmpty else { return }
        var have = Set((symbols ?? []).map(\.id))
        var queue = elements.compactMap(\.symbol)
        var added: [Symbol] = []
        while let id = queue.popLast() {
            guard !have.contains(id), let s = theirs[id] else { continue }
            have.insert(id)
            added.append(s)
            queue += s.elements.compactMap(\.symbol)
        }
        if !added.isEmpty { symbols = (symbols ?? []) + added }
    }

    /// Drops symbols no instance on the page uses, directly or inside another symbol it uses.
    public mutating func pruneSymbols() {
        guard let all = symbols, !all.isEmpty else { return }
        let table = symbolIndex
        var used = Set<UUID>(), queue = elements.compactMap(\.symbol)
        while let id = queue.popLast() {
            guard used.insert(id).inserted, let s = table[id] else { continue }
            queue += s.elements.compactMap(\.symbol)
        }
        let kept = all.filter { used.contains($0.id) }
        symbols = kept.isEmpty ? nil : kept
    }
}
