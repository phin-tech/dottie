import SwiftUI
import DottieKit

struct ContentView: View {
    @ObservedObject var document: DrawingDocument
    @Environment(\.undoManager) private var undoManager
    @State private var tool: Tool = .select
    @State private var selection: Set<UUID> = []
    @State private var newStyle = Style()
    @State private var newRouting: Routing = .straight
    @Environment(\.colorScheme) private var colorScheme

    /// Default stroke for new shapes, so drawings are visible on the canvas in either appearance.
    private static func defaultStroke(_ scheme: ColorScheme) -> RGBA {
        scheme == .dark ? RGBA(r: 0.93, g: 0.93, b: 0.94) : .black
    }

    var body: some View {
        HSplitView {
            CanvasView(document: document, tool: $tool, selection: $selection, style: newStyle, routing: newRouting)
                .frame(minWidth: 400)
            Inspector(document: document, selection: selection, newStyle: $newStyle, newRouting: $newRouting, undoManager: undoManager)
                .frame(width: 220)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases) { t in
                        Image(systemName: t.symbol).tag(t)
                            .help("\(t.label) (\(String(t.shortcut).uppercased()))")
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .onChange(of: colorScheme, initial: true) { old, new in
            // Only follow the appearance while the stroke is still an untouched default.
            if newStyle.stroke == .black || newStyle.stroke == Self.defaultStroke(old) {
                newStyle.stroke = Self.defaultStroke(new)
            }
        }
    }
}

struct Inspector: View {
    @ObservedObject var document: DrawingDocument
    var selection: Set<UUID>
    @Binding var newStyle: Style
    @Binding var newRouting: Routing
    var undoManager: UndoManager?

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
                Slider(value: binding(\.roughness, "Change Roughness"), in: 0...3) { Text("Sketchiness") }
                    .disabled(binding(\.roughness, "").wrappedValue == 0)
                Slider(value: binding(\.strokeWidth, "Change Stroke Width"), in: 1...12) { Text("Stroke") }
                ColorPicker("Stroke", selection: colorBinding(\.stroke, "Change Stroke Color"))
                ColorPicker("Fill", selection: colorBinding(\.fill, "Change Fill Color"), supportsOpacity: true)
            }
            Section("Connector") {
                Picker("Routing", selection: routingBinding) {
                    Text("Straight").tag(Routing.straight)
                    Text("Curved").tag(Routing.curved)
                    Text("Elbow").tag(Routing.elbow)
                }
                .pickerStyle(.segmented)
                Toggle("Arrowhead", isOn: arrowBinding)
            }
            Section("Layers") {
                ForEach(document.model.layers) { Text($0.name) }
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
            get: { let c = raw.wrappedValue; return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
                raw.wrappedValue = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
            })
    }
}
