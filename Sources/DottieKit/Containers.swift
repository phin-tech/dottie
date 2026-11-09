import Foundation
import CoreGraphics

/// What makes a rectangle a container (ADR 0006): a titled box holding the elements whose `containerID` is its id.
/// It fits round them (with room for its title) unless it was sized by hand, and moving it moves them. A container
/// with `lanes` is a swimlane: its child containers are its lanes, stacked in rows or columns across it.
public struct ContainerData: Codable, Equatable, Sendable {
    /// Keeps the size it was given instead of fitting its contents.
    public var fixed: Bool?
    /// A swimlane's lanes: its child containers, as rows (one under another) or columns.
    public var lanes: LaneDirection?
    public init(fixed: Bool? = nil, lanes: LaneDirection? = nil) { self.fixed = fixed; self.lanes = lanes }
}

public enum LaneDirection: String, Codable, Sendable, CaseIterable { case rows, columns }

extension DottieDocument {
    /// Room round a container's contents.
    public static let containerPadding = 20.0
    /// The smallest a container gets.
    static let containerMinimum = CGSize(width: 120, height: 80)

    /// How tall a container's title band is: its text's height with some room, or none without a title.
    static func titleBand(_ e: Element) -> Double {
        guard let t = e.text, !t.isEmpty else { return 0 }
        return Double(t.components(separatedBy: "\n").count) * e.style.fontSize * 1.25 + 14
    }

    /// The elements in container `id`, directly.
    public func children(of id: UUID) -> [Element] { elements.filter { $0.containerID == id } }

    /// Container `id` and everything in it, at any depth (ids).
    public func descendants(of id: UUID) -> Set<UUID> {
        var out = Set<UUID>(), queue = [id]
        while let next = queue.popLast() {
            for e in elements where e.containerID == next && !out.contains(e.id) { out.insert(e.id); queue.append(e.id) }
        }
        return out
    }

    /// The innermost container whose frame holds `p`, leaving out `except` and what's in it.
    func container(at p: CGPoint, except: UUID?) -> Element? {
        let banned = except.map { descendants(of: $0).union([$0]) } ?? []
        // Later in the page is on top, and a container nested in another is drawn after it.
        return elements.last { $0.container != nil && !banned.contains($0.id) && $0.frame.contains(p) }
    }

    /// Containers fitted round their contents, innermost first; swimlanes' lanes laid out across them. Each
    /// container's title band is its label's place.
    public mutating func fitContainers() {
        let containers = elements.indices.filter { elements[$0].container != nil }
        guard !containers.isEmpty else { return }
        // Innermost first: deepest nesting first.
        func depth(_ e: Element) -> Int {
            var d = 0, at = e.containerID, seen = Set<UUID>()
            while let id = at, !seen.contains(id), let up = elements.first(where: { $0.id == id }) { seen.insert(id); d += 1; at = up.containerID }
            return d
        }
        let order = containers.sorted { depth(elements[$0]) > depth(elements[$1]) }
        for i in order {
            let c = elements[i]
            let band = Self.titleBand(c), pad = Self.containerPadding
            let kids = elements.indices.filter { elements[$0].containerID == c.id && elements[$0].kind != .connector }
            if let lanes = c.container?.lanes {
                layOutLanes(i, kids.filter { elements[$0].container != nil }, lanes, band: band)
            } else if c.container?.fixed != true, !kids.isEmpty {
                var box = kids.map { elements[$0].rotatedBounds }.reduce(CGRect.null) { $0.union($1) }
                box = CGRect(x: box.minX - pad, y: box.minY - pad - band, width: box.width + 2 * pad, height: box.height + 2 * pad + band)
                if box.width < Self.containerMinimum.width { box.size.width = Self.containerMinimum.width }
                if box.height < Self.containerMinimum.height { box.size.height = Self.containerMinimum.height }
                elements[i].frame = box
            }
            let h = elements[i].height
            elements[i].labelRect = band > 0 && h > 0 ? NormalizedRect(x: 0, y: 0, width: 1, height: min(1, band / h)) : nil
        }
    }

