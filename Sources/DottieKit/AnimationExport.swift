import Foundation
import CoreGraphics
import AVFoundation

extension Exporter {
    /// The most frames an animation export draws (about 11 minutes at 15 fps).
    public static let maxAnimationFrames = 10_000

    /// True when `doc`'s animation has more frames than an export will draw.
    public static func animationTooLong(_ doc: DottieDocument) -> Bool {
        (doc.timeline?.frameCount ?? 1) + 1 > maxAnimationFrames
    }

    /// What an animation export draws: each frame's time, how long it shows, and the part of the page it
    /// shows, all at one output size (`size`, in points). Without a camera every frame shows the bounds of
    /// the whole animation; with one, each shows the camera's view, widened to the first key's shape so
    /// the output size never changes. Frames are resolved again when drawn rather than kept, so memory stays
    /// flat; empty frames (before anything has entered) don't count towards the bounds. nil when there are
    /// too many frames to export.
    struct Plan {
        var timeline: Timeline
        var times: [Double]
        var durations: [Double]
        var rects: [CGRect]
        var size: CGSize
    }

    static func animation(_ doc: DottieDocument) -> Plan? {
        guard !animationTooLong(doc) else { return nil }
        let timeline = doc.timeline ?? Timeline(duration: 0)
        let times = timeline.frameTimes
        let step = 1 / timeline.fps
        let durations = times.indices.map { i in i + 1 < times.count ? times[i + 1] - times[i] : step }
        if let first = timeline.camera?.first(where: { $0.width > 1 && $0.height > 1 }) {
            let aspect = first.width / first.height
            let rects = times.map { timeline.cameraView(at: $0) ?? first.rect }
            // Big enough for the widest view at 1:1, within a sane pixel budget.
            let width = min(Double(rects.map(\.width).max() ?? CGFloat(first.width)), 4096)
            return Plan(timeline: timeline, times: times, durations: durations, rects: rects,
                        size: CGSize(width: width, height: width / aspect))
        }
        var b = CGRect.null
        for t in times {
            let frame = doc.resolved(at: t)
            if !frame.elements.isEmpty { b = b.union(bounds(of: frame)) }
        }
        if b.isNull { b = bounds(of: doc.resolved(at: times[0])) }
        return Plan(timeline: timeline, times: times, durations: durations,
                    rects: Array(repeating: b, count: times.count), size: b.size)
    }

