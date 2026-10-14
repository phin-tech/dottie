import SwiftUI
import DottieKit

struct ContentView: View {
    @ObservedObject var document: DrawingDocument
    var fileURL: URL?
    @Environment(\.undoManager) var undoManager
    @Environment(\.controlActiveState) private var activeState
    @State private var tool: Tool = .select
    @State var selection: Set<UUID> = []
    @State private var newStyle = Style()
    @State private var newRouting: Routing = .straight
    @AppStorage(Pref.newStyle) private var storedStyle = ""
    @AppStorage(Pref.routing) private var prefRouting = Pref.routingDefault
    @State private var showInspector = true
    @State private var activeLayer: UUID?
    @State private var placeRequest: PlaceRequest?
    @State private var sidebarTab: SidebarTab = .inspector

    var body: some View {
        CanvasView(document: document, tool: $tool, selection: $selection, style: newStyle, routing: newRouting,
                   activeLayerID: activeLayer, placeRequest: $placeRequest)
            .frame(minWidth: 400)
            .inspector(isPresented: $showInspector) {
                VStack(spacing: 0) {
                    Picker("Sidebar", selection: $sidebarTab) {
                        ForEach(SidebarTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding([.horizontal, .top], 12)
                    switch sidebarTab {
                    case .inspector:
                        Inspector(document: document, selection: selection, tool: tool, newStyle: $newStyle, newRouting: $newRouting, activeLayer: $activeLayer, undoManager: undoManager)
                    case .library:
                        LibraryPanel(document: document, selection: selection) { item, keep in
                            placeRequest = PlaceRequest(item: item, keepOriginalColors: keep)
                        }
                    }
                }
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
                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .onChange(of: fileURL, initial: true) { _, url in
            LiveRegistry.shared.register(document, fileURL: url, undoManager: undoManager)
        }
        // A new window counts as current until another becomes key, so "current" works before first focus.
        .onAppear { LiveRegistry.shared.markFront(document, undoManager: undoManager) }
        .onChange(of: activeState) { _, state in
            if state == .key { LiveRegistry.shared.markFront(document, undoManager: undoManager) }
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

enum SidebarTab: String, CaseIterable, Identifiable {
    case inspector = "Inspector", library = "Library"
    var id: String { rawValue }
}

struct Inspector: View {
    @ObservedObject var document: DrawingDocument
    var selection: Set<UUID>
    var tool: Tool
    @Binding var newStyle: Style
    @Binding var newRouting: Routing
    @Binding var activeLayer: UUID?
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
            LayersSection(document: document, selection: selection, activeLayer: $activeLayer, undoManager: undoManager)
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
                Picker("Fill pattern", selection: binding(\.fillStyle, "Change Fill Pattern")) {
                    Text("Solid").tag(FillStyle.solid)
                    Text("Hachure").tag(FillStyle.hachure)
                    Text("Cross").tag(FillStyle.crossHatch)
                }
                .pickerStyle(.segmented)
                Picker("Line", selection: binding(\.dash, "Change Line Style")) {
                    Text("Solid").tag(DashStyle.solid)
                    Text("Dashed").tag(DashStyle.dashed)
                    Text("Dotted").tag(DashStyle.dotted)
                }
                .pickerStyle(.segmented)
                Slider(value: binding(\.bowing, "Change Bowing"), in: 0...3) { Text("Bowing") }
                    .disabled(binding(\.roughness, "").wrappedValue == 0)
            }
            if tool == .connector || !selectedConnectors.isEmpty {
                Section("Connector") {
                    Picker("Routing", selection: routingBinding) {
                        Text("Straight").tag(Routing.straight)
                        Text("Curved").tag(Routing.curved)
                        Text("Elbow").tag(Routing.elbow)
                    }
                    .pickerStyle(.segmented)
                    Picker("Start", selection: headBinding(\.startHead, "Change Start Arrowhead")) { headItems }
                    Picker("End", selection: headBinding(\.endHead, "Change End Arrowhead")) { headItems }
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

    @ViewBuilder private var headItems: some View {
        Text("None").tag(Arrowhead.none)
        Text("Arrow").tag(Arrowhead.arrow)
        Text("Triangle").tag(Arrowhead.triangle)
        Text("Dot").tag(Arrowhead.dot)
        Text("Bar").tag(Arrowhead.bar)
    }

    private func headBinding(_ kp: WritableKeyPath<ConnectorData, Arrowhead>, _ name: String) -> Binding<Arrowhead> {
        let fallback: Arrowhead = kp == \ConnectorData.endHead ? .arrow : .none
        return Binding(get: { selectedConnectors.first?.connector?[keyPath: kp] ?? fallback },
                       set: { v in editConnectors(name) { $0[keyPath: kp] = v } })
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

/// Add / hide / lock / rename / reorder layers. The highlighted layer receives new shapes.
struct LayersSection: View {
    @ObservedObject var document: DrawingDocument
    var selection: Set<UUID>
    @Binding var activeLayer: UUID?
    var undoManager: UndoManager?

    private var layers: [Layer] { document.model.layers }
    private var current: UUID { activeLayer.flatMap { id in layers.first { $0.id == id }?.id } ?? layers.last?.id ?? UUID() }

    private func edit(_ name: String, _ change: (inout DottieDocument) -> Void) {
        var next = document.model
        change(&next)
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    var body: some View {
        Section("Layers") {
            // Front-most layer first, like every layers panel.
            ForEach(layers.reversed()) { layer in
                LayerRow(layer: layer, isActive: layer.id == current,
                         count: document.model.elements.filter { $0.layerID == layer.id }.count,
                         select: { activeLayer = layer.id },
                         rename: { n in edit("Rename Layer") { $0.editLayer(layer.id) { $0.name = n } } },
                         toggleVisible: { edit("Toggle Layer Visibility") { $0.editLayer(layer.id) { $0.visible.toggle() } } },
                         toggleLocked: { edit("Toggle Layer Lock") { $0.editLayer(layer.id) { $0.locked.toggle() } } })
            }
            HStack {
                Button { edit("Add Layer") { activeLayer = $0.addLayer(above: current) } } label: { Image(systemName: "plus") }
                    .help("Add layer")
                Button { edit("Delete Layer") { if $0.removeLayer(current) { activeLayer = nil } } } label: { Image(systemName: "minus") }
                    .help("Delete layer (its shapes move to the layer below)")
                    .disabled(layers.count < 2)
                Button { edit("Move Layer Up") { $0.moveLayer(current, by: 1) } } label: { Image(systemName: "arrow.up") }
                    .help("Bring layer forward")
                Button { edit("Move Layer Down") { $0.moveLayer(current, by: -1) } } label: { Image(systemName: "arrow.down") }
                    .help("Send layer backward")
                Spacer()
                Button("Move selection here") { edit("Move to Layer") { $0.move(selection, toLayer: current) } }
                    .disabled(selection.isEmpty)
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct LayerRow: View {
    var layer: Layer
    var isActive: Bool
    var count: Int
    var select: () -> Void
    var rename: (String) -> Void
    var toggleVisible: () -> Void
    var toggleLocked: () -> Void
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleVisible) { Image(systemName: layer.visible ? "eye" : "eye.slash") }
                .help(layer.visible ? "Hide layer" : "Show layer")
            Button(action: toggleLocked) { Image(systemName: layer.locked ? "lock.fill" : "lock.open") }
                .help(layer.locked ? "Unlock layer" : "Lock layer")
            TextField("Layer", text: $name)
                .textFieldStyle(.plain)
                .onSubmit { if name != layer.name, !name.isEmpty { rename(name) } else { name = layer.name } }
            Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isActive ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onAppear { name = layer.name }
        .onChange(of: layer.name) { _, n in name = n }
        .opacity(layer.visible ? 1 : 0.55)
    }
}
