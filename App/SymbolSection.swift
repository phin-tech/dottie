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
                CommitField(label: "Name", value: symbol.name) { name in
                    var next = document.model
                    next.renameSymbol(symbol.id, to: name)
                    document.commit(next, actionName: "Rename Symbol", undoManager: undoManager)
                }
                Toggle("Button", isOn: isButton)
                    .help("A Flash-style button: copies show its up scene; on the web, its over scene under the pointer, "
                          + "its down scene while pressed, and its hit scene's shapes take clicks. Edit Symbol to pose them")
                if symbol.isButton {
                    Text("Edit Symbol to draw its up, over and down scenes\(symbol.sceneTime(.hit) == nil ? ", and a hit scene to limit where it takes clicks" : "").")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Plays", selection: playback) {
                        Text("Over and over").tag(SymbolPlayback.loop)
                        Text("Once").tag(SymbolPlayback.once)
                        Text("Stands still").tag(SymbolPlayback.still)
                        Text("When clicked (web player)").tag(SymbolPlayback.click)
                    }
                    .disabled((symbol.timeline?.duration ?? 0) == 0)
                    .help("When clicked: rests at the start, and plays through once when clicked in <dottie-player>. "
                          + "Other exports show the start")
                }
                if !symbol.isButton, (symbol.timeline?.duration ?? 0) > 0, playback.wrappedValue != .still {
                    // Played once, a copy can also wait: a negative offset holds it at its start until then.
                    let wait = playback.wrappedValue == .once ? -(document.model.timeline?.duration ?? 0) : 0
                    Stepper(value: offset, in: wait...max(symbol.timeline?.duration ?? 0, 0.1), step: 0.1) {
                        LabeledContent("Starts", value: offset.wrappedValue < 0
                                       ? String(format: "after %.1f s", -offset.wrappedValue)
                                       : String(format: "%.1f s in", offset.wrappedValue))
                    }
                    .help("How far into the symbol's animation this copy is when the page's starts, so copies don't move "
                          + "in step. Played once, it can instead wait, to pop in later (a toast)")
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
        if let symbol, !(symbol.params ?? [:]).isEmpty || !symbol.placeholders.isEmpty {
            parameters(symbol)
        }
    }

    /// What this copy fills in: a field per parameter, its default as the placeholder. Under it, the symbol's own
    /// list: defaults to change, and names its text writes as {{name}} that it doesn't have yet, to add.
    @ViewBuilder private func parameters(_ symbol: Symbol) -> some View {
        let params = symbol.params ?? [:]
        let names = params.keys.sorted()
        let missing = symbol.placeholders.filter { params[$0] == nil }
        Section("Parameters") {
            ForEach(names, id: \.self) { name in
                CommitField(label: name, value: instance.args?[name] ?? "", prompt: params[name] ?? "", allowsEmpty: true) { v in
                    set("Change Parameter") { e in
                        var args = e.args ?? [:]
                        args[name] = v.isEmpty ? nil : v
                        e.args = args.isEmpty ? nil : args
                    }
                }
                    .help("This copy's \(name), shown where the symbol's text says {{\(name)}}; empty uses the default")
            }
            if !missing.isEmpty {
                Button("Add \(missing.map { "{{\($0)}}" }.joined(separator: ", "))") {
                    changeParams("Add Parameter") { p in for n in missing { p[n] = n } }
                }
                .help("Make the names the symbol's text writes in braces into parameters each copy can fill in")
            }
            if !names.isEmpty {
                DisclosureGroup("Defaults") {
                    ForEach(names, id: \.self) { name in
                        HStack {
                            CommitField(label: name, value: params[name] ?? "", allowsEmpty: true) { v in
                                changeParams("Change Default") { $0[name] = v }
                            }
                            Button { changeParams("Remove Parameter") { $0[name] = nil } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop \(name) being a parameter; {{\(name)}} then shows as written")
                        }
                    }
                }
            } else {
                Text("Write {{name}} in the symbol's text (Edit Symbol) for something each copy fills in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func changeParams(_ action: String, _ change: (inout [String: String]) -> Void) {
        var next = document.model
        guard let id = symbol?.id, let i = next.symbols?.firstIndex(where: { $0.id == id }) else { return }
        var p = next.symbols![i].params ?? [:]
        change(&p)
        next.symbols![i].params = p.isEmpty ? nil : p
        document.commit(next, actionName: action, undoManager: undoManager)
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

    private var isButton: Binding<Bool> {
        Binding(get: { symbol?.isButton ?? false },
                set: { on in
                    guard let id = symbol?.id else { return }
                    var next = document.model
                    if on { next.makeButton(id) }
                    else if let i = next.symbols?.firstIndex(where: { $0.id == id }) { next.symbols![i].button = nil }
                    document.commit(next, actionName: on ? "Make Button" : "Make Plain Symbol", undoManager: undoManager)
                })
    }

    private var offset: Binding<Double> {
        Binding(get: { instance.offset ?? 0 },
                set: { o in set("Change Start") { let r = (o * 10).rounded() / 10; $0.offset = r == 0 ? nil : r } })
    }
}

/// Text committed on Return or when the field loses focus, so typing makes one undo step. Empty is ignored unless
/// `allowsEmpty`.
private struct CommitField: View {
    var label: String
    var value: String
    var prompt = ""
    var allowsEmpty = false
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt))
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
    }

    private func save() {
        let t = allowsEmpty ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowsEmpty || !t.isEmpty, t != value { commit(t) }
    }
}
