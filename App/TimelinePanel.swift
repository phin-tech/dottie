import SwiftUI
import DottieKit

/// The timeline under an animated page's canvas, Flash-style: a row per animated element, grouped by layer,
/// with its keyframes (diamonds) and what happens between them (bars), under a ruler and a playhead.
/// Dragging anywhere on the ruler or rows scrubs. While playing, the canvas shows the frame at `playhead`
/// and takes no edits; paused there, edits on the canvas pose that frame (they become keyframes). Done (or
/// Esc) goes back to editing the page itself. Clicking a row's name selects that element.
///
/// Keys are edited here too: click a diamond to select it (the playhead jumps there), drag it to retime it
/// (Option-drag copies it), and change its ease or delete it from the header or by right-clicking it.
/// Right-clicking the ruler adds a scene marker there, or renames (in a popover under its flag) or deletes the one
/// under the pointer; the flag in the header adds one at the playhead.
struct TimelinePanel: View {
    let page: DottieDocument
    @Binding var playhead: Double?
    @Binding var playing: Bool
    @Binding var selectedKey: KeyRef?
    var onSelect: (UUID) -> Void
    /// Applies a change to the page's timeline as one undo step, named for the Edit menu.
    var onEdit: (String, (inout Timeline) -> Void) -> Void
    /// Renames the scene at a time, with the clicks that play it.
    var onRenameScene: (Double, String) -> Void
    /// A key being dragged: drawn at `to` until the drag ends, then moved (or copied) there in one step.
    @State private var keyDrag: KeyDrag?
    @State private var scrubbing = false
    @AppStorage("timelineCollapsed") private var collapsed = false
    /// The most the rows may take, set by dragging the panel's top edge; fewer rows take less.
    @AppStorage("timelineHeight") private var rowsHeight = 200.0
    /// The rows' height when a resize began.
    @State private var resizeFrom: CGFloat?
    @State private var collapsedLayers: Set<UUID> = []
    /// What the pointer is over in the ruler or a track, for their context menus, which aren't told where the
    /// right-click was.
    @State private var pointer = Pointer()
    /// The time under the pointer. A reference, not state: it changes every few points, and redrawing the
    /// panel that often would be wasted, since only the menus' actions read it.
    @State private var pointerTime = PointerTime()
    /// The scene whose name is being edited in the popover under its flag.
    @State private var renamingScene: Marker?

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
        .overlay(alignment: .top) { if !collapsed { resizeHandle } }
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
            DisclosureButton(isExpanded: !collapsed, expandHelp: "Show Timeline", collapseHelp: "Hide Timeline") {
                collapsed.toggle()
            }
            IconButton(playing ? "pause.fill" : "play.fill", help: playing ? "Pause" : "Play") {
                if playhead == nil { playhead = 0 }
                playing.toggle()
            }
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
            BarDivider()
            IconButton("flag", help: "Add Scene Marker at the Playhead") { addScene(at: playhead ?? 0) }
            if let markers = timeline.markers, !markers.isEmpty {
                sceneControls(markers)
            }
            if let k = selectedKey, let key = timeline.key(of: k.element, at: k.t) {
                keyControls(k, key)
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

    /// Back and next between scenes, with the current scene's name.
    @ViewBuilder
    private func sceneControls(_ markers: [Marker]) -> some View {
        let t = playhead ?? 0
        let current = markers.last { $0.t <= t + 1e-6 }
        IconButton("backward.end.fill", help: "Previous Scene") { scrub(to: markers.last { $0.t < t - 1e-6 }?.t ?? 0) }
        Text(current?.name ?? "Start").lineLimit(1).frame(maxWidth: 140)
        IconButton("forward.end.fill", help: "Next Scene") {
            if let next = markers.first(where: { $0.t > t + 1e-6 }) { scrub(to: next.t) }
        }
    }

    /// The selected key's ease and a delete button.
    @ViewBuilder
    private func keyControls(_ k: KeyRef, _ key: Keyframe) -> some View {
        BarDivider()
        Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor)
        Text("\(key.t.formatted(.number.precision(.fractionLength(1))))s").monospacedDigit().foregroundStyle(.secondary)
        Picker("Ease", selection: Binding(get: { key.ease ?? .linear }, set: { e in
            onEdit("Set Ease") { $0.setEase(e, of: k.element, at: k.t) }
        })) {
            ForEach(Ease.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("How it moves from this key to the next")
        IconButton("trash", help: "Delete Key") { deleteSelectedKey() }
    }

    private func deleteSelectedKey() {
        guard let k = selectedKey else { return }
        deleteKey(k)
    }

    private func deleteKey(_ k: KeyRef) {
        onEdit("Delete Key") { $0.removeKey(of: k.element, at: k.t) }
        if selectedKey == k { selectedKey = nil }
    }

    /// Adds a scene at `t`; beeps if there is one there already.
    private func addScene(at t: Double) {
        var probe = timeline
        guard probe.addScene(at: t) else { NSSound.beep(); return }
        onEdit("Add Scene") { $0.addScene(at: t) }
    }

    private func renameScene(_ m: Marker) { renamingScene = m }

    /// The scene's name under its flag. Clicks find scenes by name, so two may not share one, in any case.
    private func sceneRenamer(_ m: Marker) -> some View {
        NamePopover(title: "Rename Scene", systemImage: "flag.fill", tint: .orange, name: m.name, placeholder: "Scene name",
                    hint: "Clicks that play it follow the new name.",
                    problem: { name in
                        if name.isEmpty { return "A scene needs a name." }
                        let taken = rows.markers.contains { $0.t != m.t && $0.name.caseInsensitiveCompare(name) == .orderedSame }
                        return taken ? "Another scene is called that." : nil
                    }) { onRenameScene(m.t, $0) }
    }

    static func title(_ e: Ease) -> String {
        switch e {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In and Out"
        case .hold: "Hold"
        case .spring: "Spring"
        case .bounce: "Bounce"
        case .elastic: "Elastic"
        }
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
            .frame(height: 18)   // a vertical Divider takes all the height it is offered
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if !rows.camera.isEmpty { cameraRow }
                    ForEach(groups) { group in
                        layerHeader(group)
                        if !collapsedLayers.contains(group.layer) {
                            ForEach(group.rows) { row in rowView(row) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)   // keeps every row exactly as wide as the ruler they scrub against
            .frame(height: shownHeight(rows: count + (rows.camera.isEmpty ? 0 : 1)))
        }
    }

    private static func clamp(_ h: Double) -> Double { min(max(h, 44), 800) }

    /// The rows' height: all of them, up to the height dragged to.
    private func shownHeight(rows: Int) -> CGFloat {
        min(CGFloat(rows) * rowHeight, CGFloat(Self.clamp(rowsHeight)))
    }

    /// The panel's top edge: drag it up or down to give the rows more or less room.
    private var resizeHandle: some View {
        let count = rows.groups.reduce(0) { $0 + 1 + (collapsedLayers.contains($1.layer) ? 0 : $1.rows.count) }
            + (rows.camera.isEmpty ? 0 : 1)
        return Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    // Start from what is shown, so a cap above the rows' own height doesn't make the drag lag.
                    let from = resizeFrom ?? shownHeight(rows: count)
                    resizeFrom = from
                    rowsHeight = Self.clamp(Double(from - g.translation.height))
                }
                .onEnded { _ in resizeFrom = nil })
            .help("Drag to resize the timeline")
    }

    /// The camera's keys, with bars where it moves between them.
    private var cameraRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "camera").frame(width: 14).foregroundStyle(.secondary)
                Text("Camera").lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .font(.caption.weight(.semibold))
            .frame(width: labelWidth, height: rowHeight)
            Divider()
            Canvas { ctx, size in
                let mid = size.height / 2, keys = rows.camera
                for (a, b) in zip(keys, keys.dropFirst()) {
                    ctx.fill(Path(roundedRect: CGRect(x: x(a, size.width), y: mid - 3, width: x(b, size.width) - x(a, size.width), height: 6),
                                  cornerRadius: 3), with: .color(.teal.opacity(0.5)))
                }
                for t in keys {
                    let c = CGPoint(x: x(t, size.width), y: mid)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)), with: .color(.teal))
                }
                if let p = playhead { drawPlayhead(&ctx, size: size, at: p, head: false) }
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture)
            .onContinuousHover { if case .active(let p) = $0 { point(at: p.x, camera: true) } }
            .contextMenu {
                if let t = pointer.key {
                    Button("Delete Camera Key") { onEdit("Delete Camera Key") { tl in tl.camera?.removeAll { abs($0.t - t) < 1e-6 } } }
                }
                Button("Remove Camera") { onEdit("Remove Camera") { $0.camera = nil } }
            }
        }
        .frame(height: rowHeight)
        .background(Color.primary.opacity(0.04))
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
            // Scene markers: a small flag at each, under the ticks' labels.
            for m in rows.markers {
                let mx = x(m.t, size.width)
                var flag = Path()
                flag.move(to: CGPoint(x: mx, y: size.height)); flag.addLine(to: CGPoint(x: mx, y: 3))
                flag.addLine(to: CGPoint(x: mx + 7, y: 6)); flag.addLine(to: CGPoint(x: mx, y: 9))
                ctx.stroke(flag, with: .color(.orange), lineWidth: 1.2)
            }
            if let p = playhead { drawPlayhead(&ctx, size: size, at: p, head: true) }
        }
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        .onContinuousHover { if case .active(let p) = $0 { point(at: p.x) } }
        .contextMenu { rulerMenu }
        .popover(isPresented: Binding(get: { renamingScene != nil }, set: { if !$0 { renamingScene = nil } }),
                 attachmentAnchor: .rect(.rect(CGRect(x: renamingScene.map { x($0.t, trackWidth) } ?? 0, y: 0, width: 8, height: 18))),
                 arrowEdge: .bottom) { if let m = renamingScene { sceneRenamer(m) } }
    }

    /// The scene under the pointer, or adding one there.
    @ViewBuilder private var rulerMenu: some View {
        if let t = pointer.marker, let m = rows.markers.first(where: { $0.t == t }) {
            Button("Go to “\(m.name)”") { scrub(to: m.t) }
            Button("Rename Scene…") { renameScene(m) }
            Divider()
            Button("Delete Scene") { onEdit("Delete Scene") { $0.removeMarker(at: m.t) } }
        } else {
            Button("Add Scene Marker Here") { addScene(at: pointerTime.t) }
        }
    }

    private func layerHeader(_ group: TimelineRows.Group) -> some View {
        let closed = collapsedLayers.contains(group.layer)
        return HStack(spacing: 4) {
            DisclosureChevron(isExpanded: !closed)
                .font(.system(size: 9, weight: .semibold))
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
                .gesture(rowGesture(row))
                .onContinuousHover { if case .active(let p) = $0 { point(at: p.x, row: row) } }
                .contextMenu { rowMenu(row) }
        }
        .frame(height: rowHeight)
    }

    /// The key under the pointer, if it is over one of this row's; then the element and adding a scene there.
    @ViewBuilder private func rowMenu(_ row: TimelineRows.Row) -> some View {
        if pointer.element == row.element, let t = pointer.key, let key = timeline.key(of: row.element, at: t) {
            let k = KeyRef(element: row.element, t: key.t)
            Picker("Ease", selection: Binding(get: { key.ease ?? .linear }, set: { e in
                selectedKey = k
                onEdit("Set Ease") { $0.setEase(e, of: k.element, at: k.t) }
            })) {
                ForEach(Ease.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            Button("Delete Key") { deleteKey(k) }
            Divider()
        }
        Button("Select \(row.label)") { onSelect(row.element) }
        Button("Add Scene Marker Here") { addScene(at: pointerTime.t) }
        Divider()
        Button("Clear Keys") {
            if selectedKey?.element == row.element { selectedKey = nil }
            onEdit("Clear Keys") { $0.tracks.removeAll { $0.element == row.element } }
        }
    }

    /// Notes what is under the pointer at `px` in the ruler (no row), a row's track or the camera's, changing state
    /// only when that changes so hovering doesn't redraw the panel at every pixel.
    private func point(at px: CGFloat, row: TimelineRows.Row? = nil, camera: Bool = false) {
        pointerTime.t = time(atX: px)
        var p = Pointer(element: row?.element)
        if let row { p.key = nearestKey(in: row, x: px)?.t }
        else if camera { p.key = rows.camera.first { abs(x($0, trackWidth) - px) <= 7 } }
        else { p.marker = rows.markers.min { abs(x($0.t, trackWidth) - px) < abs(x($1.t, trackWidth) - px) }
            .flatMap { abs(x($0.t, trackWidth) - px) <= 6 ? $0.t : nil } }
        if p != pointer { pointer = p }
    }

    /// The row's key within 7 points of `px`, the nearest if several are.
    private func nearestKey(in row: TimelineRows.Row, x px: CGFloat) -> TimelineRows.Mark? {
        guard let k = row.keys.min(by: { abs(x($0.t, trackWidth) - px) < abs(x($1.t, trackWidth) - px) }),
              abs(x(k.t, trackWidth) - px) <= 7 else { return nil }
        return k
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
            case .repeating(let count):
                // A bracket under the row, labelled with how many times (∞ for forever).
                var p = Path()
                p.move(to: CGPoint(x: a, y: size.height - 6)); p.addLine(to: CGPoint(x: a, y: size.height - 2))
                p.addLine(to: CGPoint(x: b, y: size.height - 2)); p.addLine(to: CGPoint(x: b, y: size.height - 6))
                ctx.stroke(p, with: .color(.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                ctx.draw(Text(count.map { "↻ \($0)×" } ?? "↻ ∞").font(.system(size: 8)).foregroundStyle(Color.accentColor),
                         at: CGPoint(x: b - 2, y: 1), anchor: .topTrailing)
            }
        }
        let dragging = keyDrag.flatMap { $0.element == row.element ? $0 : nil }
        var marks = row.keys
        if let d = dragging, let i = marks.firstIndex(where: { abs($0.t - d.from) < 0.5 / timeline.fps }) {
            var moved = marks[i]
            moved.t = d.to
            if d.copy { marks.append(moved) } else { marks[i] = moved }
        }
        for key in marks {
            let c = CGPoint(x: x(key.t, size.width), y: mid)
            let selected = dragging.map { abs(key.t - $0.to) < 1e-9 }
                ?? selectedKey.map { $0.element == row.element && abs($0.t - key.t) < 0.5 / timeline.fps } ?? false
            let r: CGFloat = selected ? 6 : 4.5
            var d = Path()
            d.move(to: CGPoint(x: c.x, y: c.y - r)); d.addLine(to: CGPoint(x: c.x + r, y: c.y))
            d.addLine(to: CGPoint(x: c.x, y: c.y + r)); d.addLine(to: CGPoint(x: c.x - r, y: c.y)); d.closeSubpath()
            // Selected: accent, a size up. Hollow when the key only shows or hides the element.
            if selected {
                ctx.fill(d, with: .color(.accentColor))
                ctx.stroke(d, with: .color(.white.opacity(0.9)), lineWidth: 1)
            } else if key.sets == [.visibility] {
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

    /// On a key: select it on click, retime it on drag (Option copies it). Elsewhere: scrub.
    private func rowGesture(_ row: TimelineRows.Row) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if keyDrag == nil, !scrubbing {
                    if let k = nearestKey(in: row, x: v.startLocation.x) {
                        keyDrag = KeyDrag(element: row.element, from: k.t, to: k.t,
                                          copy: NSEvent.modifierFlags.contains(.option))
                    } else {
                        scrubbing = true
                        selectedKey = nil
                    }
                }
                if var d = keyDrag { d.to = time(atX: v.location.x); keyDrag = d } else { scrub(toX: v.location.x) }
            }
            .onEnded { _ in
                defer { keyDrag = nil; scrubbing = false }
                guard let d = keyDrag else { return }
                if abs(d.to - d.from) >= 0.5 / timeline.fps {
                    onEdit(d.copy ? "Copy Key" : "Move Key") { $0.moveKey(of: d.element, from: d.from, to: d.to, copy: d.copy) }
                }
                selectedKey = KeyRef(element: d.element, t: d.to)
                scrub(to: d.to)
            }
    }

    /// The frame time under a point in a track, clamped to the timeline.
    private func time(atX px: CGFloat) -> Double {
        let inset: CGFloat = 6
        let u = Double((px - inset) / max(trackWidth - inset * 2, 1))
        let t = min(max(u * timeline.duration, 0), timeline.duration)
        return (t * timeline.fps).rounded() / timeline.fps
    }

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
        case .symbol: return "square.on.square.dashed"
        }
    }
}

/// A key picked in the timeline: the element's key at time `t`.
struct KeyRef: Equatable {
    var element: UUID
    var t: Double
}

/// What the pointer is over in the timeline: in a track the key there, or on the ruler the scene.
private struct Pointer: Equatable {
    var element: UUID?
    var key: Double?
    var marker: Double?
}

/// The time under the pointer in the timeline.
private final class PointerTime {
    var t = 0.0
}

/// A key being dragged in the timeline.
private struct KeyDrag: Equatable {
    var element: UUID
    var from: Double
    var to: Double
    var copy: Bool
}