    /// Every frame's SVG for the player, sharing what repeats. Anything whose markup is the same in every
    /// frame is drawn once, consecutive runs of it as one group; any other piece that turns up in more than
    /// one frame (lines boiling every few frames, a shape that has settled) is also stored once. Frames refer
    /// to those with `<use>`, in place, so the stacking order and the pixels are exactly what drawing each
    /// frame whole gives (`defs` goes once, before the frames). Size then grows with what changes, not with
    /// the size of the drawing.
    ///
    /// A clickable element (`clickable`: its id and the index of its action) is drawn in place in every frame,
    /// never shared: a click inside a `<use>` is reported on the `<use>`, and the page's styles can't reach what
    /// a `<use>` draws. It is one focusable group holding its normal look and, if it has one, its hover look. A
    /// symbol's copy gathers every part it draws into that group; a button's copy adds its over and down states,
    /// and a layer on top that takes the clicks: its hit state, or else its frame.
    static func playerFrames(_ doc: DottieDocument, plan: Plan, clickable: [String: Int] = [:]) -> (defs: String, frames: [String]) {
        let clickIDs = Set(doc.elements.filter { clickable[$0.id.uuidString] != nil }.map(\.id))
        let instanceIDs = Set(doc.elements.filter { clickIDs.contains($0.id) && $0.kind == .symbol }.map(\.id))
        // Who each drawn part belongs to, when that is a clickable element: itself, or the copy it is part of.
        var owner: [String: String] = [:]
        for id in clickIDs.subtracting(instanceIDs) { owner[id.uuidString] = id.uuidString }
        for (part, id) in doc.parts(of: instanceIDs) { owner[part] = id.uuidString }
        let hoverIDs = Set(doc.elements.filter { clickIDs.contains($0.id) && $0.kind != .symbol && !($0.hover?.isEmpty ?? true) }.map(\.id))
        let over = doc.buttonTimes(.over, of: instanceIDs), down = doc.buttonTimes(.down, of: instanceIDs)
        let hit = doc.buttonTimes(.hit, of: instanceIDs)

        /// One frame: every part's markup, and for clickable owners their markup in each state.
        struct Frame {
            var bounds: CGRect
            var parts: [String: String]
            var hover: [String: String] = [:], over: [String: String] = [:], down: [String: String] = [:], hit: [String: String] = [:]
            var frames: [String: CGRect] = [:]
            var angles: [String: Double] = [:]
        }
        /// The parts of `d` belonging to clickable owners; only to the owners in `of` when given (those with that state).
        func keyed(_ d: DottieDocument, _ r: CGRect, of: [UUID: Double]? = nil) -> [String: String] {
            let only = of.map { Set($0.keys.map(\.uuidString)) }
            return Dictionary(svgParts(d, background: nil, bounds: r).1.filter { p in
                guard let o = owner[p.key] else { return false }
                return only?.contains(o) ?? true
            }.map { ($0.key, $0.markup) }, uniquingKeysWith: { a, _ in a })
        }
        var order = ["rock"] + doc.expandingSymbols(at: 0, posing: false).orderedElements.map(\.id.uuidString)
        let frames0 = plan.times.indices.map { i -> Frame in
            let t = Timeline.clampTime(plan.times[i]), r = plan.rects[i]
            let posed = doc.posed(at: t)
            let shown = posed.expandingSymbols(at: t)
            let (b, parts) = svgParts(shown, background: nil, bounds: r)
            var f = Frame(bounds: b, parts: Dictionary(parts.map { ($0.key, $0.markup) }, uniquingKeysWith: { a, _ in a }))
            if !hoverIDs.isEmpty { f.hover = keyed(shown.hovered(hoverIDs), r) }
            if !over.isEmpty { f.over = keyed(posed.expandingSymbols(at: t, times: over), r, of: over) }
            if !down.isEmpty { f.down = keyed(posed.expandingSymbols(at: t, times: down), r, of: down) }
            if !hit.isEmpty { f.hit = keyed(posed.expandingSymbols(at: t, times: hit), r, of: hit) }
            for e in posed.elements where instanceIDs.contains(e.id) { f.frames[e.id.uuidString] = e.frame; f.angles[e.id.uuidString] = e.angle }
            return f
        }
        // A hit state can draw parts the copy otherwise never shows; they still belong in the order.
        let known = Set(order)
        for f in frames0 { for k in f.hit.keys.sorted() where !known.contains(k) { order.append(k) } }

        let byKey = frames0.map(\.parts)
        let labels: [String: String] = {
            let table = doc.symbolIndex
            return Dictionary(doc.elements.map { e in
                (e.id.uuidString, e.buttonLabel(symbolName: e.symbol.flatMap { table[$0]?.name }).attributeEscaped)
            }, uniquingKeysWith: { a, _ in a })
        }()
        let unchanging = Set(order.filter { key in
            guard owner[key] == nil, let first = byKey.first?[key] else { return false }
            return byKey.allSatisfy { $0[key] == first }
        })
        var defs = "", runOf: [String: Int] = [:], runCount = 0
        var i = 0
        while i < order.count {
            guard unchanging.contains(order[i]) else { i += 1; continue }
            var markup = ""
            let start = i
            while i < order.count, unchanging.contains(order[i]) { markup += byKey[0][order[i]]!; runOf[order[i]] = runCount; i += 1 }
            if start < i { defs += "<g id=\"ds\(runCount)\">\n\(markup)</g>\n"; runCount += 1 }
        }
        // The other pieces worth sharing: markup that more than one frame uses.
        var uses: [String: Int] = [:]
        for frame in byKey { for (key, markup) in frame where !unchanging.contains(key) && owner[key] == nil { uses[markup, default: 0] += 1 } }
        // Numbered in drawing order, so the same drawing always exports the same page.
        var shared: [String: Int] = [:]
        for frame in byKey {
            for key in order where !unchanging.contains(key) && owner[key] == nil {
                if let markup = frame[key], uses[markup, default: 0] > 1, shared[markup] == nil { shared[markup] = shared.count }
            }
        }
        for (markup, id) in shared.sorted(by: { $0.value < $1.value }) { defs += "<g id=\"dp\(id)\">\n\(markup)</g>\n" }

        // Each owner's parts, in drawing order.
        var partsOf: [String: [String]] = [:]
        for key in order { if let o = owner[key] { partsOf[o, default: []].append(key) } }

        let frames = frames0.map { f -> String in
            var out = svgOpen(f.bounds, background: nil, paint: false)
            var lastRun = -1
            var done = Set<String>()
            for key in order {
                if let run = runOf[key] {
                    if run != lastRun { out += "<use href=\"#ds\(run)\"/>\n"; lastRun = run }
                } else if let o = owner[key] {
                    guard !done.contains(o), let a = clickable[o] else { continue }
                    let keys = partsOf[o] ?? []
                    let normal = keys.compactMap { f.parts[$0] }.joined()
                    guard !normal.isEmpty else { continue }
                    done.insert(o)
                    out += button(o, index: a, label: labels[o] ?? "", keys: keys, in: f, normal: normal)
                    lastRun = -1
                } else if let markup = f.parts[key] {
                    out += shared[markup].map { "<use href=\"#dp\($0)\"/>\n" } ?? markup
                    lastRun = -1
                }
            }
            return out + "</svg>\n"
        }

        /// The group a clickable owner draws as in one frame.
        func button(_ o: String, index a: Int, label: String, keys: [String], in f: Frame, normal: String) -> String {
            func state(_ m: [String: String]) -> String? {
                let s = keys.compactMap { m[$0] }.joined()
                return s.isEmpty ? nil : s
            }
            let isInstance = f.frames[o] != nil
            let overMarkup = isInstance ? state(f.over) : state(f.hover)
            let downMarkup = isInstance ? state(f.down) : nil
            let shownOver = overMarkup.flatMap { $0 == normal ? nil : $0 }
            let shownDown = downMarkup.flatMap { $0 == (overMarkup ?? normal) ? nil : $0 }
            var g = "<g class=\"dottie-a\(shownDown == nil ? "" : " dottie-b")\" data-a=\"\(a)\" tabindex=\"0\" role=\"button\" aria-label=\"\(label)\">\n"
            if !isInstance, shownOver == nil { return g + normal + "</g>\n" }
            let still = isInstance ? " pointer-events=\"none\"" : ""
            g += "<g class=\"dottie-n\"\(still)>\n\(normal)</g>\n"
            if let shownOver { g += "<g class=\"dottie-h\"\(still)>\n\(shownOver)</g>\n" }
            if let shownDown { g += "<g class=\"dottie-d\"\(still)>\n\(shownDown)</g>\n" }
            if isInstance {
                // What takes the clicks: the hit state drawn invisibly, or the copy's frame.
                if let h = state(f.hit) {
                    g += "<g class=\"dottie-hit\" opacity=\"0\" pointer-events=\"all\">\n\(h)</g>\n"
                } else if let r = f.frames[o] {
                    let c = CGPoint(x: r.midX, y: r.midY), angle = f.angles[o] ?? 0
                    let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                        .map { Element.rotate($0, about: c, by: angle) }
                    let path = CGMutablePath()
                    path.addLines(between: corners)
                    path.closeSubpath()
                    g += "<path class=\"dottie-hit\" d=\"\(pathData(path))\" fill=\"none\" stroke=\"none\" pointer-events=\"all\"/>\n"
                }
            }
            return g + "</g>\n"
        }

        let holder = defs.isEmpty ? "" : "<svg width=\"0\" height=\"0\" style=\"position:absolute;overflow:hidden\" aria-hidden=\"true\"><defs>\n\(defs)</defs></svg>\n"
        return (holder, frames)
    }

