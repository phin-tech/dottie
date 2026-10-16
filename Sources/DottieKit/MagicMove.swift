import Foundation
import CoreGraphics

/// What `magicMove(to:)` did.
public struct MagicMoveSummary: Equatable, Sendable {
    /// Shapes found on both pages, now tweening from one pose to the other.
    public var moved: Int
    /// Elements only the target page has, copied in and faded up.
    public var entering: Int
    /// Elements only this page has, faded away.
    public var leaving: Int
}

extension DottieDocument {
    /// Keynote's Magic Move: animates this page, from `start` (the end of its timeline by default) over
    /// `duration` seconds, into the pose of `target` as it starts. Draw each end as an ordinary page and let
    /// Dottie tween between them; the keys it writes are ordinary keys, adjustable afterwards.
    ///
    /// A shape on this page matches one on the target with the same `anchor`, else one with the same seed,
    /// kind and text (a duplicated page keeps its shapes' seeds), else one with the same text. Each match must
    /// be the only candidate on both pages. Matched shapes tween their frame, rotation, line width, colors
    /// and opacity; their kind, text and the rest of their style stay this page's. Shapes only this page has
    /// fade out; shapes only the target has are copied in, hidden until the move, and fade in. A connector
    /// stays when the target joins the same two shapes, and otherwise fades out or in like a shape.
    /// Running it again finds the copies it made, so nothing is copied twice.
    @discardableResult
    public mutating func magicMove(to target: DottieDocument, at start: Double? = nil, duration: Double = 1,
                                   ease: Ease = .easeInOut) throws -> MagicMoveSummary {
        guard target.id != id else { throw OpsError.invalid("Magic Move needs another page to move to") }
        let t = Timeline.clampTime(start ?? timeline?.duration ?? 0)
        let d = min(max(0.05, duration.isFinite ? duration : 1), Timeline.maxDuration - t + 0.05)
        var tl = timeline ?? Timeline(duration: t + d)
        tl.duration = max(tl.duration, t + d)
        // The page's still keeps showing this page as drawn, not the next one it turns into.
        if tl.poster == nil { tl.poster = t }
        timeline = tl

        // Both ends as posed: this page at `t`, the target where it starts.
        func posed(_ e: Element) -> Element { tl.track(for: e.id)?.apply(to: e, at: t) ?? e }
        let here = elements.filter { tl.track(for: $0.id)?.isVisible(at: t) ?? true }.map(posed)
        let there = target.timeline == nil ? target.elements : target.resolved(at: 0).elements
        let originals = target.elementIndex

        // Shapes first, pass by pass, each pass among those still unmatched.
        var match: [UUID: UUID] = [:]   // target id -> this page's id
        func pair(by key: (Element) -> String?) {
            let mine = here.filter { $0.kind != .connector && !match.values.contains($0.id) }
            let theirs = there.filter { $0.kind != .connector && match[$0.id] == nil }
            let a = Dictionary(grouping: mine.compactMap { e in key(e).map { ($0, e) } }, by: \.0)
            let b = Dictionary(grouping: theirs.compactMap { e in key(e).map { ($0, e) } }, by: \.0)
            for (k, list) in b where list.count == 1 {
                guard let other = a[k], other.count == 1 else { continue }
                match[list[0].1.id] = other[0].1.id
            }
        }
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        pair { nonEmpty($0.anchor) }
        pair { e in "\(e.kind.rawValue) \(originals[e.id]?.seed ?? e.seed) \(e.text ?? "")" }
        pair { nonEmpty($0.text) }

        var summary = MagicMoveSummary(moved: 0, entering: 0, leaving: 0)
        let mine = Dictionary(here.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for b in there where b.kind != .connector {
            guard let aid = match[b.id], let a = mine[aid] else { continue }
            var from = Keyframe(t: t, ease: ease == .linear ? nil : ease), to = Keyframe(t: t + d)
            func key(_ p: WritableKeyPath<Keyframe, Double?>, _ x: Double, _ y: Double) {
                if x != y { from[keyPath: p] = x; to[keyPath: p] = y }
            }
            func key(_ p: WritableKeyPath<Keyframe, RGBA?>, _ x: RGBA, _ y: RGBA) {
                if x != y { from[keyPath: p] = x; to[keyPath: p] = y }
            }
            key(\.x, a.x, b.x); key(\.y, a.y, b.y); key(\.width, a.width, b.width); key(\.height, a.height, b.height)
            key(\.rotation, a.angle, b.angle); key(\.strokeWidth, a.style.strokeWidth, b.style.strokeWidth)
            key(\.stroke, a.style.stroke, b.style.stroke); key(\.fill, a.style.fill, b.style.fill)
            key(\.opacity, a.style.opacity ?? 1, b.style.opacity ?? 1)
            summary.moved += 1
            guard from != Keyframe(t: t, ease: from.ease) else { continue }   // already there
            tl.setKey(from, for: aid); tl.setKey(to, for: aid)
        }
        timeline = tl

        // Connectors join up: one stays when the target joins the same two shapes, ends mapped through `match`.
        func ends(_ c: ConnectorData, _ map: (UUID) -> UUID?) -> String? {
            guard let s = c.start.elementID.flatMap(map), let e = c.end.elementID.flatMap(map) else { return nil }
            return "\(s) \(e)"
        }
        var theirLinks: [String: Int] = [:]
        for b in there { if let c = b.connector, let k = ends(c, { match[$0] }) { theirLinks[k, default: 0] += 1 } }
        var kept = Set<String>()
        var leaving: [UUID] = []
        for a in here {
            if let c = a.connector {
                if let k = ends(c, { $0 }), theirLinks[k] != nil, !kept.contains(k) { kept.insert(k); continue }
                leaving.append(a.id)
            } else if !match.values.contains(a.id) {
                leaving.append(a.id)
            }
        }

        // What only the target has comes in as copies, connectors bound to this page's shapes.
        let layerIDs = Set(layers.map(\.id))
        var copyOf: [UUID: UUID] = [:]
        var entering: [Element] = []
        for b in there where b.kind != .connector && match[b.id] == nil { copyOf[b.id] = UUID() }
        for b in there {
            if let c = b.connector, let k = ends(c, { match[$0] }), kept.contains(k) { kept.remove(k); continue }
            guard b.kind == .connector || copyOf[b.id] != nil else { continue }
            var e = originals[b.id] ?? b
            e.id = copyOf[b.id] ?? UUID()
            e.groupID = nil
            e.link = nil
            if !layerIDs.contains(e.layerID) { e.layerID = layers.first?.id ?? e.layerID }
            if var c = e.connector {
                func remap(_ p: inout Endpoint) {
                    guard let id = p.elementID else { return }
                    p.elementID = match[id] ?? copyOf[id]
                    if p.elementID == nil { p = Endpoint(elementID: nil, port: p.port, x: p.x, y: p.y) }
                }
                remap(&c.start); remap(&c.end)
                e.connector = c
            }
            entering.append(e)
        }
        elements += entering
        for id in leaving { try addTransition(.fadeOut, to: id, at: t, duration: d) }
        for e in entering { try addTransition(.fadeIn, to: e.id, at: t, duration: d) }
        summary.entering = entering.count
        summary.leaving = leaving.count
        return summary
    }
}
