import Foundation

/// Playing a page as `<dottie-player>` would, with no browser: clicks, waits and the moment they reach, so an agent
/// (the MCP `simulate` tool, `dottie simulate`) can check that an interactive page does what it was built to.
///
/// It follows the web player's rules (web/src/player.ts, `Playback.step`, `DottiePlayer.activate`, `nextScene`):
/// playing steps whole frames of the timeline; it stops on reaching a scene, and at the end when the page has scenes
/// (otherwise it goes round); a looping scene plays round from its end to its start. A click sets and flips its
/// variables, then jumps to its scene and plays on. Links and other pages are reported, not followed; a symbol copy
/// that replays when clicked isn't played.
public struct Simulation: Sendable {
    public let doc: DottieDocument
    /// The times of the frames playing steps through (`Timeline.frameTimes`); one frame, 0, without a timeline.
    let times: [Double]
    /// Each scene's first frame, its name, and whether it loops, in marker order.
    let scenes: [Int]
    let sceneNames: [String]
    let sceneLoops: [Bool]
    /// The frame drawn now.
    public private(set) var frame: Int
    /// Whether the page is playing.
    public private(set) var playing: Bool
    /// The page's variables now.
    public private(set) var state: [String: Var]
    /// Seconds played since the variables last changed: how long backlog has been piling up.
    public private(set) var sinceChange = 0.0
    /// What each queue held when the variables last changed, which it drains from (`FrameMetrics.carry`).
    public private(set) var carried: [String: Double] = [:]
    /// Every frame shown since `record()`, for a video of the run (`Exporter.gif(_:)`, `mp4(_:)`); nil when not recording.
    public private(set) var recording: Recording?

    /// Starts as the player does: at the start, playing unless the first scene is there and doesn't loop. With
    /// `scene`, at that scene, playing on from it.
    public init(_ doc: DottieDocument, scene: String? = nil) throws {
        self.doc = doc
        let tl = doc.timeline
        times = tl?.frameTimes ?? [0]
        let markers = tl?.markers ?? []
        let times = self.times
        func nearest(_ t: Double) -> Int {
            times.indices.min { abs(times[$0] - t) < abs(times[$1] - t) } ?? 0
        }
        scenes = markers.map { nearest($0.t) }
        sceneNames = markers.map(\.name)
        sceneLoops = markers.map { $0.loop == true }
        state = doc.variables ?? [:]
        frame = 0
        playing = false
        if let scene {
            guard let i = DottieDocument.scene(named: scene, in: markers) else {
                throw OpsError.invalid("No scene '\(scene)' (scenes: \(sceneNames.isEmpty ? "none" : sceneNames.joined(separator: ", ")))")
            }
            frame = scenes[i]
            setPlaying(true)
        } else {
            setPlaying(!scenes.contains(0) || sceneLoops[scenes.firstIndex(of: 0)!])
        }
    }

    var frameCount: Int { times.count }
    /// The moment drawn now, in seconds.
    public var time: Double { times[frame] }

    private mutating func setPlaying(_ on: Bool) {
        playing = on && frameCount > 1 && doc.timeline != nil
    }

    /// The scene frame `i` is in, or -1 before the first.
    func sceneAt(_ i: Int) -> Int {
        var s = -1
        for (j, f) in scenes.enumerated() where f <= i { s = j }
        return s
    }

    /// The name of the scene playing now, if any.
    public var scene: String? {
        let s = sceneAt(frame)
        return s >= 0 ? sceneNames[s] : nil
    }

    /// The frame after scene `s`'s last.
    func sceneEnd(_ s: Int) -> Int {
        scenes.enumerated().first { $0.offset > s && $0.element > scenes[s] }?.element ?? frameCount
    }

    /// `Playback.step` with the timeline looping at its end, as `<dottie-player>` does by default.
    func step(_ i: Int) -> (frame: Int, stop: Bool) {
        let next = i + 1
        let s = sceneAt(i)
        if s >= 0, sceneLoops[s], next >= sceneEnd(s) { return (scenes[s], false) }
        if next >= frameCount { return (0, !scenes.isEmpty) }
        if let entered = scenes.firstIndex(of: next) { return (next, !sceneLoops[entered]) }
        return (next, false)
    }

    /// Starts recording: from now on, every frame shown is kept, this one first (`recording`).
    public mutating func record() {
        recording = Recording(doc: doc, fps: Timeline.clampFPS(doc.timeline?.fps ?? Recording.stillFPS), frames: [])
        recording!.frames.append(snapshot)
    }

