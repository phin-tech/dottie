import SwiftUI
import DottieKit

/// The strip under an animated page's canvas: preview the animation, play and pause it, and scrub through it.
/// While previewing, the canvas shows the frame at `playhead` and takes no edits; Done goes back to editing.
struct TimelineBar: View {
    let timeline: Timeline
    @Binding var playhead: Double?
    @State private var playing = false

    var body: some View {
        HStack(spacing: 10) {
            if let t = playhead {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(playing ? "Pause" : "Play")
                Slider(value: Binding(get: { t }, set: { playing = false; playhead = $0 }),
                       in: 0...max(timeline.duration, 0.01))
                    .controlSize(.small)
                Text(String(format: "%.1fs", t))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Button("Done") { playing = false; playhead = nil }
                    .controlSize(.small)
                    .help("Back to editing")
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Button { playhead = 0; playing = true } label: { Label("Preview", systemImage: "play.fill") }
                    .controlSize(.small)
                    .help("Play the page's animation")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
        .onExitCommand { if playhead != nil { playing = false; playhead = nil } }
        .task(id: playing) {
            guard playing else { return }
            let step = 1 / max(timeline.fps, 1)
            while playing, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(step))
                guard playing, let t = playhead else { playing = false; return }
                let next = t + step
                playhead = next >= timeline.duration ? 0 : next   // loops, like the exports
            }
        }
    }

    private var summary: String {
        let secs = timeline.duration.formatted(.number.precision(.fractionLength(0...1)))
        return "Animation · \(secs)s · \(timeline.frameCount) frames"
    }
}
