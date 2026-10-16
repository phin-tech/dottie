import Foundation

/// The curve from one keyframe to the next.
public enum Ease: String, Codable, Sendable, CaseIterable {
    case linear, easeIn, easeOut, easeInOut
    /// Keep this key's value until the next key, then jump (a Flash "keyframe without a tween").
    case hold

    func apply(_ u: Double) -> Double {
        switch self {
        case .linear: u
        case .easeIn: u * u * u
        case .easeOut: 1 - pow(1 - u, 3)
        case .easeInOut: u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        case .hold: 0
        }
    }
}

/// An element's properties at one moment. Every property is optional: a key sets only what it names, and
/// each property tweens between the keys that set it, so moving a box and later recoloring it are separate.
public struct Keyframe: Codable, Equatable, Sendable {
    /// Seconds from the start of the timeline.
    public var t: Double
    public var x, y, width, height: Double?
    /// Radians, as `Element.rotation`.
    public var rotation: Double?
    public var strokeWidth: Double?
    public var stroke, fill: RGBA?
    /// Shown or hidden from this key on; never tweened. Before an element's first `visible` key it has the
    /// opposite value, so a single `visible: true` key is where the element appears.
    public var visible: Bool?
    /// How much of the stroke is drawn, 0...1: tweening it up draws the element on. Also keys connectors.
    public var reveal: Double?
    /// The curve towards the next key; nil is `.linear`.
    public var ease: Ease?

    public init(t: Double, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil,
                rotation: Double? = nil, strokeWidth: Double? = nil, stroke: RGBA? = nil, fill: RGBA? = nil,
                visible: Bool? = nil, reveal: Double? = nil, ease: Ease? = nil) {
        self.t = t; self.x = x; self.y = y; self.width = width; self.height = height
        self.rotation = rotation; self.strokeWidth = strokeWidth; self.stroke = stroke; self.fill = fill
        self.visible = visible; self.reveal = reveal; self.ease = ease
    }
}

/// The keyframes of one element, in time order.
public struct Track: Codable, Equatable, Sendable {
    public var element: UUID
    public var keys: [Keyframe]
    /// Overrides the timeline's boil for this element: true keeps it boiling even while still (a "live"
    /// light), false never boils it, nil follows `Timeline.settle`. A track may exist only to carry this.
    public var boil: Bool?
    /// Spans of time when the element travels along a path instead of following its x and y keys.
    public var follow: [Follow]?
    public init(element: UUID, keys: [Keyframe], boil: Bool? = nil, follow: [Follow]? = nil) {
        self.element = element
        self.keys = keys.sorted { $0.t < $1.t }
        self.boil = boil
        self.follow = follow
    }
}

/// A page's animation. The page's elements are the base pose; tracks override their properties over time.
/// Connectors are never keyed: their endpoints follow the shapes they attach to.
public struct Timeline: Codable, Equatable, Sendable {
    public var fps: Double
    /// Seconds.
    public var duration: Double
    /// Reseed sketchy strokes every `boil` frames, so lines jitter like hand-drawn animation. nil holds them steady.
    public var boil: Int?
    /// Boil a shape only while its keys are changing it, so its lines settle once it holds still. Shapes
    /// without keys stay steady; a connector boils while either shape it attaches to does.
    public var settle: Bool?
    /// The moment a still picture of the page shows (exports, previews, thumbnails); nil is the end.
    public var poster: Double?
    public var tracks: [Track]

    public init(fps: Double = 12, duration: Double, boil: Int? = nil, settle: Bool? = nil,
                tracks: [Track] = []) {
        self.fps = fps; self.duration = duration; self.boil = boil; self.settle = settle; self.tracks = tracks
    }

    public var frameCount: Int { max(1, Int((duration * fps).rounded(.up))) }

    /// The time of frame `i`, for export and playback.
    public func time(ofFrame i: Int) -> Double { Double(i) / fps }

    /// Sets the element's boil override (see `Track.boil`), creating an empty track if needed.
    public mutating func setBoil(_ boil: Bool?, for id: UUID) {
        if let ti = tracks.firstIndex(where: { $0.element == id }) { tracks[ti].boil = boil }
        else { tracks.append(Track(element: id, keys: [], boil: boil)) }
    }

    /// The element's keyframes, or nil if it isn't animated.
    public func track(for id: UUID) -> Track? { tracks.first { $0.element == id } }

    /// Adds or replaces the properties `key` sets at its time, creating the track if needed.
    /// Keys within half a frame of each other are the same key.
    public mutating func setKey(_ key: Keyframe, for id: UUID) {
        guard let ti = tracks.firstIndex(where: { $0.element == id }) else {
            tracks.append(Track(element: id, keys: [key])); return
        }
        var keys = tracks[ti].keys
        if let ki = keys.firstIndex(where: { abs($0.t - key.t) < 0.5 / fps }) {
            keys[ki] = keys[ki].merging(key)
        } else {
            keys.append(key)
        }
        tracks[ti].keys = keys.sorted { $0.t < $1.t }
    }

