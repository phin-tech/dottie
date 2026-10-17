import Foundation

/// The curve from one keyframe to the next. Each is a pure function of the fraction of the way between the
/// keys, 0 at the first and exactly 1 at the second; spring and elastic pass 1 on the way, overshooting the
/// next key's value and settling back onto it.
public enum Ease: String, Codable, Sendable, CaseIterable {
    case linear, easeIn, easeOut, easeInOut
    /// Keep this key's value until the next key, then jump (a Flash "keyframe without a tween").
    case hold
    /// Starts gently, overshoots and settles, like a weight on a spring.
    case spring
    /// Lands and bounces a few times, each lower, like a dropped ball.
    case bounce
    /// Snaps there and wobbles about it, like a plucked rubber band.
    case elastic

    /// A name this version doesn't know (written by a newer Dottie) plays linear rather than failing the file.
    public init(from decoder: Decoder) throws {
        self = Ease(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .linear
    }

    func apply(_ u: Double) -> Double {
        switch self {
        case .linear: u
        case .easeIn: u * u * u
        case .easeOut: 1 - pow(1 - u, 3)
        case .easeInOut: u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        case .hold: 0
        case .spring: Self.spring(u)
        case .bounce: Self.bounce(u)
        case .elastic: Self.elastic(u)
        }
    }

    /// A damped spring released from rest, nudged so it is exactly 1 at the end.
    static func spring(_ u: Double) -> Double {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        func s(_ u: Double) -> Double { 1 - exp(-6 * u) * (cos(3 * .pi * u) + 6 / (3 * .pi) * sin(3 * .pi * u)) }
        return s(u) + u * (1 - s(1))
    }

    /// Robert Penner's ease-out bounce: four arcs, each landing on 1.
    static func bounce(_ u: Double) -> Double {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        let n = 7.5625, d = 2.75
        if u < 1 / d { return n * u * u }
        if u < 2 / d { let v = u - 1.5 / d; return n * v * v + 0.75 }
        if u < 2.5 / d { let v = u - 2.25 / d; return n * v * v + 0.9375 }
        let v = u - 2.625 / d
        return n * v * v + 0.984375
    }

    /// Robert Penner's ease-out elastic.
    static func elastic(_ u: Double) -> Double {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        return pow(2, -10 * u) * sin((u * 10 - 0.75) * (2 * .pi / 3)) + 1
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
    /// How opaque the element is, 0...1 (`Style.opacity`). Also keys connectors.
    public var opacity: Double?
    /// The curve towards the next key; nil is `.linear`.
    public var ease: Ease?

    public init(t: Double, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil,
                rotation: Double? = nil, strokeWidth: Double? = nil, stroke: RGBA? = nil, fill: RGBA? = nil,
                visible: Bool? = nil, reveal: Double? = nil, opacity: Double? = nil, ease: Ease? = nil) {
        self.t = t; self.x = x; self.y = y; self.width = width; self.height = height
        self.rotation = rotation; self.strokeWidth = strokeWidth; self.stroke = stroke; self.fill = fill
        self.visible = visible; self.reveal = reveal; self.opacity = opacity; self.ease = ease
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
    /// Spans of the keys that play again (a pulse that never stops, a wiggle three times).
    public var repeats: [Repeat]?
    /// Marching ants: the element's dashes travel along its line at this many points per second, from its
    /// start towards its end (backwards when negative), for the whole timeline. Only a dashed or dotted line
    /// shows it. The speed is evened out so the dashes come round to where they started as the timeline loops.
    public var march: Double?
    public init(element: UUID, keys: [Keyframe], boil: Bool? = nil, follow: [Follow]? = nil, repeats: [Repeat]? = nil,
                march: Double? = nil) {
        self.element = element
        self.keys = keys.sorted { $0.t < $1.t }
        self.boil = boil
        self.follow = follow
        self.repeats = repeats
        self.march = march.flatMap(Self.clampMarch)
    }

    /// The fastest march, points per second.
    public static let maxMarch = 10_000.0
    static func clampMarch(_ v: Double) -> Double? {
        guard v.isFinite, v != 0 else { return nil }
        return min(max(v, -maxMarch), maxMarch)
    }

    private enum CodingKeys: String, CodingKey { case element, keys, boil, follow, repeats, march }

    /// Hand- or agent-written files may list keys out of order or with impossible times: keep the usable
    /// keys, in time order, so interpolation (which walks them in order) stays right.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        element = try c.decode(UUID.self, forKey: .element)
        keys = (try c.decodeIfPresent([Keyframe].self, forKey: .keys) ?? [])
            .filter { $0.t.isFinite && $0.t >= 0 && $0.t <= Timeline.maxDuration }
            .sorted { $0.t < $1.t }
        boil = try c.decodeIfPresent(Bool.self, forKey: .boil)
        follow = try c.decodeIfPresent([Follow].self, forKey: .follow)?
            .filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end <= Timeline.maxDuration }
        repeats = try c.decodeIfPresent([Repeat].self, forKey: .repeats)?.filter(\.isValid)
        march = try c.decodeIfPresent(Double.self, forKey: .march).flatMap(Self.clampMarch)
    }

    /// The time inside the element's own keys that `t` plays: within a repeat, the same moment of the
    /// repeated span; after a counted repeat ends, the time shifted back by the repeats it played.
    func localTime(_ t: Double) -> Double {
        guard let reps = repeats?.filter(\.isValid).sorted(by: { $0.start < $1.start }), !reps.isEmpty else { return t }
        var t = t
        for r in reps where t >= r.end {
            let length = r.end - r.start
            guard let count = r.count else { return r.start + (t - r.start).truncatingRemainder(dividingBy: length) }
            let played = length * Double(count)
            if t < r.start + played { return r.start + (t - r.start).truncatingRemainder(dividingBy: length) }
            t -= played - length
        }
        return t
    }
}

/// A span of a track's keys that plays again: `count` times in all (nil forever, until the timeline ends).
public struct Repeat: Codable, Equatable, Sendable {
    public var start, end: Double
    public var count: Int?
    public init(start: Double, end: Double, count: Int? = nil) {
        self.start = start; self.end = end; self.count = count
    }
    var isValid: Bool {
        start.isFinite && end.isFinite && start >= 0 && end - start > 1e-3 && end <= Timeline.maxDuration
            && (count.map { $0 >= 1 && $0 <= 10_000 } ?? true)
    }
}

/// The view an export shows at time `t`: a rectangle of the page, eased from this key to the next.
public struct CameraKey: Codable, Equatable, Sendable {
    public var t: Double
    public var x, y, width, height: Double
    public var ease: Ease?
    public init(t: Double, rect: CGRect, ease: Ease? = nil) {
        self.t = t; x = rect.minX; y = rect.minY; width = rect.width; height = rect.height; self.ease = ease
    }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool { [t, x, y, width, height].allSatisfy(\.isFinite) && width > 1 && height > 1 && t >= 0 }
}

/// A named moment: where a click-through presentation stops.
public struct Marker: Codable, Equatable, Sendable {
    public var t: Double
    public var name: String
    public init(t: Double, name: String) { self.t = t; self.name = name }
}

/// A page's animation. The page's elements are the base pose; tracks override their properties over time.
/// Connectors are never keyed: their endpoints follow the shapes they attach to.
public struct Timeline: Codable, Equatable, Sendable {
    /// The longest animation, in seconds. Everything that sets a time clamps to it, so a stray huge number
    /// from a file or a script can't turn into billions of frames.
    public static let maxDuration = 3600.0
    public static let fpsRange = 1.0...60.0
    /// How many drawings a boil cycles through. Three, as hand-drawn animation usually does; repeating them
    /// also lets the HTML player and the movie encoders share what comes round again.
    public static let boilDrawings = 3