    /// The moment drawn now, as a recording keeps it.
    var snapshot: Recording.Frame { Recording.Frame(time: time, state: state, since: sinceChange, carried: carried) }

    /// Plays for `seconds` (whole frames at the timeline's rate), as the player's tick does. While recording, each
    /// frame shown is kept, played or held.
    public mutating func wait(_ seconds: Double) {
        guard var r = recording, seconds > 0 else { play(seconds); return }
        recording = nil
        let frames = Int((seconds * r.fps + 1e-9).rounded(.down))
        for _ in 0..<min(frames, Exporter.maxAnimationFrames) {
            play(1 / r.fps)
            r.frames.append(snapshot)
        }
        play(seconds - Double(frames) / r.fps)
        recording = r
    }

    private mutating func play(_ seconds: Double) {
        guard let tl = doc.timeline, seconds > 0 else { return }
        if playing { sinceChange += seconds }
        var steps = Int((seconds * Timeline.clampFPS(tl.fps) + 1e-9).rounded(.down))
        while playing, steps > 0 {
            steps -= 1
            let (next, stop) = step(frame)
            if stop, next == 0, frame + 1 >= frameCount { playing = false; break }
            frame = next
            if stop { playing = false }
        }
    }

    /// Plays on to the next scene, as the Next button does.
    public mutating func nextScene() {
        let s = sceneAt(frame)
        if s >= 0, sceneLoops[s] { frame = s + 1 < scenes.count ? scenes[s + 1] : 0 }
        else if frame >= frameCount - 1 { frame = 0 }
        setPlaying(true)
    }

    /// The element `target` names: its id (or the start of one), else its text or anchor, exactly and then in any
    /// case. Text is matched as it shows now, an override's included. Several matches are an error that lists them.
    public func element(_ target: String) throws -> Element {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: t), let e = doc.elements.first(where: { $0.id == id }) { return e }
        let byID = doc.elements.filter { t.count >= 4 && $0.id.uuidString.lowercased().hasPrefix(t.lowercased()) }
        if byID.count == 1 { return byID[0] }
        let values = doc.stateValues(.values(state))
        func shown(_ e: Element) -> String? { e.activeOverrides(values).compactMap(\.text).last ?? e.text }
        func named(_ same: (String) -> Bool) -> [Element] {
            doc.elements.filter { e in [shown(e), e.text, e.anchor].contains { $0.map(same) ?? false } }
        }
        var found = named { $0 == t }
        if found.isEmpty { found = named { $0.caseInsensitiveCompare(t) == .orderedSame } }
        if found.count > 1, case let clickable = found.filter({ $0.click != nil || $0.url != nil }), clickable.count == 1 {
            return clickable[0]
        }
        guard found.count == 1 else {
            if found.isEmpty { throw OpsError.invalid("No element '\(target)' on the page") }
            throw OpsError.invalid("'\(target)' names \(found.count) elements; use an id: "
                                   + found.map { $0.id.uuidString }.joined(separator: ", "))
        }
        return found[0]
    }

    /// Clicks `target` (see `element`): returns what the click did, in words.
    @discardableResult
    public mutating func click(_ target: String) throws -> String {
        let e = try element(target)
        let c = e.click
        var did: [String] = []
        if let c, c.changesState {
            let before = state, hiddenBefore = Set(hiddenByState.map(\.id))
            let queues = doc.metrics(at: time, state: .values(before), since: sinceChange, carried: carried).carry
            state = c.applied(to: state, initial: doc.variables ?? [:])
            if state != before { sinceChange = 0; carried = queues }
            let changed = state.keys.sorted().filter { before[$0] ?? false != state[$0] ?? false }
            did.append(changed.isEmpty ? "changed no variable" : "set " + changed.map { "\($0)=\(state[$0]!)" }.joined(separator: ", "))
            let hiddenAfter = Set(hiddenByState.map(\.id))
            let shows = doc.elements.filter { hiddenBefore.contains($0.id) && !hiddenAfter.contains($0.id) }
            let hides = doc.elements.filter { !hiddenBefore.contains($0.id) && hiddenAfter.contains($0.id) }
            if !shows.isEmpty { did.append("shows " + shows.map(Self.name).joined(separator: ", ")) }
            if !hides.isEmpty { did.append("hides " + hides.map(Self.name).joined(separator: ", ")) }
        }
        let markers = doc.timeline?.markers ?? []
        if let name = c?.scene, !name.isEmpty, let i = DottieDocument.scene(named: name, in: markers) {
            frame = scenes[i]
            setPlaying(true)
            did.append("plays scene \(sceneNames[i])")
        } else if let url = c?.url ?? e.outsideLink?.webAddress {
            did.append("opens \(url) (not followed)")
        } else if c == nil || !(c!.changesState), let link = e.link {
            did.append("shows the page with \(link.uuidString) (not followed)")
        }
        if let name = c?.scene, !name.isEmpty, DottieDocument.scene(named: name, in: markers) == nil {
            did.append("names scene '\(name)', which isn't on the page")
        }
        return did.isEmpty ? "does nothing (no click)" : did.joined(separator: "; ")
    }

    /// The page as drawn now: the frame, with these variables.
    public var picture: DottieDocument { doc.resolved(at: time, state: .values(state), since: sinceChange, carried: carried) }

    /// The elements with a condition that the variables now hide.
    public var hiddenByState: [Element] {
        let off = doc.stateHidden(.values(state))
        return doc.elements.filter { off.contains($0.id) }
    }

    /// One line on where the page is: time, scene, playing, variables and what they hide.
    public var summary: String {
        var parts = [String(format: "t=%.2fs", time)]
        if let scene { parts.append("scene \(scene)") }
        parts.append(playing ? "playing" : "stopped")
        if !state.isEmpty { parts.append(state.keys.sorted().map { "\($0)=\(state[$0]!)" }.joined(separator: " ")) }
        let hidden = hiddenByState
        if doc.elements.contains(where: { $0.when != nil }) {
            parts.append(hidden.isEmpty ? "nothing hidden by when"
                         : "hidden by when: " + hidden.map(Self.name).joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }

    static func name(_ e: Element) -> String {
        if let t = e.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return "\"\(t.prefix(30))\"" }
        if let a = e.anchor, !a.isEmpty { return a }
        return "\(e.kind.rawValue) \(e.id.uuidString.prefix(8))"
    }
}

