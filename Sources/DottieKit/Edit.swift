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
    @discardableResult
    public mutating func paste(_ data: Data, offset: CGPoint = CGPoint(x: 16, y: 16)) -> Set<UUID> {
        guard let items = try? JSONDecoder().decode([Element].self, from: data), !items.isEmpty else { return [] }
        var idMap: [UUID: UUID] = [:]
        var groupMap: [UUID: UUID] = [:]
        for e in items { idMap[e.id] = UUID() }
        let fallback = layers.first { $0.visible && !$0.locked }?.id ?? layers[0].id
        var added: [Element] = []
        for var e in items {
            e.id = idMap[e.id]!
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
}