    /// Frames per second, kept within `fpsRange`.
    public var fps: Double { didSet { fps = Self.clampFPS(fps) } }
    /// Seconds, kept within 0...`maxDuration`.
    public var duration: Double { didSet { duration = Self.clampTime(duration) } }
    /// Reseed sketchy strokes every `boil` frames, so lines jitter like hand-drawn animation, cycling through
    /// `boilDrawings` versions of each line as a hand-drawn boil loops a few drawings. nil holds them steady.
    public var boil: Int? { didSet { boil = boil.flatMap { $0 > 0 ? min($0, 10_000) : nil } } }
    /// Boil a shape only while its keys are changing it, so its lines settle once it holds still. Shapes
    /// without keys stay steady; a connector boils while either shape it attaches to does.
    public var settle: Bool?
    /// The moment a still picture of the page shows (exports, previews, thumbnails); nil is the end.
    public var poster: Double? { didSet { poster = poster.map(Self.clampTime) } }
    public var tracks: [Track]
    /// Where exports look over time; nil frames the whole animation.
    public var camera: [CameraKey]?
    /// Named scenes; the HTML player stops at each, for click-through presentations.
    public var markers: [Marker]?

    public init(fps: Double = 12, duration: Double, boil: Int? = nil, settle: Bool? = nil,
                tracks: [Track] = []) {
        self.fps = Self.clampFPS(fps); self.duration = Self.clampTime(duration)
        self.boil = boil.flatMap { $0 > 0 ? min($0, 10_000) : nil }
        self.settle = settle; self.tracks = tracks
    }

