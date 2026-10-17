import SwiftUI
import DottieKit

/// The selected instance's symbol: its name, how this copy plays it, and the ways into and out of it.
struct SymbolSection: View {
    @ObservedObject var document: DrawingDocument
    var instance: Element
    var undoManager: UndoManager?
    var onBreakApart: (Set<UUID>) -> Void

    private var symbol: Symbol? { instance.symbol.flatMap { document.model.symbolIndex[$0] } }

    var body: some View {
        Section("Symbol") {
            if let symbol {
                NameField(name: symbol.name) { name in
                    var next = document.model
                    next.renameSymbol(symbol.id, to: name)
                    document.commit(next, actionName: "Rename Symbol", undoManager: undoManager)
                }
                Picker("Plays", selection: playback) {
                    Text("Over and over").tag(SymbolPlayback.loop)
                    Text("Once").tag(SymbolPlayback.once)
                    Text("Stands still").tag(SymbolPlayback.still)
                }
                .disabled((symbol.timeline?.duration ?? 0) == 0)
                if (symbol.timeline?.duration ?? 0) > 0, playback.wrappedValue != .still {
                    Stepper(value: offset, in: 0...max(symbol.timeline?.duration ?? 0, 0.1), step: 0.1) {
                        LabeledContent("Starts", value: String(format: "%.1f s in", offset.wrappedValue))
                    }
                    .help("How far into the symbol's animation this copy is when the page's starts, so copies don't move in step")
                }
                LabeledContent("Instances", value: "\(document.model.elements.filter { $0.symbol == symbol.id }.count)")
                HStack {
                    Button("Edit Symbol") { document.editSymbol(of: instance.id) }
                        .help("Edit the symbol itself; every instance changes (double-click an instance to do the same)")
                    Button("Break Apart") {
                        var next = document.model
                        let parts = next.breakApart(instance.id)
                        document.commit(next, actionName: "Break Apart", undoManager: undoManager)
                        onBreakApart(parts)
                    }
                    .help("Replace this instance with plain copies of its shapes")
                }
            } else {
                Text("Its symbol is missing from this page.").foregroundStyle(.secondary)
            }
        }
    }

    private func set(_ name: String, _ change: @escaping (inout Element) -> Void) {
        var next = document.model
        guard let i = next.elements.firstIndex(where: { $0.id == instance.id }) else { return }
        change(&next.elements[i])
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    private var playback: Binding<SymbolPlayback> {
        Binding(get: { instance.playback ?? .loop },
                set: { p in set("Change Playback") { $0.playback = p == .loop ? nil : p } })
    }

    private var offset: Binding<Double> {
        Binding(get: { instance.offset ?? 0 },
                set: { o in set("Change Start") { let r = (o * 10).rounded() / 10; $0.offset = r == 0 ? nil : r } })
    }
}

/// A name committed on Return or when the field loses focus.
private struct NameField: View {
    var name: String
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
            .onAppear { text = name }
            .onChange(of: name) { _, n in if !focused { text = n } }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t != name { commit(t) }
    }
}
