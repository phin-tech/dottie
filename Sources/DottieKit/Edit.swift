import Foundation
import CoreGraphics

public enum AlignEdge: String, Codable, Sendable, CaseIterable { case left, centerX, right, top, centerY, bottom }
public enum DistributeAxis: String, Codable, Sendable { case horizontal, vertical }

/// Document-level editing commands: clipboard, groups, arrangement. Pure value transforms so the
/// app and the MCP server share them and they can be tested headless.
extension DottieDocument {
    // MARK: Clipboard

    /// Serialized copy of `ids`. Connectors bound to shapes outside the copied set are frozen to
    /// free points, so a paste never reaches back into the source drawing.
    public func clipboardData(for ids: Set<UUID>) -> Data? {
        var picked = elements.filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return nil }
        for i in picked.indices where picked[i].kind == .connector {
            guard var c = picked[i].connector else { continue }
            let (s, e) = Connector.endpoints(of: picked[i], in: self)
            if let id = c.start.elementID, !ids.contains(id) { c.start = .free(s) }
            if let id = c.end.elementID, !ids.contains(id) { c.end = .free(e) }
            picked[i].connector = c
        }
        return try? JSONEncoder().encode(picked)
    }

    /// Adds clipboard contents with fresh ids, offset by `offset`. Returns the new element ids.
    /// A link to an element outside the clipboard survives when the target is on this page or `keepsLink` says
    /// it exists elsewhere in the file.
    @discardableResult
    public mutating func paste(_ data: Data, offset: CGPoint = CGPoint(x: 16, y: 16),
                               keepsLink: (UUID) -> Bool = { _ in false }) -> Set<UUID> {
        guard let items = try? JSONDecoder().decode([Element].self, from: data), !items.isEmpty else { return [] }
        var idMap: [UUID: UUID] = [:]
        var groupMap: [UUID: UUID] = [:]
        for e in items { idMap[e.id] = UUID() }
        let fallback = layers.first { $0.visible && !$0.locked }?.id ?? layers[0].id
        let existing = items.contains { $0.link != nil } ? Set(elements.map(\.id)) : []
        var added: [Element] = []
        for var e in items {
            e.id = idMap[e.id]!
            // A link follows its target into the copy; otherwise it survives only if the target is still in the file.
            if let t = e.link { e.link = idMap[t] ?? (existing.contains(t) || keepsLink(t) ? t : nil) }
            e.seed = .random(in: 1...UInt32.max)
            if !layers.contains(where: { $0.id == e.layerID && !$0.locked }) { e.layerID = fallback }
            if let g = e.groupID { e.groupID = groupMap[g, default: UUID()]; groupMap[g] = e.groupID }
            if var c = e.connector {
                for isStart in [true, false] {
                    var ep = isStart ? c.start : c.end
                    if let id = ep.elementID { ep.elementID = idMap[id] }
                    if ep.elementID == nil { ep.x += offset.x; ep.y += offset.y }
                    if isStart { c.start = ep } else { c.end = ep }
                }
                e.connector = c
            } else {
                e.x += offset.x; e.y += offset.y
            }
            added.append(e)
        }
        elements.append(contentsOf: added)
        return Set(added.map(\.id))
    }

    /// Adds artwork positioned with its top-left at the origin (an import, a stencil), centered on
    /// `center`, on `layerID`, with fresh ids and group ids. Returns the new element ids.
    @discardableResult
    public mutating func insert(_ art: [Element], size: CGSize, center: CGPoint, layerID: UUID) -> Set<UUID> {
        var items = art
        for i in items.indices { items[i].layerID = layerID }
        guard let data = try? JSONEncoder().encode(items) else { return [] }
        return paste(data, offset: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    /// Copy + paste in one step. Returns the new ids.
    @discardableResult
    public mutating func duplicate(_ ids: Set<UUID>, offset: CGPoint = CGPoint(x: 16, y: 16)) -> Set<UUID> {
        guard let data = clipboardData(for: ids) else { return [] }
        return paste(data, offset: offset)
    }

    // MARK: Groups

    /// `ids` plus every element that shares a group with one of them.
    public func expandingGroups(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(elements.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !groups.isEmpty else { return ids }
        return ids.union(elements.filter { $0.groupID.map(groups.contains) == true }.map(\.id))
    }

    /// Puts the elements in one new group, replacing any groups they were in. Needs two or more.
    @discardableResult
    public mutating func group(_ ids: Set<UUID>) -> UUID? {
        let ids = expandingGroups(ids)
        guard ids.count >= 2 else { return nil }
        let g = UUID()
        for i in elements.indices where ids.contains(elements[i].id) { elements[i].groupID = g }
        return g
    }

    public mutating func ungroup(_ ids: Set<UUID>) {
        let ids = expandingGroups(ids)
        for i in elements.indices where ids.contains(elements[i].id) { elements[i].groupID = nil }
    }

    // MARK: Links

    /// Points every element in `ids` at `target`, or clears their links when it is nil. The target may be on
    /// this page or on any of `otherPages`.
    public mutating func setLink(_ ids: Set<UUID>, to target: UUID?, otherPages: [DottieDocument] = []) throws {
        if let target {
            guard let t = elements.first(where: { $0.id == target })
                    ?? otherPages.lazy.compactMap({ $0.elements.first { $0.id == target } }).first
            else { throw OpsError.notFound("No element \(target.uuidString)") }
            guard t.kind != .connector else { throw OpsError.invalid("A link must point at a shape, not a connector") }
            guard !ids.contains(target) else { throw OpsError.invalid("An element cannot link to itself") }
        }
        for i in elements.indices where ids.contains(elements[i].id) { elements[i].link = target }
    }

    /// Where following a link to `id` should look: the element, or its whole group so a grouped "section"
    /// is shown complete. nil when the link is broken (the element is gone or its layer is hidden).
    public func linkBounds(to id: UUID) -> CGRect? {
        guard let t = elements.first(where: { $0.id == id }),
              layers.first(where: { $0.id == t.layerID })?.visible == true else { return nil }
        let b = selectionBounds(expandingGroups([id]))
        return b.isNull ? nil : b
    }

    // MARK: Arrangement

    private func shapeIndices(_ ids: Set<UUID>) -> [Int] {
        elements.indices.filter { ids.contains(elements[$0].id) && elements[$0].kind != .connector }
    }

    /// Aligns shapes to the combined bounds of the selection. Connectors follow their bindings.
    public mutating func align(_ ids: Set<UUID>, to edge: AlignEdge) {
        let idx = shapeIndices(ids)
        guard idx.count >= 2 else { return }
        let box = idx.map { elements[$0].frame }.reduce(CGRect.null) { $0.union($1) }
        for i in idx {
            let f = elements[i].frame
            switch edge {
            case .left: elements[i].x = box.minX
            case .centerX: elements[i].x = box.midX - f.width / 2
            case .right: elements[i].x = box.maxX - f.width
            case .top: elements[i].y = box.minY
            case .centerY: elements[i].y = box.midY - f.height / 2
            case .bottom: elements[i].y = box.maxY - f.height
            }
        }
    }

    /// Spaces shapes so the gaps between them are equal; the outermost two stay put. Needs three.
    public mutating func distribute(_ ids: Set<UUID>, along axis: DistributeAxis) {
        var idx = shapeIndices(ids)
        guard idx.count >= 3 else { return }
        func lo(_ i: Int) -> Double { axis == .horizontal ? elements[i].x : elements[i].y }
        func len(_ i: Int) -> Double { axis == .horizontal ? elements[i].width : elements[i].height }
        idx.sort { lo($0) < lo($1) }
        let start = lo(idx[0]), end = lo(idx[idx.count - 1]) + len(idx[idx.count - 1])
        let gap = (end - start - idx.map(len).reduce(0, +)) / Double(idx.count - 1)
        var cursor = start
        for i in idx {
            if axis == .horizontal { elements[i].x = cursor } else { elements[i].y = cursor }
            cursor += len(i) + gap
        }
    }

    public enum ZMove: Sendable { case toFront, toBack, forward, backward }

    /// Reorders z-position, keeping the selection's relative order.
    public mutating func reorder(_ ids: Set<UUID>, _ move: ZMove) {
        let picked = elements.filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return }
        switch move {
        case .toFront:
            elements = elements.filter { !ids.contains($0.id) } + picked
        case .toBack:
            elements = picked + elements.filter { !ids.contains($0.id) }
        case .forward:
            for i in elements.indices.reversed() where ids.contains(elements[i].id) && i + 1 < elements.count && !ids.contains(elements[i + 1].id) {
                elements.swapAt(i, i + 1)
            }
        case .backward:
            for i in elements.indices where ids.contains(elements[i].id) && i > 0 && !ids.contains(elements[i - 1].id) {
                elements.swapAt(i, i - 1)
            }
        }
    }

    // MARK: Rotation

    /// Union of the selected shapes' rotated bounds; connectors don't contribute.
    public func selectionBounds(_ ids: Set<UUID>) -> CGRect {
        elements.filter { ids.contains($0.id) && $0.kind != .connector }.map(\.rotatedBounds)
            .reduce(CGRect.null) { $0.union($1) }
    }

    /// Turns shapes about a shared `center` by `delta` radians (clockwise): each shape's own angle
    /// grows by `delta` and its position orbits the center. Free connector ends orbit too; bound ends
    /// follow their shapes.
    public mutating func rotate(_ ids: Set<UUID>, by delta: Double, about center: CGPoint) {
        for i in elements.indices where ids.contains(elements[i].id) {
            if var c = elements[i].connector {
                for isStart in [true, false] {
                    var ep = isStart ? c.start : c.end
                    if ep.elementID == nil {
                        let p = Element.rotate(CGPoint(x: ep.x, y: ep.y), about: center, by: delta)
                        ep.x = p.x; ep.y = p.y
                    }
                    if isStart { c.start = ep } else { c.end = ep }
                }
                elements[i].connector = c
            } else {
                let f = elements[i].frame
                let m = Element.rotate(CGPoint(x: f.midX, y: f.midY), about: center, by: delta)
                elements[i].x = m.x - f.width / 2
                elements[i].y = m.y - f.height / 2
                var a = (elements[i].angle + delta).truncatingRemainder(dividingBy: 2 * .pi)
                if a > .pi { a -= 2 * .pi } else if a <= -.pi { a += 2 * .pi }
                elements[i].rotation = abs(a) < 1e-9 ? nil : a
            }
        }
    }

    // MARK: Layers

    /// Elements back to front: lower layers first, array order within a layer. This is what is drawn
    /// and what a click hits, so reordering layers reorders the picture.
    public var orderedElements: [Element] {
        guard layers.count > 1 else { return elements }
        // Bucket by layer rank: stable, and linear instead of a sort on every draw and click.
        let rank = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($1.id, $0) })
        var buckets = [[Element]](repeating: [], count: layers.count)
        for e in elements { buckets[rank[e.layerID] ?? 0].append(e) }
        return buckets.flatMap { $0 }
    }

    /// Adds a layer above `above` (or on top). Returns its id.
    @discardableResult
    public mutating func addLayer(name: String? = nil, above: UUID? = nil) -> UUID {
        let layer = Layer(name: name ?? "Layer \(layers.count + 1)")
        let at = above.flatMap { id in layers.firstIndex { $0.id == id } }.map { $0 + 1 } ?? layers.count
        layers.insert(layer, at: at)
        return layer.id
    }

    /// Removes a layer; its elements move to the neighbouring layer so nothing is lost.
    /// A document always keeps at least one layer.
    @discardableResult
    public mutating func removeLayer(_ id: UUID) -> Bool {
        guard layers.count > 1, let i = layers.firstIndex(where: { $0.id == id }) else { return false }
        let heir = layers[i > 0 ? i - 1 : i + 1].id
        for k in elements.indices where elements[k].layerID == id { elements[k].layerID = heir }
        layers.remove(at: i)
        return true
    }

    /// Moves a layer one step toward the front (`+1`) or back (`-1`).
    public mutating func moveLayer(_ id: UUID, by step: Int) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + step, 0), layers.count - 1)
        guard j != i else { return }
        layers.swapAt(i, j)
    }

    public mutating func editLayer(_ id: UUID, _ change: (inout Layer) -> Void) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layers[i])
    }

    /// Moves `ids` to `layer`, in front of `target` (just above it in z-order), or on top of the layer when
    /// `target` is nil. Their relative order is kept. A target inside `ids` is ignored.
    public mutating func move(_ ids: Set<UUID>, toLayer layer: UUID, inFrontOf target: UUID?) {
        guard layers.contains(where: { $0.id == layer }) else { return }
        var picked = elements.filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return }
        for i in picked.indices { picked[i].layerID = layer }
        var rest = elements.filter { !ids.contains($0.id) }
        let at: Int
        if let target, !ids.contains(target), let i = rest.firstIndex(where: { $0.id == target }) {
            at = i + 1
        } else if let last = rest.lastIndex(where: { $0.layerID == layer }) {
            at = last + 1
        } else {
            at = rest.count
        }
        rest.insert(contentsOf: picked, at: at)
        elements = rest
    }

    public mutating func move(_ ids: Set<UUID>, toLayer layer: UUID) {
        guard layers.contains(where: { $0.id == layer }) else { return }
        for k in elements.indices where ids.contains(elements[k].id) { elements[k].layerID = layer }
    }
}