    /// A time in seconds made safe: finite and within 0...`maxDuration` (NaN is 0).
    public static func clampTime(_ t: Double) -> Double {
        guard t.isFinite else { return t == .infinity ? maxDuration : 0 }
        return min(max(t, 0), maxDuration)
    }

    static func clampFPS(_ f: Double) -> Double {
        f.isFinite ? min(max(f, fpsRange.lowerBound), fpsRange.upperBound) : 12
    }

    private enum CodingKeys: String, CodingKey { case fps, duration, boil, settle, poster, tracks, camera, markers }

    /// Every field is optional on disk, and out-of-range numbers are clamped rather than rejected, so a
    /// hand-written or damaged timeline still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fps: try c.decodeIfPresent(Double.self, forKey: .fps) ?? 12,
                  duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0,
                  boil: try c.decodeIfPresent(Int.self, forKey: .boil),
                  settle: try c.decodeIfPresent(Bool.self, forKey: .settle),
                  tracks: try c.decodeIfPresent([Track].self, forKey: .tracks) ?? [])
        poster = try c.decodeIfPresent(Double.self, forKey: .poster).map(Self.clampTime)
        camera = try c.decodeIfPresent([CameraKey].self, forKey: .camera)?.filter(\.isValid).sorted { $0.t < $1.t }
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers)?
            .filter { $0.t.isFinite && $0.t >= 0 }.sorted { $0.t < $1.t }
    }

    /// The camera's view at `t`, or nil when there's no camera.
    public func cameraRect(at t: Double) -> CGRect? {
        guard let keys = camera?.filter(\.isValid), let first = keys.first else { return nil }
        let before = keys.last { $0.t <= t }, after = keys.first { $0.t > t }
        guard let b = before else { return first.rect }
        guard let a = after else { return b.rect }
        let u = (b.ease ?? .easeInOut).apply((t - b.t) / max(a.t - b.t, 1e-9))
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * u }
        // A springy ease can overshoot a zoom past nothing.
        return CGRect(x: mix(b.x, a.x), y: mix(b.y, a.y), width: max(1, mix(b.width, a.width)), height: max(1, mix(b.height, a.height)))
    }

    /// What exports show at `t`: the camera's view widened (never cropped) to the first key's shape, so
    /// the output keeps one size as the camera moves. nil when there's no camera.
    public func cameraView(at t: Double) -> CGRect? {
        guard let first = camera?.first(where: \.isValid), let r = cameraRect(at: t), r.width > 0, r.height > 0 else { return nil }
        let aspect = first.width / first.height
        var out = r
        if r.width / r.height < aspect { out.size.width = r.height * aspect } else { out.size.height = r.width / aspect }
        out.origin = CGPoint(x: r.midX - out.width / 2, y: r.midY - out.height / 2)
        return out
    }

    /// Adds or replaces the camera key at `t` (to a microsecond), growing the timeline to fit.
    public mutating func setCamera(_ key: CameraKey) {
        var key = key
        key.t = Self.clampTime(key.t)
        guard key.isValid else { return }
        var keys = (camera ?? []).filter { abs($0.t - key.t) >= 1e-6 }
        keys.append(key)
        camera = keys.sorted { $0.t < $1.t }
        duration = max(duration, key.t)
    }

    /// Adds a scene marker (replacing one at the same time), growing the timeline to fit.
    public mutating func addMarker(at t: Double, name: String) {
        let t = Self.clampTime(t)
        var list = (markers ?? []).filter { abs($0.t - t) >= 1e-6 }
        list.append(Marker(t: t, name: name))
        markers = list.sorted { $0.t < $1.t }
        duration = max(duration, t)
    }

    /// Adds a scene called `nextSceneName` at `t`, unless one is there already (replacing it would rename it out
    /// from under the clicks that play it). Returns whether it added one.
    @discardableResult
    public mutating func addScene(at t: Double) -> Bool {
        let t = Self.clampTime(t)
        guard !(markers ?? []).contains(where: { abs($0.t - t) < 1e-6 }) else { return false }
        addMarker(at: t, name: nextSceneName)
        return true
    }

    /// Removes the scene marker at `t`, if there is one.
    public mutating func removeMarker(at t: Double) {
        markers = markers?.filter { abs($0.t - t) >= 1e-6 }
        if markers?.isEmpty == true { markers = nil }
    }

    /// "Scene N" for the first N no marker is called yet, so a deleted scene's name isn't handed out twice.
    public var nextSceneName: String {
        let names = Set((markers ?? []).map { $0.name.lowercased() })
        var n = (markers?.count ?? 0) + 1
        while names.contains("scene \(n)") { n += 1 }
        return "Scene \(n)"
    }

    /// Makes the element's keys from `start` to `end` play again, `count` times in all (nil forever).
    public mutating func addRepeat(for id: UUID, from start: Double, to end: Double, count: Int? = nil) {
        let r = Repeat(start: Self.clampTime(start), end: Self.clampTime(end), count: count.map { min(max($0, 1), 10_000) })
        guard r.isValid else { return }
        if let ti = tracks.firstIndex(where: { $0.element == id }) {
            tracks[ti].repeats = (tracks[ti].repeats ?? []).filter { $0.start != r.start } + [r]
        } else {
            tracks.append(Track(element: id, keys: [], repeats: [r]))
        }
        if let n = r.count { duration = max(duration, Self.clampTime(r.start + (r.end - r.start) * Double(n))) }
    }

    public var frameCount: Int { max(1, Int((Self.clampTime(duration) * Self.clampFPS(fps)).rounded(.up))) }

    /// The time of frame `i`, for export and playback.
    public func time(ofFrame i: Int) -> Double { Double(i) / Self.clampFPS(fps) }

    /// The times exports and playback draw: every frame, plus the end itself when it falls between frames,
    /// so a loop reaches the rest pose the still shows.
    public var frameTimes: [Double] {
        var times = (0..<frameCount).map(time(ofFrame:))
        if let last = times.last, duration - last > 1e-6 { times.append(duration) }
        return times
    }

    /// Sets the element's boil override (see `Track.boil`), creating an empty track if needed.
    public mutating func setBoil(_ boil: Bool?, for id: UUID) {
        if let ti = tracks.firstIndex(where: { $0.element == id }) { tracks[ti].boil = boil }
        else { tracks.append(Track(element: id, keys: [], boil: boil)) }
    }

    /// Sets how fast the element's dashes march (see `Track.march`; nil or 0 stops them), creating an empty
    /// track if needed.
    public mutating func setMarch(_ speed: Double?, for id: UUID) {
        let speed = speed.flatMap(Track.clampMarch)
        if let ti = tracks.firstIndex(where: { $0.element == id }) {
            tracks[ti].march = speed
            let t = tracks[ti]
            if speed == nil, t.keys.isEmpty, (t.follow ?? []).isEmpty, (t.repeats ?? []).isEmpty, t.boil == nil { tracks.remove(at: ti) }
        } else if speed != nil {
            tracks.append(Track(element: id, keys: [], march: speed))
        }
    }

    /// Where the dashes of a line marching at `speed` stand at `t`: the dash phase, within one pattern
    /// `period`. The speed is rounded to a whole number of patterns over the timeline, so a loop is seamless.
    func marchOffset(speed: Double, period: Double, at t: Double) -> Double {
        guard period > 0 else { return 0 }
        var speed = speed
        let d = Self.clampTime(duration)
        if d > 0 {
            let laps = (speed * d / period).rounded()
            if laps != 0 { speed = laps * period / d }
        }
        let r = (speed * t).truncatingRemainder(dividingBy: period)
        // Positive phase pulls the pattern back towards the start, so going forward is a falling phase.
        return r < 0 ? -r : r == 0 ? 0 : period - r
    }

    /// The element's keyframes, or nil if it isn't animated.
    public func track(for id: UUID) -> Track? { tracks.first { $0.element == id } }

    /// Adds or replaces the properties `key` sets at its time, creating the track if needed. Only a key at
    /// the same time (to a microsecond) is merged into, so a transition's closely spaced keys stay distinct
    /// at any frame rate.
    public mutating func setKey(_ key: Keyframe, for id: UUID) {
        var key = key
        key.t = Self.clampTime(key.t)
        guard let ti = tracks.firstIndex(where: { $0.element == id }) else {
            tracks.append(Track(element: id, keys: [key])); return
        }
        var keys = tracks[ti].keys
        if let ki = keys.firstIndex(where: { abs($0.t - key.t) < 1e-6 }) {
            keys[ki] = keys[ki].merging(key)
        } else {
            keys.append(key)
        }
        tracks[ti].keys = keys.sorted { $0.t < $1.t }
    }

    // MARK: Editing keys (the timeline editor)

    /// Where the element's key nearest `t` is, if one lies within half a frame: one key, never several.
    private func keyIndex(of id: UUID, at t: Double) -> (track: Int, key: Int)? {
        guard let ti = tracks.firstIndex(where: { $0.element == id }) else { return nil }
        let keys = tracks[ti].keys
        guard let ki = keys.indices.min(by: { abs(keys[$0].t - t) < abs(keys[$1].t - t) }),
              abs(keys[ki].t - t) <= 0.5 / Self.clampFPS(fps) else { return nil }
        return (ti, ki)
    }

    /// The element's key at `t` (the nearest within half a frame), if any.
    public func key(of id: UUID, at t: Double) -> Keyframe? {
        keyIndex(of: id, at: t).map { tracks[$0.track].keys[$0.key] }
    }

    /// Moves the element's key at `from` to `to` (snapped to a frame, 0 and up), merging into a key already
    /// exactly there. With `copy`, the key at `from` stays and a copy lands at `to`. The timeline grows to fit.
    public mutating func moveKey(of id: UUID, from: Double, to: Double, copy: Bool = false) {
        guard let (ti, ki) = keyIndex(of: id, at: from) else { return }
        var k = tracks[ti].keys[ki]
        let to = (Self.clampTime(to) * Self.clampFPS(fps)).rounded() / Self.clampFPS(fps)
        if !copy { tracks[ti].keys.remove(at: ki) }
        k.t = to
        setKey(k, for: id)
        duration = max(duration, to)
    }

    /// Removes the element's key at `t`; a track left with nothing on it goes too.
    public mutating func removeKey(of id: UUID, at t: Double) {
        guard let (ti, ki) = keyIndex(of: id, at: t) else { return }
        tracks[ti].keys.remove(at: ki)
        if tracks[ti].keys.isEmpty, (tracks[ti].follow ?? []).isEmpty, tracks[ti].boil == nil, tracks[ti].march == nil {
            tracks.remove(at: ti)
        }
    }

    /// Sets the curve from the element's key at `t` to the next one.
    public mutating func setEase(_ ease: Ease, of id: UUID, at t: Double) {
        guard let (ti, ki) = keyIndex(of: id, at: t) else { return }
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
        k.visible = other.visible ?? visible; k.reveal = other.reveal ?? reveal
        k.opacity = other.opacity ?? opacity; k.ease = other.ease ?? ease
        return k
    }
}

