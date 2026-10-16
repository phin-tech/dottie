import Foundation
import CoreGraphics
import AVFoundation

extension Exporter {
    /// Every frame of `doc`'s timeline, and the bounds that hold all of them. A page without a timeline is
    /// one frame.
    static func animation(_ doc: DottieDocument) -> (Timeline, [DottieDocument], CGRect) {
        let timeline = doc.timeline ?? Timeline(duration: 0)
        let frames = (0..<timeline.frameCount).map { doc.resolved(at: timeline.time(ofFrame: $0)) }
        let b = frames.map { bounds(of: $0) }.reduce(CGRect.null) { $0.union($1) }
        return (timeline, frames, b)
    }

    /// The page's timeline as an H.264 movie on the page color.
    public static func mp4(_ doc: DottieDocument, scale: Double = 2) -> Data? {
        let (timeline, frames, area) = animation(doc)
        // H.264 wants even dimensions: grow the area to the next even pixel size.
        let w = Int((area.width * scale).rounded(.up)) + Int((area.width * scale).rounded(.up)) % 2
        let h = Int((area.height * scale).rounded(.up)) + Int((area.height * scale).rounded(.up)) % 2
        let b = CGRect(x: area.minX, y: area.minY, width: Double(w) / scale, height: Double(h) / scale)

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

        for (i, frame) in frames.enumerated() {
            guard let image = bitmap(frame, bounds: b, scale: scale, background: CGColor(gray: 1, alpha: 1)),
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
            let time = CMTime(value: CMTimeValue((Double(i) * 600 / timeline.fps).rounded()), timescale: 600)
            guard adaptor.append(buffer, withPresentationTime: time) else { writer.cancelWriting(); return nil }
        }
        input.markAsFinished()
        // Hold the last frame for its full length rather than a single tick.
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue((Double(frames.count) * 600 / timeline.fps).rounded()), timescale: 600))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { return nil }
        return try? Data(contentsOf: url)
    }

    /// A self-contained web page that plays the page's timeline: every frame as inline SVG, with play/pause,
    /// a scrubber, and the space and arrow keys. It loops, and stays sharp at any size.
    public static func player(_ doc: DottieDocument, title: String = "Dottie animation") -> String {
        let (timeline, frames, b) = animation(doc)
        let page = doc.resolvedTheme?.background ?? RGBA(r: 1, g: 1, b: 1)
        let ink = doc.resolvedTheme?.ink ?? .black
        func hex(_ c: RGBA) -> String {
            func h(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
            return "#\(h(c.r))\(h(c.g))\(h(c.b))"
        }
        let safeTitle = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        var body = ""
        for (i, f) in frames.enumerated() {
            body += "<div class=\"f\(i == 0 ? " on" : "")\">\(svg(f, background: nil, bounds: b))</div>\n"
        }
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
        .stage { width: min(100%, \(Int(b.width.rounded(.up)))px); }
        .f { display: none; } .f.on { display: block; }
        .f svg { width: 100%; height: auto; display: block; }
        .bar { display: flex; align-items: center; gap: 12px; width: min(100%, 480px); }
        button { font: inherit; color: inherit; background: none; border: 1.5px solid currentColor; border-radius: 6px;
          width: 34px; height: 30px; cursor: pointer; }
        input[type=range] { flex: 1; accent-color: var(--ink); }
        output { font-variant-numeric: tabular-nums; min-width: 4.5em; text-align: right; }
        </style>
        </head>
        <body>
        <div class="stage">
        \(body)</div>
        <div class="bar">
        <button id="play" aria-label="Pause">❚❚</button>
        <input id="scrub" type="range" min="0" max="\(frames.count - 1)" value="0" aria-label="Frame">
        <output id="time">0.0s</output>
        </div>
        <script>
        (function () {
          var fps = \(timeline.fps), frames = document.querySelectorAll(".f"), n = frames.length;
          var play = document.getElementById("play"), scrub = document.getElementById("scrub"), time = document.getElementById("time");
          var i = 0, playing = n > 1, last = 0, acc = 0;
          function show(k) {
            frames[i].classList.remove("on"); i = (k + n) % n; frames[i].classList.add("on");
            scrub.value = i; time.textContent = (i / fps).toFixed(1) + "s";
          }
          function setPlaying(p) {
            playing = p && n > 1; play.textContent = playing ? "❚❚" : "▶";
            play.setAttribute("aria-label", playing ? "Pause" : "Play"); last = 0; acc = 0;
          }
          function tick(now) {
            if (playing) {
              if (last) acc += now - last;
              last = now;
              while (acc >= 1000 / fps) { acc -= 1000 / fps; show(i + 1); }
            }
            requestAnimationFrame(tick);
          }
          play.onclick = function () { setPlaying(!playing); };
          scrub.oninput = function () { setPlaying(false); show(+scrub.value); };
          document.addEventListener("keydown", function (e) {
            if (e.target === scrub && e.key !== " ") return;
            if (e.key === " ") { e.preventDefault(); setPlaying(!playing); }
            else if (e.key === "ArrowRight") { setPlaying(false); show(i + 1); }
            else if (e.key === "ArrowLeft") { setPlaying(false); show(i - 1); }
          });
          if (matchMedia("(prefers-reduced-motion: reduce)").matches) { setPlaying(false); show(n - 1); }
          setPlaying(playing);
          requestAnimationFrame(tick);
        })();
        </script>
        </body>
        </html>

        """
    }
}
