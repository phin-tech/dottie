import SwiftUI
import DottieKit

/// A strip over the canvas with what the selection uses most, like Affinity's context toolbar: a shape's look,
/// colors, line and opacity; a connector's routing and ends; a symbol copy's playback. With nothing selected it
/// sets the style for new shapes. The inspector's tabs hold the rest.
struct ContextBar: View {
    @ObservedObject var document: DrawingDocument
    var style: SelectionStyle
    var tool: Tool
    var undoManager: UndoManager?

    private var selected: [Element] { style.selected }
    private var copy: Element? { selected.count == 1 && selected[0].kind == .symbol ? selected[0] : nil }
    private var onlyCopies: Bool { !selected.isEmpty && selected.allSatisfy { $0.kind == .symbol } }
    private var onlyNotes: Bool { tool == .note || (!selected.isEmpty && selected.allSatisfy { $0.kind == .note }) }
    private var showsConnector: Bool { tool == .connector && selected.isEmpty || !style.selectedConnectors.isEmpty }
    private var onlyConnectors: Bool { showsConnector && selected.allSatisfy { $0.kind == .connector } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Label(title, systemImage: icon)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                bar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        // A sideways scroll view has no height of its own; without one the bar collapses to nothing.
        .frame(height: 32)
        .controlSize(.small)
        .background(.bar)
    }

    @ViewBuilder private var bar: some View {
        if let copy, let symbol = copy.symbol.flatMap({ document.model.symbolIndex[$0] }) {
            BarDivider()
            if !symbol.isButton, (symbol.timeline?.duration ?? 0) > 0 {
                Picker("Plays", selection: playback(copy)) {
                    Text("Over and over").tag(SymbolPlayback.loop)
                    Text("Once").tag(SymbolPlayback.once)
                    Text("Stands still").tag(SymbolPlayback.still)
                    Text("When clicked").tag(SymbolPlayback.click)
                }
                .fixedSize()
            }
            Button("Edit Symbol") { document.editSymbol(of: copy.id) }
                .help("Edit the symbol itself; every copy changes")
        }
        if onlyCopies {
            BarDivider()
            opacity
        } else {
            BarDivider()
            Picker("Look", selection: style.look) {
                Text("Sketchy").tag(true)
                Text("Clean").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // Each part with its own color: the outline, the fill, the text.
            if !style.onlyTextBoxes {
                BarDivider()
                labeled("Stroke") {
                    ColorPicker("Stroke", selection: style.stroke).labelsHidden()
                    width
                    Picker("Line", selection: style.binding(\.dash, "Change Line Style")) {
                        ForEach(StyleChoices.dashes, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Line style")
                }
            }
            if onlyNotes {
                BarDivider()
                labeled("Fill") { NoteSwatches(fill: style.binding(\.fill, "Change Note Color")) }
            } else if style.hasFill && !onlyConnectors && !style.onlyTextBoxes {
                BarDivider()
                labeled("Fill") {
                    ColorPicker("Fill", selection: style.color(\.fill, "Change Fill Color"), supportsOpacity: true).labelsHidden()
                    Picker("Fill pattern", selection: style.binding(\.fillStyle, "Change Fill Pattern")) {
                        ForEach(StyleChoices.fills, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if style.hasText {
                BarDivider()
                labeled("Text") {
                    ColorPicker("Text", selection: style.text).labelsHidden()
                    if style.hasLabels && !style.onlyTextBoxes { followStroke }
                    FontMenu(font: style.binding(\.font, "Change Font"))
                    textSize
                }
            }
            BarDivider()
            opacity
        }
        if showsConnector {
            BarDivider()
            Picker("Routing", selection: style.routing) {
                ForEach(StyleChoices.routings, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            labeled("Ends") {
                Picker("Start", selection: style.head(\.startHead, "Change Start Arrowhead")) {
                    ForEach(StyleChoices.heads, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("End", selection: style.head(\.endHead, "Change End Arrowhead")) {
                    ForEach(StyleChoices.heads, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }


    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            content()
        }
    }

    /// Lit while labels take the stroke color; clicking it toggles that.
    private var followStroke: some View {
        let follows = style.textFollowsStroke
        return Button { follows.wrappedValue.toggle() } label: {
            Image(systemName: "link")
                .foregroundStyle(follows.wrappedValue ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(follows.wrappedValue ? "Text matches the stroke color; click to color it separately"
                                   : "Text has its own color; click to match the stroke again")
    }

    private static let widths: [Double] = [1, 1.5, 2, 3, 4, 6, 8, 12]
    private static let opacities: [Double] = [1, 0.75, 0.5, 0.25]

    private var width: some View {
        let w = style.binding(\.strokeWidth, "Change Stroke Width")
        return Menu(Inspector.points(w.wrappedValue)) {
            ForEach(Self.widths, id: \.self) { v in Button(Inspector.points(v)) { w.wrappedValue = v } }
        }
        .fixedSize()
        .help("Line width")
    }

    private var textSize: some View {
        let s = style.binding(\.fontSize, "Change Text Size")
        return Menu(Inspector.points(s.wrappedValue)) {
            ForEach(TextSizes.common, id: \.self) { v in Button(Inspector.points(v)) { s.wrappedValue = v } }
        }
        .fixedSize()
        .help("Text size")
    }

    private var opacity: some View {
        let o = style.binding(\.opacityLevel, "Change Opacity")
        return Menu(Inspector.percent(o.wrappedValue)) {
            ForEach(Self.opacities, id: \.self) { v in Button(Inspector.percent(v)) { o.wrappedValue = v } }
        }
        .fixedSize()
        .help("Opacity (the Style tab has a slider for any value)")
    }

    private func playback(_ copy: Element) -> Binding<SymbolPlayback> {
        Binding(get: { copy.playback ?? .loop },
                set: { p in
                    var next = document.model
                    guard let i = next.elements.firstIndex(where: { $0.id == copy.id }) else { return }
                    next.elements[i].playback = p == .loop ? nil : p
                    document.commit(next, actionName: "Change Playback", undoManager: undoManager)
                })
    }

    private var title: String {
        if selected.isEmpty { return tool == .connector ? "New arrows" : "New shapes" }
        if selected.count > 1 { return "\(selected.count) selected" }
        let e = selected[0]
        if let symbol = e.symbol.flatMap({ document.model.symbolIndex[$0] }) { return symbol.name }
        return e.displayTitle
    }

    private var icon: String {
        guard selected.count == 1 else { return selected.isEmpty ? "plus.square.dashed" : "square.on.square" }
        switch selected[0].kind {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .diamond: return "diamond"
        case .text: return "textformat"
        case .note: return "note.text"
        case .connector: return "arrow.right"
        case .freehand: return "scribble"
        case .path: return "scribble.variable"
        case .image: return "photo"
        case .symbol: return "square.on.square.dashed"
        }
    }
}
