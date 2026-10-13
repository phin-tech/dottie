import SwiftUI
import DottieKit

struct ContentView: View {
    @ObservedObject var document: DrawingDocument
    @Environment(\.undoManager) var undoManager
    @State private var tool: Tool = .select
    @State var selection: Set<UUID> = []
    @State private var newStyle = Style()
    @State private var newRouting: Routing = .straight
    @AppStorage(Pref.newStyle) private var storedStyle = ""
    @AppStorage(Pref.routing) private var prefRouting = Pref.routingDefault
    @State private var showInspector = true

    var body: some View {
        CanvasView(document: document, tool: $tool, selection: $selection, style: newStyle, routing: newRouting)
            .frame(minWidth: 400)
            .inspector(isPresented: $showInspector) {
                Inspector(document: document, selection: selection, tool: tool, newStyle: $newStyle, newRouting: $newRouting, undoManager: undoManager)
                    .inspectorColumnWidth(min: 250, ideal: 270, max: 360)
            }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases) { t in
                        Image(systemName: t.symbol)
                            .accessibilityLabel(t.label)
                            .tag(t)
                            .help("\(t.label) (\(String(t.shortcut).uppercased()))")
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation(.snappy) { showInspector.toggle() } } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .focusedSceneValue(\.tool, $tool)
        .focusedSceneValue(\.editor, editorActions)
        .frame(minWidth: 700, minHeight: 480)
        // The inspector edits `newStyle`; remember it across launches, and pick up Settings' reset.
        .onChange(of: storedStyle, initial: true) { _, json in
            let style = Pref.decodeStyle(json) ?? Style()
            if style != newStyle { newStyle = style }
        }
        .onChange(of: newStyle) { _, style in storedStyle = Pref.encode(style) }
        .onChange(of: prefRouting, initial: true) { _, v in newRouting = Routing(rawValue: v) ?? .straight }
        .onChange(of: newRouting) { _, r in prefRouting = r.rawValue }
    }
}

struct Inspector: View {
    @ObservedObject var document: DrawingDocument
    var selection: Set<UUID>
    var tool: Tool
    @Binding var newStyle: Style
    @Binding var newRouting: Routing
    var undoManager: UndoManager?
    @Environment(\.colorScheme) private var colorScheme

    private var selected: [Element] { document.model.elements.filter { selection.contains($0.id) } }

    /// Edits the selection when there is one, otherwise the style used for new shapes.
    private func binding<T>(_ kp: WritableKeyPath<Style, T>, _ name: String) -> Binding<T> {
        Binding(
            get: { selected.first?.style[keyPath: kp] ?? newStyle[keyPath: kp] },
            set: { value in
                newStyle[keyPath: kp] = value
                guard !selection.isEmpty else { return }
                var next = document.model
                for i in next.elements.indices where selection.contains(next.elements[i].id) {
                    next.elements[i].style[keyPath: kp] = value
                }
                document.commit(next, actionName: name, undoManager: undoManager)
            })
    }

    var body: some View {
        Form {
            Section("Style") {
                Picker("Look", selection: lookBinding) {
                    Text("Sketchy").tag(true)
                    Text("Clean").tag(false)
                }
                .pickerStyle(.segmented)
                Slider(value: binding(\.roughness, "Change Roughness"), in: 0...3) { Text("Roughness") }
                    .disabled(binding(\.roughness, "").wrappedValue == 0)
                Slider(value: binding(\.strokeWidth, "Change Stroke Width"), in: 1...12) { Text("Width") }
                ColorPicker("Stroke", selection: colorBinding(\.stroke, "Change Stroke Color"))
                ColorPicker("Fill", selection: colorBinding(\.fill, "Change Fill Color"), supportsOpacity: true)
            }
            if tool == .connector || !selectedConnectors.isEmpty {
                Section("Connector") {
                    Picker("Routing", selection: routingBinding) {
                        Text("Straight").tag(Routing.straight)
                        Text("Curved").tag(Routing.curved)
                        Text("Elbow").tag(Routing.elbow)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Arrowhead", isOn: arrowBinding)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var selectedConnectors: [Element] { selected.filter { $0.kind == .connector } }

    private func editConnectors(_ name: String, _ change: (inout ConnectorData) -> Void) {
        var next = document.model
        for i in next.elements.indices where selection.contains(next.elements[i].id) {
            if var c = next.elements[i].connector { change(&c); next.elements[i].connector = c }
        }
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    private var routingBinding: Binding<Routing> {
        Binding(get: { selectedConnectors.first?.connector?.routing ?? newRouting },
                set: { r in newRouting = r; if !selectedConnectors.isEmpty { editConnectors("Change Routing") { $0.routing = r } } })
    }

    private var arrowBinding: Binding<Bool> {
        Binding(get: { selectedConnectors.first?.connector?.endArrow ?? true },
                set: { v in editConnectors("Toggle Arrowhead") { $0.endArrow = v } })
    }

    /// Sketchy (roughness 1) vs clean (0); the slider fine-tunes sketchy.
    private var lookBinding: Binding<Bool> {
        let r = binding(\.roughness, "Change Look")
        return Binding(get: { r.wrappedValue > 0 }, set: { r.wrappedValue = $0 ? 1 : 0 })
    }

    private func colorBinding(_ kp: WritableKeyPath<Style, RGBA>, _ name: String) -> Binding<Color> {
        let raw = binding(kp, name)
        return Binding(
            get: { var c = raw.wrappedValue
                if c.isAutomaticInk { c = colorScheme == .dark ? .inkOnDark : .black }
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
                raw.wrappedValue = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
            })
    }
}