    /// A swimlane's lanes, each fitted to its contents, then stacked from below the title and stretched to the
    /// widest (rows) or tallest (columns); a lane that moves takes what's in it along.
    private mutating func layOutLanes(_ i: Int, _ lanes: [Int], _ direction: LaneDirection, band: Double) {
        guard !lanes.isEmpty else { return }
        let origin = CGPoint(x: elements[i].x, y: elements[i].y + band)
        let across = lanes.map { direction == .rows ? elements[$0].width : elements[$0].height }.max() ?? 0
        var at = 0.0
        for l in lanes {
            var f = elements[l].frame
            let target = direction == .rows
                ? CGRect(x: origin.x, y: origin.y + at, width: max(across, elements[i].width), height: f.height)
                : CGRect(x: origin.x + at, y: origin.y, width: f.width, height: max(across, elements[i].height - band))
            let d = CGPoint(x: target.minX - f.minX, y: target.minY - f.minY)
            if d != .zero { translate(descendants(of: elements[l].id), by: d) }
            f = target
            elements[l].frame = f
            at += direction == .rows ? f.height : f.width
        }
        let size = direction == .rows ? CGSize(width: max(across, elements[i].width), height: at + band)
                                      : CGSize(width: at, height: (lanes.map { elements[$0].height }.max() ?? 0) + band)
        elements[i].width = size.width; elements[i].height = size.height
    }

    /// Moves the elements `ids` by `d`; connectors' free ends and bends go too.
    mutating func translate(_ ids: Set<UUID>, by d: CGPoint) {
        guard !ids.isEmpty else { return }
        for i in elements.indices where ids.contains(elements[i].id) {
            elements[i].x += d.x; elements[i].y += d.y
            if var c = elements[i].connector {
                if c.start.elementID == nil { c.start.x += d.x; c.start.y += d.y }
                if c.end.elementID == nil { c.end.x += d.x; c.end.y += d.y }
                c.waypoints = c.waypoints?.map { Waypoint(x: $0.x + d.x, y: $0.y + d.y) }
                elements[i].connector = c
            }
        }
    }

    /// This page after an edit from `old` (ADR 0006): a container that moved takes what's in it along; one resized
    /// by hand keeps that size; a shape moved into a container joins it and one moved out of its container leaves;
    /// then containers fit their contents, behind them.
    public func reconcilingContainers(from old: DottieDocument?) -> DottieDocument {
        guard elements.contains(where: { $0.container != nil || $0.containerID != nil }) else { return self }
        var copy = self
        if let old {
            let before = old.elementIndex
            var moved = Set<UUID>()
            for e in copy.elements {
                if let was = before[e.id], was.x != e.x || was.y != e.y || was.width != e.width || was.height != e.height { moved.insert(e.id) }
            }
            // Containers moved (not resized) take their contents that didn't move themselves.
            var carried = Set<UUID>()
            for i in copy.elements.indices where copy.elements[i].container != nil {
                let e = copy.elements[i]
                // One carried by its own container has been moved already, with all it holds.
                guard let was = before[e.id], !carried.contains(e.id) else { continue }
                if was.width == e.width && was.height == e.height && (was.x != e.x || was.y != e.y) {
                    let inside = copy.descendants(of: e.id).subtracting(moved)
                    copy.translate(inside, by: CGPoint(x: e.x - was.x, y: e.y - was.y))
                    carried.formUnion(inside)
                } else if was.width != e.width || was.height != e.height, e.container?.lanes == nil {
                    copy.elements[i].container?.fixed = true
                }
            }
            // Shapes moved on their own, or new ones without a container: into the container under their center, or
            // out of theirs.
            for i in copy.elements.indices where copy.elements[i].kind != .connector && !carried.contains(copy.elements[i].id) {
                let e = copy.elements[i]
                if let was = before[e.id] {
                    guard moved.contains(e.id), was.containerID == e.containerID else { continue }
                } else if e.containerID != nil { continue }
                let target = copy.container(at: CGPoint(x: e.frame.midX, y: e.frame.midY), except: e.id)
                if target?.id != e.containerID { copy.elements[i].containerID = target?.id }
            }
        }
        copy.fitContainers()
        copy.keepContainersBehind()
        return copy
    }

