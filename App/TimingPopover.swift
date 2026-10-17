import SwiftUI
import DottieKit

/// The animation's length and frame rate, in a popover from the time in the timeline's header. It warns, without
/// refusing, when a shorter length would leave keys or scenes past the end, since those then never play.
struct TimingPopover: View {
    var timeline: Timeline
    var onCommit: (_ duration: Double, _ fps: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lengthText: String?
    @State private var fpsChoice: Double?
    @FocusState private var focused: Bool

    private static let rates: [Double] = [12, 15, 24, 25, 30, 60]

    private var text: Binding<String> {
        Binding(get: { lengthText ?? Self.seconds(timeline.duration) }, set: { lengthText = $0 })
    }
    private var length: Double? {
        Double(text.wrappedValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
    private var fps: Double { fpsChoice ?? timeline.fps }

    private var problem: String? {
        guard let length, length.isFinite else { return "The length is a number of seconds." }
        if length <= 0 { return "The animation needs some length." }
        if length > Timeline.maxDuration { return "An animation can be at most an hour long." }
        return nil
    }

    /// What the new timing leaves out, or how many frames it makes.
    private var note: (String, Color) {
        if let problem { return (problem, .red) }
        let cut = timeline.cutOff(by: length!)
        let parts = [Self.count(cut.keys, "key"), Self.count(cut.scenes, "scene")].compactMap { $0 }
        if !parts.isEmpty {
            let are = cut.keys + cut.scenes == 1 ? "comes" : "come"
            return ("\(parts.joined(separator: " and ")) \(are) after \(Self.seconds(length!))s and won't play.", .orange)
        }
        var t = timeline
        t.duration = length!
        t.fps = fps
        return ("\(t.frameCount) frames", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Animation Timing", systemImage: "timer")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow {
                    Text("Length").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("Seconds", text: text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .focused($focused)
                            .onSubmit(commit)
                        Stepper("Length", value: Binding(get: { length ?? timeline.duration },
                                                         set: { lengthText = Self.seconds(min(max($0, 0.5), Timeline.maxDuration)) }),
                                step: 0.5)
                            .labelsHidden()
                        Text("s").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Frame rate").foregroundStyle(.secondary)
                    Picker("Frame rate", selection: Binding(get: { fps }, set: { fpsChoice = $0 })) {
                        ForEach(Self.rates.contains(timeline.fps) ? Self.rates : (Self.rates + [timeline.fps]).sorted(), id: \.self) {
                            Text("\(Self.seconds($0)) fps").tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Text(note.0)
                .font(.caption)
                .foregroundStyle(note.1)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func commit() {
        guard problem == nil, let length else { return }
        dismiss()
        onCommit(length, fps)
    }

    /// 3, 2.5, 0.25: no trailing zeros.
    static func seconds(_ s: Double) -> String { s.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) }

    private static func count(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