extension Track {
    /// The value of one property at time `t`: the base value with no key setting it, held flat before the
    /// first such key and after the last, and eased between the two keys around `t`.
    func value<V>(at t: Double, _ prop: (Keyframe) -> V?, base: V, lerp: (V, V, Double) -> V) -> V {
        let t = localTime(t)
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
        let t = localTime(t)
        func changing<V: Equatable>(_ prop: (Keyframe) -> V?) -> Bool {
            guard let b = keys.last(where: { $0.t <= t && prop($0) != nil }),
                  let a = keys.first(where: { $0.t > t && prop($0) != nil }) else { return false }
            return b.ease != .hold && prop(b) != prop(a)
        }
        return changing(\.x) || changing(\.y) || changing(\.width) || changing(\.height)
            || changing(\.rotation) || changing(\.strokeWidth) || changing(\.stroke) || changing(\.fill)
            || changing(\.reveal) || changing(\.opacity)
    }

    /// Whether the element is shown at time `t`.
    func isVisible(at t: Double) -> Bool {
        let t = localTime(t)
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
            // Springy eases overshoot: a color can't go past white or black.
            value(at: t, p, base: base) { a, b, u in
                func mix(_ p: Double, _ q: Double) -> Double { min(max(p + (q - p) * u, 0), 1) }
                return RGBA(r: mix(a.r, b.r), g: mix(a.g, b.g), b: mix(a.b, b.b), a: mix(a.a, b.a))
            }
        }
        var e = e
        if keys.contains(where: { $0.reveal != nil }) {
            let r = num(\.reveal, e.reveal ?? 1)
            e.reveal = r >= 1 ? nil : max(0, r)
        }
        if keys.contains(where: { $0.opacity != nil }) {
            let o = min(max(num(\.opacity, e.style.opacity ?? 1), 0), 1)
            e.style.opacity = o >= 1 ? nil : o
        }
        // A connector's geometry comes from its shapes; only its drawing-on and opacity are keyed.
        if e.kind == .connector { return e }
        e.x = num(\.x, e.x); e.y = num(\.y, e.y)
        // Nor can a size or a line width go below nothing.
        e.width = max(0, num(\.width, e.width)); e.height = max(0, num(\.height, e.height))
        if keys.contains(where: { $0.rotation != nil }) { e.rotation = num(\.rotation, e.angle) }
        e.style.strokeWidth = max(0, num(\.strokeWidth, e.style.strokeWidth))
        e.style.stroke = color(\.stroke, e.style.stroke)
        e.style.fill = color(\.fill, e.style.fill)
        return e
    }
}