    /// `r` widened (never cropped) about its center to the width-to-height ratio `aspect`.
    static func fit(_ r: CGRect, aspect: Double) -> CGRect {
        guard r.width > 0, r.height > 0, aspect > 0 else { return r }
        var out = r
        if r.width / r.height < aspect { out.size.width = r.height * aspect } else { out.size.height = r.width / aspect }
        out.origin = CGPoint(x: r.midX - out.width / 2, y: r.midY - out.height / 2)
        return out
    }

    /// The page's timeline as an H.264 movie on the page color.
    public static func mp4(_ doc: DottieDocument, scale: Double = 2) -> Data? {
        guard let plan = animation(doc) else { return nil }
        let times = plan.times, durations = plan.durations
        // H.264 wants even dimensions: round the output up to the next even pixel size, and widen each view
        // to match, so nothing is stretched.
        let w = Int((plan.size.width * scale).rounded(.up)) + Int((plan.size.width * scale).rounded(.up)) % 2
        let h = Int((plan.size.height * scale).rounded(.up)) + Int((plan.size.height * scale).rounded(.up)) % 2
        let rects = plan.rects.map { fit($0, aspect: Double(w) / Double(h)) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dottie-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        for (i, t) in times.enumerated() {
            guard let image = bitmap(doc.resolved(at: t), bounds: rects[i], scale: scale, background: CGColor(gray: 1, alpha: 1),
                                     pixels: (w, h)),
                  let pool = adaptor.pixelBufferPool else { writer.cancelWriting(); return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { writer.cancelWriting(); return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            let time = CMTime(value: CMTimeValue((t * 600).rounded()), timescale: 600)
            guard adaptor.append(buffer, withPresentationTime: time) else { writer.cancelWriting(); return nil }
        }
        input.markAsFinished()
        // Hold the last frame for its full length rather than a single tick.
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(((times.last ?? 0) + (durations.last ?? 0)) * 600), timescale: 600))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { return nil }
        return try? Data(contentsOf: url)
    }

    /// How clickable elements look in the web players: a pointer, their hover look under it or with keyboard
    /// focus (a soft glow when they have none), and a small nudge (or a button's down look) while pressed. The
    /// classes `dottie-hover` and `dottie-press` stand in for `:hover` and `:active` on a button the web page export
    /// has just swapped in, which the browser doesn't count as under the pointer until it moves.
    static let clickStyle = """
    .dottie-a { cursor: pointer; outline: none; }
    .dottie-a .dottie-h { display: none; }
    .dottie-a:hover .dottie-h, .dottie-a.dottie-hover .dottie-h, .dottie-a:focus-visible .dottie-h { display: inline; }
    .dottie-a:hover .dottie-n, .dottie-a.dottie-hover .dottie-n, .dottie-a:focus-visible .dottie-n { display: none; }
    .dottie-a:focus-visible { filter: drop-shadow(0 0 3px var(--dottie-focus, #3b82f6)); }
    .dottie-a:not(.dottie-b):active, .dottie-a.dottie-press:not(.dottie-b) { transform: translate(1px, 1px); }
    .dottie-a .dottie-d { display: none; }
    .dottie-b:active .dottie-n, .dottie-b:active .dottie-h, .dottie-b.dottie-press .dottie-n, .dottie-b.dottie-press .dottie-h { display: none; }
    .dottie-b:active .dottie-d, .dottie-b.dottie-press .dottie-d { display: inline; }
    """

    /// A self-contained web page that plays the page's timeline: every frame as inline SVG, with play/pause,
    /// a scrubber, and the space and arrow keys. It loops, and stays sharp at any size. With scene markers it
    /// becomes a click-through presentation: playing stops at each scene, and next/back (or the arrow keys)
    /// move between scenes. Clickable elements (`Element.click`) jump to their scene or open their link, by
    /// mouse or keyboard. nil when the animation is too long to export (see `maxAnimationFrames`).
    public static func player(_ doc: DottieDocument, title: String = "Dottie animation") -> String? {
        guard let plan = animation(doc) else { return nil }
        let timeline = plan.timeline, times = plan.times
        // With reduced motion the player rests on the frame a still would show.
        let poster = timeline.poster ?? timeline.duration
        func nearest(_ t: Double) -> Int { times.indices.min { abs(times[$0] - t) < abs(times[$1] - t) } ?? 0 }
        let posterIndex = nearest(poster)
        let scenes = (timeline.markers ?? []).map { (frame: nearest($0.t), name: $0.name) }
        let page = doc.resolvedTheme?.background ?? RGBA(r: 1, g: 1, b: 1)
        let ink = doc.resolvedTheme?.ink ?? .black
        func hex(_ c: RGBA) -> String {
            func h(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
            return "#\(h(c.r))\(h(c.g))\(h(c.b))"
        }
        /// A value safe to drop into the page's script: JSON, with `</` broken so it can't close the tag.
        func js<T: Encodable>(_ v: T) -> String {
            let data = (try? JSONEncoder().encode(v)) ?? Data("null".utf8)
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        }
        let safeTitle = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        // Clickable elements, back to front, and what each does: a scene's index, or a link.
        let targets = doc.clickTargets
        var clickable: [String: Int] = [:]
        var actions: [[String: String]] = []
        for e in doc.orderedElements {
            guard let target = targets[e.id] else { continue }
            clickable[e.id.uuidString] = actions.count
            switch target {
            case .scene(let i): actions.append(["s": String(i)])
            case .url(let u): actions.append(["u": u])
            }
        }
        let (defs, frames) = playerFrames(doc, plan: plan, clickable: clickable)
        var body = ""
        for (i, frame) in frames.enumerated() {
            body += "<div class=\"f\(i == 0 ? " on" : "")\">\(frame)</div>\n"
        }
        let sceneControls = scenes.isEmpty ? "" : """
        <button id="prev" aria-label="Previous scene">⏮</button>
        <output id="scene"></output>
        <button id="next" aria-label="Next scene">⏭</button>
        """
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safeTitle)</title>
        <style>
        :root { --page: \(hex(page)); --ink: \(hex(ink)); }
        html, body { margin: 0; min-height: 100%; background: var(--page); color: var(--ink);
          font: 14px -apple-system, system-ui, sans-serif; }
        body { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 16px;
          min-height: 100vh; padding: 16px; box-sizing: border-box; }
        .stage { width: min(100%, \(Int(plan.size.width.rounded(.up)))px); }
        .f { display: none; } .f.on { display: block; }
        .f svg { width: 100%; height: auto; display: block; }
        .bar { display: flex; align-items: center; gap: 12px; width: min(100%, 560px); }
        button { font: inherit; color: inherit; background: none; border: 1.5px solid currentColor; border-radius: 6px;
          width: 34px; height: 30px; cursor: pointer; }
        input[type=range] { flex: 1; accent-color: var(--ink); }
        output { font-variant-numeric: tabular-nums; min-width: 4.5em; text-align: right; }
        #scene { min-width: 0; text-align: center; font-weight: 600; white-space: nowrap; }
        \(clickable.isEmpty ? "" : clickStyle)
        </style>
        </head>
        <body>
        \(defs)<div class="stage">
        \(body)</div>
        <div class="bar">
        <button id="play" aria-label="Pause">❚❚</button>
        \(sceneControls)
        <input id="scrub" type="range" min="0" max="\(times.count - 1)" value="0" aria-label="Frame">
        <output id="time">0.0s</output>
        </div>
        <script>
        (function () {
          var times = \(js(times)), scenes = \(js(scenes.map(\.frame))), names = \(js(scenes.map(\.name)));
          var frames = document.querySelectorAll(".f"), n = frames.length, step = 1000 / \(timeline.fps);
          var play = document.getElementById("play"), scrub = document.getElementById("scrub"), time = document.getElementById("time");
          var sceneLabel = document.getElementById("scene"), acts = \(js(actions));
          var reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
          var i = 0, playing = n > 1, last = 0, acc = 0;
          function sceneAt(k) { var s = -1; for (var j = 0; j < scenes.length; j++) if (scenes[j] <= k) s = j; return s; }
          function show(k) {
            // Keyboard focus on a clickable element moves to its copy in the frame shown next.
            var a = document.activeElement, held = a && a.getAttribute && frames[i].contains(a) ? a.getAttribute("data-a") : null;
            frames[i].classList.remove("on"); i = (k + n) % n; frames[i].classList.add("on");
            if (held !== null) { var same = frames[i].querySelector('[data-a="' + held + '"]'); if (same) same.focus({ preventScroll: true }); }
            if (hovered !== null || holding !== null) mark();
            scrub.value = i; time.textContent = times[i].toFixed(1) + "s";
            if (sceneLabel) { var s = sceneAt(i); sceneLabel.textContent = s < 0 ? "" : names[s]; }
          }
          function setPlaying(p) {
            playing = p && n > 1; play.textContent = playing ? "❚❚" : "▶";
            play.setAttribute("aria-label", playing ? "Pause" : "Play"); last = 0; acc = 0;
          }
          // With scenes, playing stops on the next scene (and at the end, rather than looping).
          function advance() {
            var next = i + 1;
            if (scenes.length && next >= n) { setPlaying(false); return false; }
            show(next);
            if (scenes.indexOf(i) >= 0) { setPlaying(false); return false; }
            return true;
          }
          function tick(now) {
            if (playing) {
              if (last) acc += now - last;
              last = now;
              while (playing && acc >= step) { acc -= step; if (!advance()) break; }
            }
            requestAnimationFrame(tick);
          }
          function nextScene() { if (i >= n - 1) show(0); setPlaying(true); }
          function prevScene() {
            var s = sceneAt(i);
            if (s >= 0 && scenes[s] === i) s -= 1;
            setPlaying(false); show(s >= 0 ? scenes[s] : 0);
          }
          // A clickable element jumps to its scene and plays on to the next (with reduced motion, straight to
          // where that stops), or opens its link.
          function act(k) {
            var x = acts[k];
            if (!x) return;
            if (x.u) { if (/^(https?:|mailto:)/i.test(x.u)) window.open(x.u, "_blank", "noopener"); return; }
            var s = +x.s;
            if (!(s >= 0 && s < scenes.length)) return;
            if (reduced || n < 2) { setPlaying(false); show(s + 1 < scenes.length ? scenes[s + 1] : n - 1); return; }
            show(scenes[s]); setPlaying(true);
          }
          function button(t) { return t && t.closest ? t.closest(".dottie-a") : null; }
          // Frames are swapped while playing, so a press and its release can land on different copies of a button,
          // and the click then reaches only the stage: the button pressed still counts if it is under the release.
          // The button under the pointer, and the one held down, are marked in each frame shown, since the browser
          // only counts a newly shown copy as hovered once the pointer moves.
          var stage = document.querySelector(".stage"), pressed = null, hovered = null, holding = null;
          function mark() {
            var old = document.querySelectorAll(".dottie-hover, .dottie-press");
            for (var j = 0; j < old.length; j++) old[j].classList.remove("dottie-hover", "dottie-press");
            if (hovered !== null) { var h = frames[i].querySelector('[data-a="' + hovered + '"]'); if (h) h.classList.add("dottie-hover"); }
            if (holding !== null) { var p = frames[i].querySelector('[data-a="' + holding + '"]'); if (p) p.classList.add("dottie-press"); }
          }
          stage.addEventListener("pointermove", function (e) {
            var b = button(e.target), a = b ? b.getAttribute("data-a") : null;
            if (a !== hovered) { hovered = a; mark(); }
          });
          stage.addEventListener("pointerleave", function () { hovered = null; holding = null; mark(); });
          document.addEventListener("pointerup", function () { if (holding !== null) { holding = null; mark(); } });
          document.addEventListener("pointercancel", function () { holding = null; mark(); });
          stage.addEventListener("pointerdown", function (e) {
            var b = button(e.target);
            pressed = b ? b.getAttribute("data-a") : null;
            holding = pressed;
            mark();
          });
          stage.addEventListener("click", function (e) {
            var b = button(e.target), held = pressed;
            pressed = null;
            if (!b && held !== null) {
              var under = button(document.elementFromPoint(e.clientX, e.clientY));
              if (under && under.getAttribute("data-a") === held) b = under;
            }
            if (b) act(+b.getAttribute("data-a"));
          });
          play.onclick = function () { if (!playing && scenes.length && i >= n - 1) show(0); setPlaying(!playing); };
          scrub.oninput = function () { setPlaying(false); show(+scrub.value); };
          if (scenes.length) {
            document.getElementById("next").onclick = nextScene;
            document.getElementById("prev").onclick = prevScene;
          }
          document.addEventListener("keydown", function (e) {
            var b = button(e.target);
            if (b && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); act(+b.getAttribute("data-a")); return; }
            if (e.target === scrub && e.key !== " ") return;
            if (e.key === " ") { e.preventDefault(); scenes.length ? (playing ? setPlaying(false) : nextScene()) : setPlaying(!playing); }
            else if (e.key === "ArrowRight") { scenes.length ? nextScene() : (setPlaying(false), show(i + 1)); }
            else if (e.key === "ArrowLeft") { scenes.length ? prevScene() : (setPlaying(false), show(i - 1)); }
            else if (e.key === ".") { setPlaying(false); show(i + 1); }
            else if (e.key === ",") { setPlaying(false); show(i - 1); }
          });
          show(0);
          if (scenes.indexOf(0) >= 0) playing = false;
          if (reduced) { playing = false; show(\(posterIndex)); }
          setPlaying(playing);
          requestAnimationFrame(tick);
        })();
        </script>
        </body>
        </html>

        """
    }
}