extension Simulation {
    /// A run of a page as a viewer would see it, frame by frame (`Simulation.record`): what a GIF or movie of
    /// clicking through it draws.
    public struct Recording: Sendable {
        /// The rate a page without a timeline is recorded at.
        static let stillFPS = 12.0
        public let doc: DottieDocument
        /// Frames a second: the timeline's.
        public let fps: Double
        public var frames: [Frame]

        /// One frame: the moment, the variables, and the queues' inputs (ADR 0003).
        public struct Frame: Sendable, Equatable {
            public var time: Double
            public var state: [String: Var]
            public var since: Double
            public var carried: [String: Double]
        }

        /// Frame `i` as drawn.
        public func picture(_ i: Int) -> DottieDocument {
            let f = frames[i]
            return doc.resolved(at: f.time, state: .values(f.state), since: f.since, carried: f.carried)
        }
    }
}

extension DottieDocument {
    /// The page with these variables as its starting values (the others keep theirs), so every export, still and
    /// player shows that state.
    public func starting(with values: [String: Var]) -> DottieDocument {
        guard !values.isEmpty else { return self }
        var copy = self
        copy.variables = (variables ?? [:]).merging(values) { _, new in new }
        return copy
    }
}

extension PageState {
    /// Variable values written `down=true,east=false,count=3` (or `down,!east`): a bare name is true, `!name`
    /// false, a number a number.
    public static func assignments(_ spec: String) throws -> [String: Var] {
        var out: [String: Var] = [:]
        for part in spec.split(separator: ",") {
            var term = part.trimmingCharacters(in: .whitespaces)
            if term.isEmpty { continue }
            var value: Var = true
            if let eq = term.firstIndex(of: "=") {
                let v = term[term.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()
                switch v {
                case "true", "yes", "on": value = true
                case "false", "no", "off": value = false
                default:
                    guard let n = Double(v), n.isFinite else {
                        throw OpsError.invalid("A variable's value is true, false or a number, got '\(v)' in '\(spec)'")
                    }
                    value = .number(n)
                }
                term = term[..<eq].trimmingCharacters(in: .whitespaces)
            } else if term.hasPrefix("!") {
                value = .bool(false)
                term = String(term.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            try checkName(term)
            out[term] = value
        }
        return out
    }

    /// Throws for a name that can't name a variable.
    public static func checkName(_ name: String) throws {
        guard isName(name) else {
            throw OpsError.invalid("A variable name is a letter or _, then letters, digits or _ (at most \(maxName)), got '\(name)'")
        }
    }
}
