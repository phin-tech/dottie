import SwiftUI
import DottieKit

/// The timeline under an animated page's canvas, Flash-style: a row per animated element, grouped by layer,
/// with its keyframes (diamonds) and what happens between them (bars), under a ruler and a playhead.
/// Dragging anywhere on the ruler or rows scrubs. While playing, the canvas shows the frame at `playhead`
/// and takes no edits; paused there, edits on the canvas pose that frame (they become keyframes). Done (or
/// Esc) goes back to editing the page itself. Clicking a row's name selects that element.
struct TimelinePanel: View {
    let page: DottieDocument
    @Binding var playhead: Double?
    @Binding var playing: Bool
    var onSelect: (UUID) -> Void
    @AppStorage("timelineCollapsed") private var collapsed = false
    @State private var collapsedLayers: Set<UUID> = []

    private let labelWidth: CGFloat = 170
    private let rowHeight: CGFloat = 22

    private var timeline: Timeline { page.timeline ?? Timeline(duration: 0) }
    private var rows: TimelineRows { TimelineRows(page) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Divider()
                grid
            }
        }
        .background(.bar)
        .onExitCommand { if playhead != nil { stop() } }
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { collapsed.toggle() } label: {
                Image(systemName: "chevron.right").rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .buttonStyle(.borderless)
            .help(collapsed ? "Show Timeline" : "Hide Timeline")
            Button {
                if playhead == nil { playhead = 0 }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(playing ? "Pause" : "Play")
            Text(timeText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if collapsed {
                Slider(value: Binding(get: { playhead ?? 0 }, set: { scrub(to: $0) }),
                       in: 0...max(timeline.duration, 0.01))
                    .controlSize(.small)
            } else {
                Spacer()
            }
            if playhead != nil {
                Button("Done") { stop() }
                    .controlSize(.small)
                    .help("Stop posing and edit the page itself (Esc)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var timeText: String {
        let total = timeline.duration.formatted(.number.precision(.fractionLength(1)))
        guard let t = playhead else { return "\(total)s · \(timeline.frameCount) frames" }
        return "\(t.formatted(.number.precision(.fractionLength(1)))) / \(total)s"
    }

    // MARK: Grid

    private var grid: some View {
        let groups = rows.groups
        let count = groups.reduce(0) { $0 + 1 + (collapsedLayers.contains($1.layer) ? 0 : $1.rows.count) }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth)
                Divider()
                ruler
                    .frame(height: 18)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { trackWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in trackWidth = w }
                    })
            }
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(groups) { group in
                        layerHeader(group)
                        if !collapsedLayers.contains(group.layer) {
                            ForEach(group.rows) { row in rowView(row) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)   // keeps every row exactly as wide as the ruler they scrub against
            .frame(height: min(CGFloat(count) * rowHeight, 200))
        }
    }

    private var ruler: some View {
        Canvas { ctx, size in
            let d = max(timeline.duration, 0.01)
            let step = d <= 3 ? 0.5 : d <= 12 ? 1 : 5
            var t = 0.0
            while t <= d + 1e-9 {
                let x = x(t, size.width)
                let major = (t / step).rounded() == t / step && Int((t / step).rounded()) % (step < 1 ? 2 : 1) == 0
                ctx.fill(Path(CGRect(x: x, y: size.height - (major ? 7 : 4), width: 1, height: major ? 7 : 4)),
                         with: .color(.secondary))
                if major {
                    ctx.draw(Text("\(t.formatted(.number.precision(.fractionLength(0...1))))s")
                                .font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 2, y: 1), anchor: .topLeading)
                }
                t += step
            }
            if let p = playhead { drawPlayhead(&ctx, size: size, at: p, head: true) }
        }
        .contentShape(Rectangle())
        .gesture(scrubGesture)
    }

    private func layerHeader(_ group: TimelineRows.Group) -> some View {
        let closed = collapsedLayers.contains(group.layer)
        return HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(closed ? 0 : 90))
            Image(systemName: "square.3.layers.3d").font(.system(size: 10))
            Text(group.name).font(.caption.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .frame(height: rowHeight)
        .background(Color.primary.opacity(0.04))
        .contentShape(Rectangle())
        .onTapGesture {
            if closed { collapsedLayers.remove(group.layer) } else { collapsedLayers.insert(group.layer) }
        }
    }

    private func rowView(_ row: TimelineRows.Row) -> some View {
        HStack(spacing: 0) {
            Button { onSelect(row.element) } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(row)).frame(width: 14).foregroundStyle(.secondary)
                    Text(row.label).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .frame(width: labelWidth, height: rowHeight)
            .help("Select \(row.label)")
            Divider()
            Canvas { ctx, size in drawTrack(row, in: &ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(scrubGesture)
        }
        .frame(height: rowHeight)
    }

    // MARK: Drawing

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        let inset: CGFloat = 6
        return inset + CGFloat(t / max(timeline.duration, 0.01)) * (width - inset * 2)
    }

    private func drawTrack(_ row: TimelineRows.Row, in ctx: inout GraphicsContext, size: CGSize) {
        let mid = size.height / 2
        for span in row.spans {
            let a = x(span.start, size.width), b = x(span.end, size.width)
            switch span.kind {
            case .hidden:
                ctx.fill(Path(CGRect(x: a, y: 2, width: b - a, height: size.height - 4)),
                         with: .color(.primary.opacity(0.06)))
            case .tween:
                ctx.fill(Path(roundedRect: CGRect(x: a, y: mid - 3, width: b - a, height: 6), cornerRadius: 3),
                         with: .color(.accentColor.opacity(0.45)))
            case .hold:
                ctx.fill(Path(CGRect(x: a, y: mid - 0.5, width: b - a, height: 1)), with: .color(.secondary))
            case .follow:
                var p = Path()
                p.move(to: CGPoint(x: a, y: mid)); p.addLine(to: CGPoint(x: b, y: mid))
                ctx.stroke(p, with: .color(.orange), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [4, 3]))
            }
        }
        for key in row.keys {
            let c = CGPoint(x: x(key.t, size.width), y: mid)
            let r: CGFloat = 4.5
            var d = Path()
            d.move(to: CGPoint(x: c.x, y: c.y - r)); d.addLine(to: CGPoint(x: c.x + r, y: c.y))
            d.addLine(to: CGPoint(x: c.x, y: c.y + r)); d.addLine(to: CGPoint(x: c.x - r, y: c.y)); d.closeSubpath()
            // Hollow when the key only shows or hides the element.
            if key.sets == [.visibility] {
                ctx.fill(d, with: .color(Color(nsColor: .windowBackgroundColor)))
                ctx.stroke(d, with: .color(.primary.opacity(0.7)), lineWidth: 1.2)
            } else {
                ctx.fill(d, with: .color(key.sets.contains(.color) && key.sets.count == 1 ? .pink : .primary.opacity(0.8)))
            }
        }
        if let p = playhead { drawPlayhead(&ctx, size: size, at: p, head: false) }
    }

    private func drawPlayhead(_ ctx: inout GraphicsContext, size: CGSize, at t: Double, head: Bool) {
        let px = x(t, size.width)
        ctx.fill(Path(CGRect(x: px - 0.5, y: 0, width: 1, height: size.height)), with: .color(.red))
        if head {
            var tri = Path()
            tri.move(to: CGPoint(x: px - 4, y: size.height - 6)); tri.addLine(to: CGPoint(x: px + 4, y: size.height - 6))
            tri.addLine(to: CGPoint(x: px, y: size.height)); tri.closeSubpath()
            ctx.fill(tri, with: .color(.red))
        }
    }

    // MARK: Interaction

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                // Every track canvas shares the ruler's width, so a local x maps the same everywhere.
                scrub(toX: v.location.x)
            }
    }

    @State private var trackWidth: CGFloat = 0

    private func scrub(toX px: CGFloat) {
        guard trackWidth > 0 else { return }
        let inset: CGFloat = 6
        let u = Double((px - inset) / max(trackWidth - inset * 2, 1))
        scrub(to: u * timeline.duration)
    }

    private func scrub(to t: Double) {
        playing = false
        let frame = (min(max(t, 0), timeline.duration) * timeline.fps).rounded() / timeline.fps
        playhead = frame
    }

    private func stop() { playing = false; playhead = nil }

    static func symbol(_ row: TimelineRows.Row) -> String {
        if row.label.hasPrefix("Packet") { return "circle.fill" }
        switch row.kind {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .diamond: return "diamond"
        case .text: return "textformat"
        case .connector: return "arrow.right"
        case .freehand: return "scribble"
        case .path: return "point.bottomleft.forward.to.point.topright.scurvepath"
        case .note: return "note.text"
        case .image: return "photo"
        }
    }
}
