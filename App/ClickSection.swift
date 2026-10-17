import SwiftUI
import AppKit
import DottieKit

/// What clicking the selection does when the drawing plays on the web (Export Animation's web page and
/// `<dottie-player>`), and how it looks under the pointer there.
struct ClickSection: View {
    @ObservedObject var document: DrawingDocument
    var selection: Set<UUID>
    var undoManager: UndoManager?
    @Environment(\.colorScheme) private var colorScheme
    /// "Opens a link" is picked but no link typed yet: nothing is stored until there's a link to keep.
    @State private var choosingLink = false

    private enum Choice: Hashable { case none, scene(String), link }

    private var selected: [Element] { document.model.elements.filter { selection.contains($0.id) } }
    private var markers: [Marker] { document.model.timeline?.markers ?? [] }

    /// The click the selection shares, if every selected element has the same one.
    private var shared: ClickAction? {
        guard let first = selected.first?.click, selected.allSatisfy({ $0.click == first }) else { return nil }
        return first
    }

    var body: some View {
        Section("When Clicked on the Web") {
            Picker("Click", selection: choice) {
                Text("Does nothing").tag(Choice.none)
                if !markers.isEmpty { Divider() }
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in Text("Plays “\(m.name)”").tag(Choice.scene(m.name)) }
                if let name = shared?.scene, !markers.contains(where: { $0.name == name }) {
                    Text("Plays “\(name)” (missing)").tag(Choice.scene(name))
                }
                Divider()
                Text("Opens a link").tag(Choice.link)
            }
            .help(markers.isEmpty ? "Add Scene Marker names the moments a click can play from"
                  : "In the exported web page and <dottie-player>, a click plays this scene on to the next one")
            if choice.wrappedValue == .link {
                LinkField(url: shared?.url ?? "") { url in set(url.isEmpty ? nil : ClickAction(url: url), "Set Click Link") }
            }
            // A symbol's copy shows its button's over state instead (see the Symbol section).
            if shared != nil, !selected.contains(where: { $0.kind == .symbol }) {
                Toggle("Highlight on hover", isOn: hoverOn)
                if hoverOn.wrappedValue {
                    ColorPicker("Hover stroke", selection: hoverColor(\.stroke, fallback: \.stroke, "Change Hover Stroke"))
                    ColorPicker("Hover fill", selection: hoverColor(\.fill, fallback: \.fill, "Change Hover Fill"), supportsOpacity: true)
                }
            }
        }
        .onChange(of: selection) { _, _ in choosingLink = false }
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                if let c = shared {
                    if let s = c.scene, !s.isEmpty { return .scene(s) }
                    if c.url != nil { return .link }
                }
                return choosingLink ? .link : .none
            },
            set: { c in
                choosingLink = c == .link
                switch c {
                case .none: set(nil, "Remove Click")
                case .scene(let name): set(ClickAction(scene: name), "Click Plays Scene")
                case .link: if shared?.url == nil, shared != nil { set(nil, "Remove Click") }
                }
            })
    }

    private func set(_ click: ClickAction?, _ name: String) {
        edit(name) { e in
            e.click = click
            if click == nil || e.kind == .symbol { e.hover = nil }
        }
    }

    private func edit(_ name: String, _ change: (inout Element) -> Void) {
        var next = document.model
        for i in next.elements.indices where selection.contains(next.elements[i].id) { change(&next.elements[i]) }
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    private var hoverOn: Binding<Bool> {
        Binding(get: { selected.contains { !($0.hover?.isEmpty ?? true) } },
                set: { on in
                    edit(on ? "Highlight on Hover" : "Remove Hover Highlight") { e in
                        e.hover = on ? HoverLook(stroke: RGBA(r: 0.23, g: 0.51, b: 0.96)) : nil
                    }
                })
    }

    /// A hover color, showing the element's own color until one is picked.
    private func hoverColor(_ kp: WritableKeyPath<HoverLook, RGBA?>, fallback: KeyPath<Style, RGBA>, _ name: String) -> Binding<Color> {
        Binding(
            get: {
                guard let e = selected.first else { return .clear }
                var c = e.hover?[keyPath: kp] ?? e.style[keyPath: fallback]
                if c.isAutomaticInk { c = colorScheme == .dark ? .inkOnDark : .black }
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
            },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
                let c = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
                edit(name) { e in
                    var look = e.hover ?? HoverLook()
                    look[keyPath: kp] = c
                    e.hover = look
                }
            })
    }
}

/// A click's link, committed on Return or when the field loses focus, and only when it is one a page may open.
private struct LinkField: View {
    var url: String
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var invalid: Bool { !trimmed.isEmpty && ClickAction.allowed(trimmed) == nil }

    var body: some View {
        TextField("Link", text: $text, prompt: Text("https://…"))
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
            .onAppear { text = url }
            .onChange(of: url) { _, n in if !focused { text = n } }
        if invalid {
            Text("Use a link starting with https://, http:// or mailto:").font(.caption).foregroundStyle(.red)
        }
    }

    private func save() {
        guard !invalid, trimmed != url else { return }
        commit(trimmed)
    }
}