    /// Moves each container just behind the first of its contents when one is drawn behind it.
    mutating func keepContainersBehind() {
        for _ in 0..<elements.count {
            var changed = false
            for (i, e) in elements.enumerated() where e.container != nil {
                guard let first = elements.firstIndex(where: { $0.containerID == e.id }), first < i else { continue }
                let c = elements.remove(at: i)
                elements.insert(c, at: first)
                changed = true
                break
            }
            if !changed { return }
        }
    }
}

extension DottieFile {
    /// `DottieDocument.reconcilingContainers(from:)` for each page, against the page with its id in `old`.
    public func reconcilingContainers(from old: DottieFile?) -> DottieFile {
        var copy = self
        copy.pages = pages.map { p in p.reconcilingContainers(from: old?.pages.first { $0.id == p.id }) }
        return copy
    }
}

extension DiagramOps {
    /// A new container titled `title` round `children` (shapes on the page; connectors between them are left as they
    /// are), or at `frame` when it has none, behind everything it holds. `lanes` makes it a swimlane, whose children
    /// should be containers (its lanes). `parent` puts it in another container.
    @discardableResult
    public static func addContainer(_ doc: inout DottieDocument, title: String?, children: [UUID] = [], frame: CGRect? = nil,
                                    lanes: LaneDirection? = nil, parent: UUID? = nil, roughness: Double? = nil,
                                    fill: RGBA? = nil, stroke: RGBA? = nil) throws -> Element {
        for id in children {
            guard let e = doc.elements.first(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
            guard e.kind != .connector else { throw OpsError.invalid("A container holds shapes; connectors go with their ends") }
        }
        if let parent { try checkParent(doc, parent) }
        var style = Style()
        style.fill = fill ?? RGBA(r: 0.5, g: 0.55, b: 0.65, a: 0.08)
        if let stroke { style.stroke = stroke }
        style.strokeWidth = 1.5
        style.fontSize = 16
        if let roughness { style.roughness = roughness }
        let f = frame ?? CGRect(x: 0, y: 0, width: 240, height: 160)
        var e = Element(kind: .rectangle, frame: f, style: style, layerID: activeLayerID(&doc), text: title.flatMap { $0.isEmpty ? nil : $0 })
        e.container = ContainerData(fixed: frame != nil && children.isEmpty ? true : nil, lanes: lanes)
        e.containerID = parent
        // Behind what it holds: before the first of them, else at the back of its parent's contents, else the back.
        let first = doc.elements.firstIndex { children.contains($0.id) }
        doc.elements.insert(e, at: first ?? doc.elements.count)
        for i in doc.elements.indices where children.contains(doc.elements[i].id) { doc.elements[i].containerID = e.id }
        doc.fitContainers()
        doc.keepContainersBehind()
        return doc.elements.first { $0.id == e.id }!
    }

    private static func checkParent(_ doc: DottieDocument, _ parent: UUID, child: UUID? = nil) throws {
        guard let p = doc.elements.first(where: { $0.id == parent }) else { throw OpsError.notFound("No element \(parent.uuidString)") }
        guard p.container != nil else { throw OpsError.invalid("\(parent.uuidString) isn't a container; make one with add_container") }
        if let child, child == parent || doc.descendants(of: child).contains(parent) {
            throw OpsError.invalid("A container can't go inside itself or something it holds")
        }
    }

    /// Puts element `id` in container `parent`, or takes it out with nil; containers fit round their contents again.
    public static func setParent(_ doc: inout DottieDocument, id: UUID, parent: UUID?) throws {
        guard let i = doc.elements.firstIndex(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
        guard doc.elements[i].kind != .connector else { throw OpsError.invalid("Connectors go with their ends, not in containers") }
        if let parent { try checkParent(doc, parent, child: id) }
        doc.elements[i].containerID = parent
        doc.fitContainers()
        doc.keepContainersBehind()
    }
}
