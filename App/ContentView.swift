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
    @AppStorage(Pref.showRulers) private var showRulers = false
    @State private var activeLayer: UUID?
    @State private var placeRequest: PlaceRequest?
    @State private var jumpRequest: JumpRequest?
    @State private var sidebarTab: SidebarTab = .inspector
    @State var showScriptConsole = false
    @State var scriptOutput = ""
    @State var scriptRunning = false
    @AppStorage(Pref.scriptSource) var scriptSource = ""

    var body: some View {
        VStack(spacing: 0) {
            CanvasView(document: document, tool: $tool, selection: $selection, style: newStyle, routing: newRouting,
                       activeLayerID: activeLayer, placeRequest: $placeRequest, showRulers: showRulers, jumpRequest: $jumpRequest)
            Divider()
            PageBar(document: document, undoManager: undoManager)
        }
            .frame(minWidth: 400)
            .onChange(of: document.currentPageID) { _, _ in
                // Keep only what is on the new page: a link picked on another page brings its sources back selected.
                selection = selection.intersection(document.model.elements.map(\.id))
                activeLayer = nil
            }
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
                        Inspector(document: document, selection: selection, tool: tool, newStyle: $newStyle, newRouting: $newRouting, activeLayer: $activeLayer, undoManager: undoManager,
                                  onSelect: { selection = $0 }, onJump: { jumpRequest = JumpRequest(target: $0) })
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
        .sheet(isPresented: $showScriptConsole) {
            ScriptConsole(source: $scriptSource, output: $scriptOutput, selectionCount: selection.count,
                          running: scriptRunning, run: runScript)
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
    var onSelect: (Set<UUID>) -> Void = { _ in }
    var onJump: (UUID) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Pref.showRulers) private var showRulers = false

    private var themeBinding: Binding<String> {
        Binding(get: { document.model.theme ?? "" },
                set: { id in
                    var next = document.model
                    next.theme = id.isEmpty ? nil : id
                    document.commit(next, actionName: "Change Theme", undoManager: undoManager)
                })
    }

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
            LayersSection(document: document, selection: selection, activeLayer: $activeLayer, undoManager: undoManager,
                          onSelect: onSelect)
            Section("Canvas") {
                Picker("Theme", selection: themeBinding) {
                    Text("Automatic").tag("")
                    ForEach(Theme.all) { t in Text(t.name).tag(t.id) }
                }
                Toggle("Rulers and guides", isOn: $showRulers)
                if showRulers { GuidesEditor(document: document, undoManager: undoManager) }
            }
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
            if selected.count == 1, let e = selected.first {
                Section("Element") {
                    AnchorField(element: e) { anchor in
                        var next = document.model
                        guard let i = next.elements.firstIndex(where: { $0.id == e.id }) else { return }
                        next.elements[i].anchor = anchor.isEmpty ? nil : anchor
                        document.commit(next, actionName: "Set Anchor", undoManager: undoManager)
                    }
                }
            }
            if !selected.isEmpty {
                Section("Link") {
                    Picker("Jumps to", selection: linkBinding) {
                        Text("None").tag(UUID?.none)
                        if let id = selectedLink, !linkTargets.contains(where: { $0.id == id }) {
                            Text(linkTitle(id) ?? "Missing element").tag(UUID?.some(id))
                        }
                        ForEach(linkTargets) { t in Text(t.title).tag(UUID?.some(t.id)) }
                    }
                    .help("Click the badge beside the shape, or ⌘-click the shape, to go there")
                    if let id = selectedLink {
                        Button("Go") { onJump(id) }
                    }
                }
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

    private static let linkTargetLimit = 200

    /// The link the selection shares, if every selected element has the same one.
    private var selectedLink: UUID? {
        guard let first = selected.first?.link, selected.allSatisfy({ $0.link == first }) else { return nil }
        return first
    }

    private struct LinkTarget: Identifiable { var id: UUID; var title: String }

    /// Shapes with an anchor or text, outside the selection, by title: what a link can point at. This page's
    /// come first; other pages' follow in tab order, prefixed with the page name.
    private var linkTargets: [LinkTarget] {
        let here = document.model.id
        let pages = [document.model] + document.file.pages.filter { $0.id != here }
        var out: [LinkTarget] = []
        for page in pages {
            let prefix = page.id == here ? "" : page.name + " › "
            out += page.elements
                .filter { $0.kind != .connector && !selection.contains($0.id) && !(($0.anchor ?? $0.text) ?? "").isEmpty }
                .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
                .map { LinkTarget(id: $0.id, title: prefix + $0.displayTitle) }
            if out.count >= Self.linkTargetLimit { break }
        }
        return Array(out.prefix(Self.linkTargetLimit))
    }

    /// The title of an element anywhere in the file, with its page name when it is not on this page.
    private func linkTitle(_ id: UUID) -> String? {
        guard let i = document.file.pageIndex(containing: id), let e = document.file.pages[i].elements.first(where: { $0.id == id })
        else { return nil }
        let page = document.file.pages[i]
        return page.id == document.model.id ? e.displayTitle : page.name + " › " + e.displayTitle
    }

    private var linkBinding: Binding<UUID?> {
        Binding(get: { selectedLink },
                set: { target in
                    var next = document.model
                    guard (try? next.setLink(selection, to: target, otherPages: document.file.pages)) != nil else { return }
                    document.commit(next, actionName: target == nil ? "Remove Link" : "Link", undoManager: undoManager)
                })
    }

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

/// Guides by number: type a position, add one at an exact place, delete, or lock them all.
struct GuidesEditor: View {
    @ObservedObject var document: DrawingDocument
    var undoManager: UndoManager?
    @State private var newValue = 0.0

    private func edit(_ name: String, _ change: (inout DottieDocument) -> Void) {
        var next = document.model
        change(&next)
        if next.guidesX?.isEmpty == true { next.guidesX = nil }
        if next.guidesY?.isEmpty == true { next.guidesY = nil }
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    private func row(_ title: String, vertical: Bool, index: Int, value: Double) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
            TextField("", value: Binding(get: { value }, set: { v in
                edit("Move Guide") { vertical ? ($0.guidesX?[index] = v) : ($0.guidesY?[index] = v) }
            }), format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder)
            .disabled(document.model.guidesLocked == true)
            Button { edit("Remove Guide") { vertical ? ($0.guidesX?.remove(at: index)) : ($0.guidesY?.remove(at: index)) } } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove guide")
        }
    }

    var body: some View {
        let xs = document.model.guidesX ?? [], ys = document.model.guidesY ?? []
        Toggle("Lock guides", isOn: Binding(get: { document.model.guidesLocked == true },
                                            set: { on in edit(on ? "Lock Guides" : "Unlock Guides") { $0.guidesLocked = on ? true : nil } }))
        ForEach(Array(xs.enumerated()), id: \.offset) { i, v in row("X", vertical: true, index: i, value: v) }
        ForEach(Array(ys.enumerated()), id: \.offset) { i, v in row("Y", vertical: false, index: i, value: v) }
        HStack {
            TextField("Position", value: $newValue, format: .number).textFieldStyle(.roundedBorder)
            Button("X") { edit("Add Guide") { $0.guidesX = ($0.guidesX ?? []) + [newValue] } }.help("Add a vertical guide at this x")
            Button("Y") { edit("Add Guide") { $0.guidesY = ($0.guidesY ?? []) + [newValue] } }.help("Add a horizontal guide at this y")
        }
        .disabled(document.model.guidesLocked == true)
        if !xs.isEmpty || !ys.isEmpty {
            Button("Clear Guides") { edit("Clear Guides") { $0.guidesX = nil; $0.guidesY = nil } }
                .disabled(document.model.guidesLocked == true)
        }
    }
}

/// Add / hide / lock / rename / reorder layers. The highlighted layer receives new shapes. Each layer
/// unfolds to its elements, front first; drag elements onto another element to restack them, or onto
/// a layer to move them there.
struct LayersSection: View {
    @ObservedObject var document: DrawingDocument
    var selection: Set<UUID>
    @Binding var activeLayer: UUID?
    var undoManager: UndoManager?
    var onSelect: (Set<UUID>) -> Void
    @State private var expanded: Set<UUID> = []

    private static let dragPrefix = "dottie-elements:"
    private static let rowLimit = 300

    private var layers: [Layer] { document.model.layers }
    private var current: UUID { activeLayer.flatMap { id in layers.first { $0.id == id }?.id } ?? layers.last?.id ?? UUID() }

    private func edit(_ name: String, _ change: (inout DottieDocument) -> Void) {
        var next = document.model
        change(&next)
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    /// Element ids carried by a drop, groups expanded.
    private func dropped(_ items: [String]) -> Set<UUID> {
        var ids = Set<UUID>()
        for s in items where s.hasPrefix(Self.dragPrefix) {
            for part in s.dropFirst(Self.dragPrefix.count).split(separator: ",") { if let u = UUID(uuidString: String(part)) { ids.insert(u) } }
        }
        return document.model.expandingGroups(ids)
    }

    private func dragString(for id: UUID) -> String {
        let ids = selection.contains(id) ? selection : [id]
        return Self.dragPrefix + ids.map(\.uuidString).joined(separator: ",")
    }

    var body: some View {
        let byLayer = Dictionary(grouping: document.model.elements, by: \.layerID)
        Section("Layers") {
            // Front-most layer first, like every layers panel.
            ForEach(layers.reversed()) { layer in
                let members = byLayer[layer.id] ?? []
                LayerRow(layer: layer, isActive: layer.id == current, count: members.count,
                         isExpanded: expanded.contains(layer.id),
                         toggleExpanded: { if !expanded.insert(layer.id).inserted { expanded.remove(layer.id) } },
                         select: { activeLayer = layer.id },
                         rename: { n in edit("Rename Layer") { $0.editLayer(layer.id) { $0.name = n } } },
                         toggleVisible: { edit("Toggle Layer Visibility") { $0.editLayer(layer.id) { $0.visible.toggle() } } },
                         toggleLocked: { edit("Toggle Layer Lock") { $0.editLayer(layer.id) { $0.locked.toggle() } } })
                    .dropDestination(for: String.self) { items, _ in
                        let ids = dropped(items)
                        guard !ids.isEmpty else { return false }
                        edit("Move to Layer") { $0.move(ids, toLayer: layer.id, inFrontOf: nil) }
                        return true
                    }
                if expanded.contains(layer.id) {
                    ForEach(Array(members.reversed().prefix(Self.rowLimit))) { e in
                        ElementRow(element: e, isSelected: selection.contains(e.id))
                            .onTapGesture { onSelect(document.model.expandingGroups([e.id])) }
                            .draggable(dragString(for: e.id))
                            .dropDestination(for: String.self) { items, _ in
                                let ids = dropped(items)
                                guard !ids.isEmpty else { return false }
                                edit("Reorder") { $0.move(ids, toLayer: layer.id, inFrontOf: e.id) }
                                return true
                            }
                    }
                    if members.count > Self.rowLimit {
                        Text("and \(members.count - Self.rowLimit) more").font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                }
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

/// The selected element's anchor. Committed on Return or when the field loses focus, so typing is one undo step.
private struct AnchorField: View {
    var element: Element
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Anchor", text: $text, prompt: Text("Not shown on the canvas"))
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
            .onAppear { text = element.anchor ?? "" }
            .onChange(of: element.id) { _, _ in text = element.anchor ?? "" }
            .onChange(of: element.anchor) { _, n in if !focused { text = n ?? "" } }
            .help("A hidden label for finding this element in the Layers panel and the Link list")
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (element.anchor ?? "") { commit(trimmed) }
    }
}

extension Element {
    /// How an element is named in lists: its anchor, the first line of its text, or its kind.
    var displayTitle: String {
        if let n = anchor, !n.isEmpty { return String(n.prefix(28)) }
        if let t = text?.split(separator: "\n").first, !t.isEmpty { return String(t.prefix(28)) }
        switch kind {
        case .path: return "Shape"
        case .freehand: return "Stroke"
        default: return kind.rawValue.capitalized
        }
    }
}

private struct ElementRow: View {
    var element: Element
    var isSelected: Bool

    private var symbol: String {
        switch element.kind {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .diamond: "diamond"
        case .text: "textformat"
        case .connector: "arrow.right"
        case .freehand: "scribble"
        case .path: "scribble.variable"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(element.displayTitle).lineLimit(1).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.leading, 22)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

private struct LayerRow: View {
    var layer: Layer
    var isActive: Bool
    var count: Int
    var isExpanded: Bool
    var toggleExpanded: () -> Void
    var select: () -> Void
    var rename: (String) -> Void
    var toggleVisible: () -> Void
    var toggleLocked: () -> Void
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleExpanded) { Image(systemName: isExpanded ? "chevron.down" : "chevron.right").frame(width: 10) }
                .help(isExpanded ? "Hide elements" : "Show elements")
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
