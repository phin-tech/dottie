import Foundation

/// What a timeline editor shows for one page: a row per animated element, grouped by layer, each with its
/// keyframes and the spans between them. Pure data, so the view only draws it.
public struct TimelineRows: Equatable, Sendable {
    public struct Group: Equatable, Sendable, Identifiable {
        public var id: UUID { layer }
        public var layer: UUID
        public var name: String
        public var rows: [Row]
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: UUID { element }
        public var element: UUID
        public var label: String
        public var kind: ElementKind
        public var keys: [Mark]
        public var spans: [Span]
    }

    /// A keyframe, and which kinds of property it sets.
    public struct Mark: Equatable, Sendable {
        public var t: Double
        public var sets: Set<Property>
        public var ease: Ease
    }

    public enum Property: String, Sendable, CaseIterable {
        case position, size, rotation, color, stroke, visibility, reveal
    }

    public struct Span: Equatable, Sendable {
        public var start, end: Double
        public var kind: Kind
        public enum Kind: Equatable, Sendable {
            /// Something is tweening between two keys.
            case tween
            /// A key is held until the next one (ease `.hold`).
            case hold
            /// Travelling along a path (a connector, or another element's outline).
            case follow(path: UUID)
            /// The element is not shown.
            case hidden
        }
    }

    public var duration: Double
    public var fps: Double
    public var groups: [Group]

    public init(_ doc: DottieDocument) {
        let timeline = doc.timeline ?? Timeline(duration: 0)
        duration = timeline.duration
        fps = timeline.fps
        let tracks = Dictionary(timeline.tracks.map { ($0.element, $0) }, uniquingKeysWith: { a, _ in a })
        let index = doc.elementIndex
        groups = doc.layers.compactMap { layer in
            let rows = doc.orderedElements.reversed()   // front to back, as layer lists read
                .filter { $0.layerID == layer.id }
                .compactMap { e -> Row? in
                    guard let track = tracks[e.id], !track.keys.isEmpty || !(track.follow ?? []).isEmpty else { return nil }
                    return Row(element: e.id, label: Self.label(e, track: track, index: index), kind: e.kind,
                               keys: track.keys.map(Self.mark), spans: Self.spans(track, duration: timeline.duration))
                }
            return rows.isEmpty ? nil : Group(layer: layer.id, name: layer.name, rows: rows)
        }
    }

    public static func mark(_ k: Keyframe) -> Mark {
        var sets: Set<Property> = []
        if k.x != nil || k.y != nil { sets.insert(.position) }
        if k.width != nil || k.height != nil { sets.insert(.size) }
        if k.rotation != nil { sets.insert(.rotation) }
        if k.fill != nil || k.stroke != nil { sets.insert(.color) }
        if k.strokeWidth != nil { sets.insert(.stroke) }
        if k.visible != nil { sets.insert(.visibility) }
        if k.reveal != nil { sets.insert(.reveal) }
        return Mark(t: k.t, sets: sets, ease: k.ease ?? .linear)
    }

    static func spans(_ track: Track, duration: Double) -> [Span] {
        var out: [Span] = []
        // Hidden stretches, from the visibility keys.
        let vis = track.keys.filter { $0.visible != nil }
        if let first = vis.first {
            var hiddenFrom: Double? = first.visible! ? 0 : nil
            for k in vis {
                if k.visible!, let from = hiddenFrom { if k.t > from { out.append(Span(start: from, end: k.t, kind: .hidden)) }; hiddenFrom = nil }
                else if !k.visible!, hiddenFrom == nil { hiddenFrom = k.t }
            }
            if let from = hiddenFrom, duration > from { out.append(Span(start: from, end: duration, kind: .hidden)) }
        }
        // Between consecutive keys: a tween where something changes, a hold where the ease says so.
        let times = Array(Set(track.keys.map(\.t))).sorted()
        for (a, b) in zip(times, times.dropFirst()) {
            let mid = (a + b) / 2
            if track.isChanging(at: mid) { out.append(Span(start: a, end: b, kind: .tween)) }
            else if track.keys.contains(where: { $0.t == a && $0.ease == .hold }) { out.append(Span(start: a, end: b, kind: .hold)) }
        }
        for f in track.follow ?? [] { out.append(Span(start: f.start, end: f.end, kind: .follow(path: f.path))) }
        return out
    }

    /// A short name for an element: its text, its anchor, what it connects, or what it travels along.
    static func label(_ e: Element, track: Track, index: [UUID: Element]) -> String {
        func name(_ id: UUID?) -> String {
            guard let id, let other = index[id] else { return "?" }
            if let t = other.text?.split(separator: "\n").first, !t.isEmpty { return String(t) }
            if let a = other.anchor, !a.isEmpty { return a }
            return other.kind.rawValue.capitalized
        }
        if let t = e.text?.split(separator: "\n").first, !t.isEmpty { return String(t) }
        if let a = e.anchor, !a.isEmpty { return a }
        if let c = e.connector { return "\(name(c.start.elementID)) → \(name(c.end.elementID))" }
        if let f = track.follow?.first, let path = index[f.path], let c = path.connector {
            return "Packet · \(name(c.start.elementID)) → \(name(c.end.elementID))"
        }
        if let f = track.follow?.first { return "\(e.kind.rawValue.capitalized) along \(name(f.path))" }
        return e.kind.rawValue.capitalized
    }
}