    // MARK: Editing keys (the timeline editor)

    /// The element's key at `t` (within half a frame), if any.
    public func key(of id: UUID, at t: Double) -> Keyframe? {
        track(for: id)?.keys.first { abs($0.t - t) < 0.5 / fps }
    }

    /// Moves the element's key at `from` to `to` (clamped to 0 and up), merging into a key already there.
    /// With `copy`, the key at `from` stays and a copy lands at `to`. The timeline grows to fit.
    public mutating func moveKey(of id: UUID, from: Double, to: Double, copy: Bool = false) {
        guard var k = key(of: id, at: from), let ti = tracks.firstIndex(where: { $0.element == id }) else { return }
        let to = (max(0, to) * fps).rounded() / fps
        if !copy { tracks[ti].keys.removeAll { abs($0.t - from) < 0.5 / fps } }
        k.t = to
        setKey(k, for: id)
        duration = max(duration, to)
    }

    /// Removes the element's key at `t`; a track left with nothing on it goes too.
    public mutating func removeKey(of id: UUID, at t: Double) {
        guard let ti = tracks.firstIndex(where: { $0.element == id }) else { return }
        tracks[ti].keys.removeAll { abs($0.t - t) < 0.5 / fps }
        if tracks[ti].keys.isEmpty, (tracks[ti].follow ?? []).isEmpty, tracks[ti].boil == nil { tracks.remove(at: ti) }
    }

    /// Sets the curve from the element's key at `t` to the next one.
    public mutating func setEase(_ ease: Ease, of id: UUID, at t: Double) {
        guard let ti = tracks.firstIndex(where: { $0.element == id }),
              let ki = tracks[ti].keys.firstIndex(where: { abs($0.t - t) < 0.5 / fps }) else { return }
        tracks[ti].keys[ki].ease = ease == .linear ? nil : ease
    }
}

extension Keyframe {
    /// `self` with every property `other` sets taken from `other`.
    func merging(_ other: Keyframe) -> Keyframe {
        var k = self
        k.x = other.x ?? x; k.y = other.y ?? y; k.width = other.width ?? width; k.height = other.height ?? height
        k.rotation = other.rotation ?? rotation; k.strokeWidth = other.strokeWidth ?? strokeWidth
        k.stroke = other.stroke ?? stroke; k.fill = other.fill ?? fill
        k.visible = other.visible ?? visible; k.reveal = other.reveal ?? reveal; k.ease = other.ease ?? ease
        return k
    }
}

extension Track {
    /// The value of one property at time `t`: the base value with no key setting it, held flat before the
    /// first such key and after the last, and eased between the two keys around `t`.
    func value<V>(at t: Double, _ prop: (Keyframe) -> V?, base: V, lerp: (V, V, Double) -> V) -> V {
        var before: Keyframe?, after: Keyframe?
        for k in keys where prop(k) != nil {
            if k.t <= t { before = k } else { after = k; break }
        }
        switch (before, after) {
        case (nil, nil): return base
        case let (b?, nil): return prop(b)!
        case let (nil, a?): return prop(a)!
        case let (b?, a?):
            let u = (a.t - b.t) > 0 ? (t - b.t) / (a.t - b.t) : 1
            return lerp(prop(b)!, prop(a)!, (b.ease ?? .linear).apply(u))
        }
    }

    /// Whether some property is tweening at time `t`: between two keys that set it to different values,
    /// and not held.
    func isChanging(at t: Double) -> Bool {
        func changing<V: Equatable>(_ prop: (Keyframe) -> V?) -> Bool {
            guard let b = keys.last(where: { $0.t <= t && prop($0) != nil }),
                  let a = keys.first(where: { $0.t > t && prop($0) != nil }) else { return false }
            return b.ease != .hold && prop(b) != prop(a)
        }
        return changing(\.x) || changing(\.y) || changing(\.width) || changing(\.height)
            || changing(\.rotation) || changing(\.strokeWidth) || changing(\.stroke) || changing(\.fill)
            || changing(\.reveal)
    }

    /// Whether the element is shown at time `t`.
    func isVisible(at t: Double) -> Bool {
        let keyed = keys.filter { $0.visible != nil }
        guard let first = keyed.first else { return true }
        return keyed.last { $0.t <= t }?.visible ?? !first.visible!
    }

