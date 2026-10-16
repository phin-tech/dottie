import Foundation

/// Editing an animation by posing it, as Flash's auto-key does: the editor shows the frame at a time `t`, and
/// what is changed there becomes keyframes at `t` instead of changes to the page.
extension DottieDocument {
    /// The page after `edited` (an edited copy of `resolved(at: t)`) is posed at time `t`.
    ///
    /// - A change to an element's frame, rotation, colors or stroke width becomes a key at `t`. If no key set
    ///   that property before, the old value is also keyed at 0, so the element moves from where it was
    ///   instead of jumping there for the whole animation.
    /// - Changes that can't be animated (text, fill style, dash, font, links, ...) apply to the element itself.
    /// - A new element is added to the page and appears at `t`; a deleted one is hidden from `t` on (or
    ///   removed outright at 0). Connectors follow their shapes, so only their label and look change.
    public func applyingPose(_ edited: DottieDocument, at t: Double) -> DottieDocument {
        let frame = resolved(at: t)
        let before = Dictionary(frame.elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let baseIndex = Dictionary(elements.indices.map { (elements[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
        var next = self
        var tl = timeline ?? Timeline(duration: max(t, 1))
        tl.duration = max(tl.duration, t)

        func key(_ id: UUID, _ old: Keyframe, _ new: Keyframe) {
            let track = tl.track(for: id)
            if t > 0 {
                // Pin the old value at 0 for each property no key has set yet.
                var start = Keyframe(t: 0)
                func unset<V>(_ p: (Keyframe) -> V?) -> Bool { !(track?.keys.contains { p($0) != nil } ?? false) }
                if new.x != nil, unset(\.x) { start.x = old.x }
                if new.y != nil, unset(\.y) { start.y = old.y }
                if new.width != nil, unset(\.width) { start.width = old.width }
                if new.height != nil, unset(\.height) { start.height = old.height }
                if new.rotation != nil, unset(\.rotation) { start.rotation = old.rotation }
                if new.fill != nil, unset(\.fill) { start.fill = old.fill }
                if new.stroke != nil, unset(\.stroke) { start.stroke = old.stroke }
                if new.strokeWidth != nil, unset(\.strokeWidth) { start.strokeWidth = old.strokeWidth }
                if new.opacity != nil, unset(\.opacity) { start.opacity = old.opacity }
                if start != Keyframe(t: 0) { tl.setKey(start, for: id) }
            }
            tl.setKey(new, for: id)
        }

        for e in edited.elements {
            guard let i = baseIndex[e.id] else {
                // Drawn while posing: on the page, appearing here.
                var added = e
                added.reveal = nil
                next.elements.append(added)
                if t > 0 { tl.setKey(Keyframe(t: t, visible: true), for: e.id) }
                continue
            }
            guard let was = before[e.id] else { continue }   // hidden at t, so it can't have been edited
            // What can't be animated goes straight onto the element.
            var base = next.elements[i]
            base.text = e.text; base.link = e.link; base.anchor = e.anchor; base.groupID = e.groupID
            base.layerID = e.layerID
            base.style.fillStyle = e.style.fillStyle; base.style.dash = e.style.dash
            base.style.roughness = e.style.roughness; base.style.bowing = e.style.bowing
            base.style.fontSize = e.style.fontSize; base.style.gridSize = e.style.gridSize
            if e.kind == .connector {
                base.connector?.routing = e.connector?.routing ?? .straight
                base.connector?.startHead = e.connector?.startHead ?? .none
                base.connector?.endHead = e.connector?.endHead ?? .arrow
                base.style.stroke = e.style.stroke; base.style.strokeWidth = e.style.strokeWidth
                next.elements[i] = base
                continue
            }
            if e.kind == .freehand || e.kind == .path { base.points = e.points; base.path = e.path; base.subpaths = e.subpaths }
            next.elements[i] = base
            // What can, becomes keys.
            var old = Keyframe(t: 0), new = Keyframe(t: t)
            func diff(_ a: Double, _ b: Double, _ set: (inout Keyframe, Double) -> Void) {
                if abs(a - b) > 1e-6 { set(&old, a); set(&new, b) }
            }
            diff(was.x, e.x) { $0.x = $1 }
            diff(was.y, e.y) { $0.y = $1 }
            diff(was.width, e.width) { $0.width = $1 }
            diff(was.height, e.height) { $0.height = $1 }
            diff(was.angle, e.angle) { $0.rotation = $1 }
            diff(was.style.strokeWidth, e.style.strokeWidth) { $0.strokeWidth = $1 }
            if was.style.fill != e.style.fill { old.fill = was.style.fill; new.fill = e.style.fill }
            if was.style.stroke != e.style.stroke { old.stroke = was.style.stroke; new.stroke = e.style.stroke }
            diff(was.style.opacity ?? 1, e.style.opacity ?? 1) { $0.opacity = $1 }
            if new != Keyframe(t: t) { key(e.id, old, new) }
        }

        let kept = Set(edited.elements.map(\.id))
        let deleted = Set(before.keys).subtracting(kept)
        if t <= 0 {
            next.remove(deleted)
        } else {
            for id in deleted { tl.setKey(Keyframe(t: t, visible: false), for: id) }
        }
        // Page settings changed while posing apply to the page.
        next.layers = edited.layers; next.guidesX = edited.guidesX; next.guidesY = edited.guidesY
        next.guidesLocked = edited.guidesLocked; next.theme = edited.theme; next.name = edited.name
        next.timeline = tl
        return next
    }

    // MARK: Menu-sized operations

    /// Gives a still page an empty timeline to add keys to.
    public mutating func startAnimation(duration: Double = 3, fps: Double = 15) {
        if timeline == nil { timeline = Timeline(fps: fps, duration: duration) }
    }

    /// Adds `transition` to each of `ids` in turn, `stagger` seconds apart, starting at `t`. Connectors take
    /// only `drawIn`; others are skipped. Returns how many elements it was added to.
    @discardableResult
    public mutating func addTransition(_ transition: Transition, to ids: [UUID], at t: Double,
                                       stagger: Double = 0.15, duration: Double? = nil) throws -> Int {
        let targets = ids.filter { id in
            guard let e = elements.first(where: { $0.id == id }) else { return false }
            return e.kind != .connector || transition.appliesToConnectors
        }
        for (i, id) in targets.enumerated() {
            try addTransition(transition, to: id, at: t + Double(i) * stagger, duration: duration)
        }
        return targets.count
    }

    /// Removes every key, path and boil override from `ids`; the page's timeline stays.
    public mutating func clearAnimation(of ids: Set<UUID>) {
        timeline?.tracks.removeAll { ids.contains($0.element) }
    }
}
