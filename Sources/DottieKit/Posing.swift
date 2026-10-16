import Foundation

/// Editing an animation by posing it, as Flash's auto-key does: the editor shows the frame at a time `t`, and
/// what is changed there becomes keyframes at `t` instead of changes to the page.
extension DottieDocument {
    /// The page after `edited` (an edited copy of `resolved(at: t)`) is posed at time `t`.
    ///
    /// - A change to an element's frame, rotation, colors, stroke width or opacity becomes a key at `t` (or
    ///   on the key nearest `t`, within half a frame, so posing on a key's frame edits that key). If no key
    ///   set that property before, its value at 0 is keyed too, so the element moves from where it was
    ///   instead of jumping there for the whole animation.
    /// - Everything else that changed (text, look, links, z-order, a connector re-attached elsewhere, ...)
    ///   applies to the element itself.
    /// - While an element follows a path, the path decides its position, so position edits are ignored.
    /// - A new element is added to the page and appears at `t`, as drawn there (a copy made mid-fade keeps
    ///   that frame's opacity); a deleted one is hidden from `t` on, or removed outright at 0.
    public func applyingPose(_ edited: DottieDocument, at t: Double) -> DottieDocument {
        let t = Timeline.clampTime(t)
        func byID(_ d: DottieDocument) -> [UUID: Element] { Dictionary(d.elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        let before = byID(resolved(at: t))
        let atStart = byID(resolved(at: 0))
        let baseByID = byID(self)
        var tl = timeline ?? Timeline(duration: max(t, 1))
        tl.duration = max(tl.duration, t)

        /// Keys `new` (only the properties it sets), pinning any property no key has set yet at its 0s value.
        func key(_ id: UUID, _ new: Keyframe, base: Element) {
            var new = new
            if let existing = tl.key(of: id, at: t) { new.t = existing.t }
            let track = tl.track(for: id)
            if new.t > 0 {
                let s = atStart[id] ?? base
                var pin = Keyframe(t: 0)
                func unset<V>(_ p: (Keyframe) -> V?) -> Bool { !(track?.keys.contains { p($0) != nil } ?? false) }
                if new.x != nil, unset(\.x) { pin.x = s.x }
                if new.y != nil, unset(\.y) { pin.y = s.y }
                if new.width != nil, unset(\.width) { pin.width = s.width }
                if new.height != nil, unset(\.height) { pin.height = s.height }
                if new.rotation != nil, unset(\.rotation) { pin.rotation = s.angle }
                if new.fill != nil, unset(\.fill) { pin.fill = s.style.fill }
                if new.stroke != nil, unset(\.stroke) { pin.stroke = s.style.stroke }
                if new.strokeWidth != nil, unset(\.strokeWidth) { pin.strokeWidth = s.style.strokeWidth }
                if new.opacity != nil, unset(\.opacity) { pin.opacity = s.style.opacity ?? 1 }
                if pin != Keyframe(t: 0) { tl.setKey(pin, for: id) }
            }
            tl.setKey(new, for: id)
        }

        var merged: [UUID: Element] = [:]
        var added: [Element] = []
        for e in edited.elements {
            guard let base = baseByID[e.id] else {
                var drawn = e
                drawn.reveal = nil
                added.append(drawn)
                if t > 0 { tl.setKey(Keyframe(t: t, visible: true), for: e.id) }
                continue
            }
            guard let was = before[e.id] else { continue }   // hidden at t, so it can't have been edited
            // Start from the edit; put back what the animation drives, which becomes keys below.
            var m = e
            m.x = base.x; m.y = base.y; m.width = base.width; m.height = base.height; m.rotation = base.rotation
            m.style.fill = base.style.fill; m.style.opacity = base.style.opacity
            m.seed = base.seed; m.reveal = base.reveal
            var new = Keyframe(t: t)
            func diff(_ a: Double, _ b: Double, _ set: (inout Keyframe, Double) -> Void) {
                if abs(a - b) > 1e-6 { set(&new, b) }
            }
            if e.kind == .connector {
                // A connector's ends come from its shapes; the frame may have pinned them where a hidden shape
                // waits. Keep the page's ends unless the edit re-attached or moved them. Its stroke isn't keyed.
                if let c = e.connector, let w = was.connector, let b = base.connector {
                    if c.start == w.start { m.connector?.start = b.start }
                    if c.end == w.end { m.connector?.end = b.end }
                }
                diff(was.style.opacity ?? 1, e.style.opacity ?? 1) { $0.opacity = $1 }
            } else {
                m.style.stroke = base.style.stroke; m.style.strokeWidth = base.style.strokeWidth
                let path = tl.track(for: e.id)?.followSpan(at: t)
                if path == nil {
                    diff(was.x, e.x) { $0.x = $1 }
                    diff(was.y, e.y) { $0.y = $1 }
                }
                diff(was.width, e.width) { $0.width = $1 }
                diff(was.height, e.height) { $0.height = $1 }
                if path?.orient != true { diff(was.angle, e.angle) { $0.rotation = $1 } }
                diff(was.style.strokeWidth, e.style.strokeWidth) { $0.strokeWidth = $1 }
                if was.style.fill != e.style.fill { new.fill = e.style.fill }
                if was.style.stroke != e.style.stroke { new.stroke = e.style.stroke }
                diff(was.style.opacity ?? 1, e.style.opacity ?? 1) { $0.opacity = $1 }
            }
            merged[e.id] = m
            if new != Keyframe(t: t) { key(e.id, new, base: base) }
        }

        // Elements the frame showed keep their new stacking order; hidden ones keep their place.
        var order = edited.elements.lazy.map(\.id).filter { merged[$0] != nil }.makeIterator()
        var next = self
        next.elements = elements.map { b in merged[b.id] != nil ? merged[order.next()!]! : b } + added

        let deleted = Set(before.keys).subtracting(edited.elements.map(\.id))
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