extension DottieDocument {
    /// The page as a still drawing at time `t` seconds, with every symbol instance expanded into what it shows
    /// then (see `expandingSymbols(at:)`). Every renderer and exporter draws the result unchanged; a page with
    /// no timeline and no instances is returned as is.
    public func resolved(at t: Double) -> DottieDocument {
        posed(at: t).expandingSymbols(at: Timeline.clampTime(t))
    }

    /// The page posed at time `t` seconds: its keys applied, symbol instances kept as instances. What the editor
    /// shows and edits while stopped on the timeline; a page without a timeline is returned as is.
    public func posed(at t: Double) -> DottieDocument {
        guard let timeline else { return self }
        let t = Timeline.clampTime(t)
        var copy = self
        copy.timeline = nil   // a frame is a still; resolving it again changes nothing
        let tracks = Dictionary(timeline.tracks.map { ($0.element, $0) }, uniquingKeysWith: { a, _ in a })
        let reseed: UInt32? = timeline.boil.map { n in
            // t and fps are both clamped, so this frame number is always a small finite integer.
            UInt32(truncatingIfNeeded: (Int((t * Timeline.clampFPS(timeline.fps) + 1e-9).rounded(.down)) / max(1, n)) % Timeline.boilDrawings)
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
            if let speed = tracks[e.id]?.march, let pattern = Renderer.dashPattern(copy.elements[i].style.dash, width: copy.elements[i].style.strokeWidth) {
                copy.elements[i].style.dashOffset = timeline.marchOffset(speed: speed, period: pattern.reduce(0, +), at: t)
            }
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
        guard let timeline else { return expandingSymbols(at: 0) }
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
