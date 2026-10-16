import Foundation
import CoreGraphics

/// A canned bit of motion that writes ordinary keyframes, so it can be adjusted key by key afterwards.
public enum Transition: String, Codable, Sendable, CaseIterable {
    // Entrances: the element is hidden until the transition starts and ends in its resting pose.
    /// Grows from small past full size, then settles.
    case popIn
    /// Grows from nothing about its center.
    case growIn
    /// Grows rightwards from its left edge.
    case wipeIn
    /// Falls from above and bounces to a stop.
    case dropIn
    /// Slides in from the left.
    case slideIn
    /// Its outline is sketched on, then it fills in; a connector draws from its start to its arrowhead.
    case drawIn
    /// Fades up from transparent.
    case fadeIn
    // Exits: the element starts in its pose and is hidden once the transition ends.
    /// Swells a little, then shrinks away.
    case popOut
    /// Shrinks to nothing about its center.
    case shrinkOut
    /// Shrinks leftwards into its left edge.
    case wipeOut
    /// Fades away.
    case fadeOut
    // Emphasis: the element starts and ends in its pose.
    /// Swells and settles back.
    case pulse
    /// Rocks side to side.
    case wiggle

    public var defaultDuration: Double {
        switch self {
        case .popIn, .popOut, .shrinkOut: 0.4
        case .dropIn: 0.6
        case .drawIn: 0.8
        default: 0.5
        }
    }

    var isEntrance: Bool { [.popIn, .growIn, .wipeIn, .dropIn, .slideIn, .drawIn, .fadeIn].contains(self) }
    var isExit: Bool { [.popOut, .shrinkOut, .wipeOut, .fadeOut].contains(self) }
    /// Transitions that don't move or resize anything, so they work on connectors too.
    public var appliesToConnectors: Bool { [.drawIn, .fadeIn, .fadeOut].contains(self) }
}

extension DottieDocument {
    /// Adds `transition` to element `id`, starting at `t` seconds, creating the timeline if there is none
    /// and lengthening it to fit. The motion is worked out from the element's pose when the transition
    /// rests: at its end for an entrance, at its start otherwise.
    @discardableResult
    public mutating func addTransition(_ transition: Transition, to id: UUID, at t: Double,
                                       duration: Double? = nil) throws -> (start: Double, end: Double) {
        guard let e = elements.first(where: { $0.id == id }) else { throw OpsError.notFound("No element \(id.uuidString)") }
        guard e.kind != .connector || transition.appliesToConnectors else {
            throw OpsError.invalid("Connectors follow their shapes; only drawIn, fadeIn and fadeOut apply to them")
        }
        let t = Timeline.clampTime(t)
        let d = min(max(0.05, duration ?? transition.defaultDuration), Timeline.maxDuration - t + 0.05)
        var tl = timeline ?? Timeline(duration: t + d)
        tl.duration = max(tl.duration, t + d)
        let restT = transition.isEntrance ? t + d : t
        let f = (tl.track(for: id)?.apply(to: e, at: restT) ?? e).frame
        let angle = tl.track(for: id)?.apply(to: e, at: restT).rotation ?? e.rotation ?? 0
        let restOpacity = (tl.track(for: id)?.apply(to: e, at: restT) ?? e).style.opacity ?? 1

        func scaled(_ at: Double, _ s: Double, _ ease: Ease? = nil, visible: Bool? = nil) -> Keyframe {
            Keyframe(t: at, x: f.midX - f.width * s / 2, y: f.midY - f.height * s / 2,
                     width: f.width * s, height: f.height * s, visible: visible, ease: ease)
        }
        func wiped(_ at: Double, _ s: Double, _ ease: Ease? = nil, visible: Bool? = nil) -> Keyframe {
            Keyframe(t: at, x: f.minX, width: max(1, f.width * s), visible: visible, ease: ease)
        }
        func at(_ at: Double, x: Double? = nil, y: Double? = nil, _ ease: Ease? = nil, visible: Bool? = nil) -> Keyframe {
            Keyframe(t: at, x: x, y: y, visible: visible, ease: ease)
        }
        func turned(_ at: Double, _ r: Double) -> Keyframe {
            Keyframe(t: at, rotation: angle + r, ease: .easeInOut)
        }

        let keys: [Keyframe]
        switch transition {
        case .popIn:
            keys = [scaled(t, 0.2, .easeOut, visible: true), scaled(t + 0.6 * d, 1.15, .easeInOut), scaled(t + d, 1)]
        case .growIn:
            keys = [scaled(t, 0.02, .easeOut, visible: true), scaled(t + d, 1)]
        case .wipeIn:
            keys = [wiped(t, 0, .easeOut, visible: true), wiped(t + d, 1)]
        case .dropIn:
            let land = f.minY, lift = max(80, f.height * 2)
            keys = [at(t, y: land - lift, .bounce, visible: true), at(t + d, y: land)]
        case .slideIn:
            keys = [at(t, x: f.minX - max(120, f.width), .easeOut, visible: true), at(t + d, x: f.minX)]
        case .drawIn:
            keys = [Keyframe(t: t, visible: true, reveal: 0, ease: .easeInOut), Keyframe(t: t + d, reveal: 1)]
        case .fadeIn:
            keys = [Keyframe(t: t, visible: true, opacity: 0, ease: .easeOut), Keyframe(t: t + d, opacity: restOpacity)]
        case .fadeOut:
            keys = [Keyframe(t: t, opacity: restOpacity, ease: .easeIn), Keyframe(t: t + d, visible: false, opacity: 0)]
        case .popOut:
            keys = [scaled(t, 1, .easeOut), scaled(t + 0.35 * d, 1.15, .easeIn), scaled(t + d, 0.2, visible: false)]
        case .shrinkOut:
            keys = [scaled(t, 1, .easeIn), scaled(t + d, 0.02, visible: false)]
        case .wipeOut:
            keys = [wiped(t, 1, .easeIn), wiped(t + d, 0, visible: false)]
        case .pulse:
            keys = [scaled(t, 1, .easeInOut), scaled(t + d / 2, 1.12, .easeInOut), scaled(t + d, 1)]
        case .wiggle:
            keys = [turned(t, 0), turned(t + d * 0.25, 0.12), turned(t + d * 0.5, -0.12),
                    turned(t + d * 0.75, 0.06), turned(t + d, 0)]
        }
        for k in keys { tl.setKey(k, for: id) }
        timeline = tl
        return (t, t + d)
    }
}