    /// `e` posed at time `t`.
    func apply(to e: Element, at t: Double) -> Element {
        func num(_ p: (Keyframe) -> Double?, _ base: Double) -> Double {
            value(at: t, p, base: base) { a, b, u in a + (b - a) * u }
        }
        func color(_ p: (Keyframe) -> RGBA?, _ base: RGBA) -> RGBA {
            value(at: t, p, base: base) { a, b, u in
                RGBA(r: a.r + (b.r - a.r) * u, g: a.g + (b.g - a.g) * u, b: a.b + (b.b - a.b) * u, a: a.a + (b.a - a.a) * u)
            }
        }
        var e = e
        if keys.contains(where: { $0.reveal != nil }) {
            let r = num(\.reveal, e.reveal ?? 1)
            e.reveal = r >= 1 ? nil : max(0, r)
        }
        // A connector's geometry comes from its shapes; only its drawing-on is keyed.
        if e.kind == .connector { return e }
        e.x = num(\.x, e.x); e.y = num(\.y, e.y)
        e.width = num(\.width, e.width); e.height = num(\.height, e.height)
        if keys.contains(where: { $0.rotation != nil }) { e.rotation = num(\.rotation, e.angle) }
        e.style.strokeWidth = num(\.strokeWidth, e.style.strokeWidth)
        e.style.stroke = color(\.stroke, e.style.stroke)
        e.style.fill = color(\.fill, e.style.fill)
        return e
    }
}

extension DottieDocument {
    /// The page as a still drawing at time `t` seconds. Every renderer and exporter draws the result
    /// unchanged; a page without a timeline is returned as is.
    public func resolved(at t: Double) -> DottieDocument {
        guard let timeline else { return self }
        var copy = self
        copy.timeline = nil   // a frame is a still; resolving it again changes nothing
        let tracks = Dictionary(timeline.tracks.map { ($0.element, $0) }, uniquingKeysWith: { a, _ in a })
        let reseed: UInt32? = timeline.boil.map { n in
            UInt32(truncatingIfNeeded: Int((t * timeline.fps + 1e-9).rounded(.down)) / max(1, n))
        }
        let hidden = Set(tracks.values.filter { !$0.isVisible(at: t) }.map(\.element))
        let moving: Set<UUID>? = timeline.settle == true
            ? Set(tracks.values.filter { $0.isChanging(at: t) }.map(\.element)) : nil
        func boils(_ e: Element) -> Bool {
            if let override = tracks[e.id]?.boil { return override }
            guard let moving else { return true }
            if let c = e.connector { return [c.start.elementID, c.end.elementID].contains { $0.map(moving.contains) ?? false } }
            return moving.contains(e.id)
        }
        for i in copy.elements.indices {
            let e = copy.elements[i]
            if let track = tracks[e.id] { copy.elements[i] = track.apply(to: e, at: t) }
            if let reseed, reseed > 0, boils(e) { copy.elements[i].seed = Self.boiled(e.seed, reseed) }
        }
        // A hidden shape waits at its resting place, not at the start of the entrance it is about to make,
        // so arrows and paths leading to it already end where it will appear.
        for i in copy.elements.indices where hidden.contains(copy.elements[i].id) { copy.elements[i] = elements[i] }
        // Paths are traced where their shapes are posed at `t`, so follows go after every key is applied.
        let posed = copy
        for i in copy.elements.indices {
            if let track = tracks[copy.elements[i].id] { copy.elements[i] = track.following(copy.elements[i], at: t, in: posed) }
        }
        // A connector goes with either shape it is attached to, unless it has visible keys of its own. Then
        // both its ends are pinned where they are now, so it draws the same route without the hidden shape.
        let index = copy.elementIndex
        var gone = hidden
        for i in copy.elements.indices {
            guard let c = copy.elements[i].connector,
                  [c.start.elementID, c.end.elementID].contains(where: { $0.map(hidden.contains) ?? false }) else { continue }
            guard tracks[copy.elements[i].id]?.keys.contains(where: { $0.visible != nil }) == true else {
                gone.insert(copy.elements[i].id); continue
            }
            let (a, b) = Connector.endpoints(of: copy.elements[i], in: copy, index: index)
            copy.elements[i].connector!.start = Endpoint(elementID: nil, port: c.start.port, x: a.x, y: a.y)
            copy.elements[i].connector!.end = Endpoint(elementID: nil, port: c.end.port, x: b.x, y: b.y)
        }
        copy.elements.removeAll { gone.contains($0.id) }
        return copy
    }

    /// Elements that only exist in motion: hidden at the start and in the still (packets, mostly). The
    /// editor leaves them out of the page it edits, since its base pose would draw them where they never are.
    public var transientElements: Set<UUID> {
        guard let timeline else { return [] }
        let end = timeline.poster ?? timeline.duration
        return Set(timeline.tracks.filter { !$0.isVisible(at: 0) && !$0.isVisible(at: end) }.map(\.element))
    }

    /// The page as a still picture: its poster frame when it is animated, the end unless set otherwise.
    /// The editor works on the page itself; exports, previews and thumbnails show this.
    public var still: DottieDocument {
        guard let timeline else { return self }
        return resolved(at: timeline.poster ?? timeline.duration)
    }

    /// A different but repeatable seed for each boil step, never 0.
    static func boiled(_ seed: UInt32, _ step: UInt32) -> UInt32 {
        var z = UInt64(seed) &+ UInt64(step) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return max(1, UInt32(truncatingIfNeeded: z ^ (z >> 31)))
    }
}
