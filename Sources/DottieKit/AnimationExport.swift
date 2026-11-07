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

    /// A self-contained web page that plays the page with dottie.js's `<dottie-player>` (`script`): its timeline
    /// with play/pause, a scrubber and keys, its scenes as a click-through, its clicks and links, and its variables,
    /// redrawn as clicks change them. It stays sharp at any size, and its size doesn't grow with the animation's
    /// length. nil if the page can't be compiled.
    public static func player(_ doc: DottieDocument, title: String = "Dottie animation") -> String? {
        guard let script = try? script(doc, options: ScriptOptions(label: doc.name)) else { return nil }
        let page = doc.resolvedTheme?.background ?? RGBA(r: 1, g: 1, b: 1)
        func h(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        let safeTitle = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safeTitle)</title>
        <style>
        html, body { margin: 0; min-height: 100%; background: #\(h(page.r))\(h(page.g))\(h(page.b)); }
        body { display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 16px; box-sizing: border-box; }
        dottie-player { width: min(100%, 1200px); }
        </style>
        </head>
        <body>
        <script>
        \(script.replacingOccurrences(of: "</script", with: "<\\/script"))</script>
        </body>
        </html>

        """
    }

}
