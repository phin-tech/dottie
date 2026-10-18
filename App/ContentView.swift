import SwiftUI
import DottieKit
import UniformTypeIdentifiers

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
    @SceneStorage("sidebarTab") private var sidebarTab: SidebarTab = .style
    /// The posed frame, kept between renders and shared by the context bar and the inspector: every control's
    /// binding reads it, so resolving it each time would cost a full resolve per control.
    @State private var frameCache = FrameCache()
    @Environment(\.colorScheme) private var colorScheme
    @State var showScriptConsole = false
    @State var scriptOutput = ""
    @State var scriptRunning = false
    @AppStorage(Pref.scriptSource) var scriptSource = ""
    /// Seconds into the page's animation while previewing it (see `TimelinePanel`); nil while editing.
    @State var playhead: Double?
    /// Playing through the animation; when paused with a playhead, edits on the canvas pose that frame.
    @State var playing = false
    /// The key picked in the timeline, if any.
    @State var selectedKey: KeyRef?
    /// The timeline's timing popover is open.
    @State var editingTiming = false
    /// An extension command whose parameter form is open.
    @State var pendingCommand: PendingCommand?
    @ObservedObject private var host = ExtensionHost.shared

    var body: some View {
        VStack(spacing: 0) {
            if let id = document.editingSymbol, let symbol = document.page.symbolIndex[id] {
                SymbolBar(pageName: document.page.name, symbolName: symbol.name,
                          instances: document.page.elements.filter { $0.symbol == id }.count) {
                    document.editingSymbol = nil
                }
                Divider()
            }
            ContextBar(document: document, style: selectionStyle, tool: tool, undoManager: undoManager)
            Divider()
            CanvasView(document: document, tool: $tool, selection: $selection, style: newStyle, routing: newRouting,
                       activeLayerID: activeLayer, placeRequest: $placeRequest, showRulers: showRulers, jumpRequest: $jumpRequest,
                       fileURL: fileURL,
                       playhead: document.model.timeline == nil || !playing ? nil : playhead,
                       pose: poseTime,
                       onExitPreview: { playing = false; playhead = nil },
                       editorActions: { editorActions(for: $0) })
            if document.model.timeline != nil {
                Divider()
                TimelinePanel(page: document.model, playhead: $playhead, playing: $playing, selectedKey: $selectedKey,
                              editingTiming: $editingTiming,
                              onSelect: { id in
                                  playing = false
                                  selection = [id]
                              },
                              onEdit: { name, change in editTimeline(name, change) },
                              onRenameScene: { t, name in
                                  var next = document.model
                                  next.renameScene(at: t, to: name)
                                  guard next != document.model else { return }
                                  document.commit(next, actionName: "Rename Scene", undoManager: undoManager)
                              })
            }
            Divider()
            PageBar(document: document, undoManager: undoManager)
        }
            .frame(minWidth: 400)
            .onChange(of: document.currentPageID) { _, _ in
                // Keep only what is on the new page: a link picked on another page brings its sources back selected.
                selection = selection.intersection(document.model.elements.map(\.id))
                activeLayer = nil
                playing = false
                playhead = nil
                selectedKey = nil
            }
            .onChange(of: document.editingSymbol) { old, _ in
                // Into a symbol, or back out of one: nothing selected carries over, except the instance just left.
                selection = old.map { s in Set(document.model.elements.filter { $0.symbol == s }.prefix(1).map(\.id)) } ?? []
                activeLayer = nil
                playing = false
                playhead = nil
                selectedKey = nil
            }
            .onChange(of: document.model.timeline == nil) { _, gone in
                // Undo (or Remove Animation) took the timeline away: stop playing and posing.
                if gone { playing = false; playhead = nil; selectedKey = nil }
            }
            .inspector(isPresented: $showInspector) {
                VStack(spacing: 0) {
                    Picker("Sidebar", selection: $sidebarTab) {
                        ForEach(SidebarTab.allCases) { t in
                            Image(systemName: t.symbol).accessibilityLabel(t.rawValue).help(t.help).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding([.horizontal, .top], 12)
                    switch sidebarTab {
                    case .style, .behavior, .layers, .page:
                        Inspector(document: document, tab: sidebarTab, selection: selection, tool: tool, style: selectionStyle,
                                  activeLayer: $activeLayer, undoManager: undoManager, fileURL: fileURL,
                                  onSelect: { selection = $0 }, onJump: { jumpRequest = JumpRequest(target: $0) },
                                  onOpenOutside: { OutsideLinks.open($0, from: fileURL) })
                    case .anchors:
                        AnchorsPanel(document: document, fileURL: fileURL) { jumpRequest = JumpRequest(target: $0) }
                    case .library:
                        LibraryPanel(document: document, selection: selection, place: { item, keep in
                            placeRequest = PlaceRequest(source: .stencil(item, keepOriginalColors: keep))
                        }, placeExtension: { extensionID, shape in
                            placeRequest = PlaceRequest(source: .extensionShape(extensionID: extensionID, shape: shape))
                        })
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
        .onAppear {
            LiveRegistry.shared.markFront(document, undoManager: undoManager)
            registerDebugHooks()
            UpdateChecker.shared.start()
            followPendingAnchor()
        }
        // A link in another drawing opened this one, which was open already: go where it points.
        .onReceive(NotificationCenter.default.publisher(for: .followDrawingAnchor)) { _ in followPendingAnchor() }
        .onChange(of: activeState) { _, state in
            if state == .key { LiveRegistry.shared.markFront(document, undoManager: undoManager); registerDebugHooks() }
        }
        .sheet(isPresented: $showScriptConsole) {
            ScriptConsole(source: $scriptSource, output: $scriptOutput, selectionCount: selection.count,
                          running: scriptRunning, run: runScript)
        }
        .sheet(item: $pendingCommand) { p in
            ExtensionCommandSheet(command: p.command,
                                  preview: { previewCommand(p, $0) },
                                  revert: { document.preview(p.base) },
                                  run: { runPendingCommand(p, $0) })
        }
        // Extension errors for this window: its own document's, and load errors (sent with no document) to the key window.
        .onReceive(NotificationCenter.default.publisher(for: .extensionProblem)) { note in
            let mine = note.object == nil ? activeState == .key : (note.object as? DrawingDocument) === document
            guard mine, let text = note.userInfo?["text"] as? String else { return }
            scriptOutput = scriptOutput.isEmpty ? text : scriptOutput + "\n" + text
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

extension ContentView {
    /// The animation time being posed: paused on an animated page's timeline. Edits there become keys.
    var poseTime: Double? { document.model.timeline == nil || playing ? nil : playhead }

    /// Style editing for the selection, shared by the context bar and the Style tab.
    var selectionStyle: SelectionStyle {
        SelectionStyle(document: document, selection: selection, newStyle: $newStyle, newRouting: $newRouting,
                       undoManager: undoManager, pose: poseTime, frameCache: frameCache, colorScheme: colorScheme)
    }

    /// Applies `change` to the page's timeline as one undo step.
    @MainActor
    func editTimeline(_ name: String, _ change: (inout Timeline) -> Void) {
        var next = document.model
        guard var tl = next.timeline else { return }
        change(&tl)
        next.timeline = tl
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    /// Goes to the shape or page a link from another drawing opened this one at, if one is waiting.
    @MainActor
    func followPendingAnchor() {
        guard let name = OutsideLinks.take(for: fileURL) else { return }
        switch document.file.destination(name) {
        case .element(let id):
            // After the window's first layout, so the jump centers the shape in the canvas it will have.
            DispatchQueue.main.async { jumpRequest = JumpRequest(target: id) }
        case .page(let id):
            document.currentPageID = id
        case nil:
            NSSound.beep()
        }
    }

    /// Lets `scripts/dottie-debug.py` drive this window in Debug builds (see `DebugDriver`).
    @MainActor
    func registerDebugHooks() {
        #if DEBUG
        DebugDriver.shared.front = DebugHooks(
            document: document, undoManager: undoManager, editor: { editorActions },
            playhead: { playhead }, setPlayhead: { playhead = $0 },
            playing: { playing }, setPlaying: { playing = $0 },
            selection: { selection }, setSelection: { selection = $0 },
            selectedKey: { selectedKey }, setSelectedKey: { selectedKey = $0 },
            editTimeline: { name, change in editTimeline(name, change) })
        #endif
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case style = "Style", behavior = "Behavior", layers = "Layers", anchors = "Anchors", page = "Page", library = "Library"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .style: "paintbrush"
        case .behavior: "cursorarrow.click.2"
        case .layers: "square.3.layers.3d"
        case .anchors: "bookmark"
        case .page: "doc"
        case .library: "books.vertical"
        }
    }

    var help: String {
        switch self {
        case .style: "Style: how the selection looks"
        case .behavior: "Behavior: links, clicks on the web, and how a symbol's copy plays"
        case .layers: "Layers"
        case .anchors: "Anchors: the drawing's anchored shapes, to go to or link to"
        case .page: "Page: theme, rulers and guides"
        case .library: "Library: stencils to place"
        }
    }
}

struct Inspector: View {
    @ObservedObject var document: DrawingDocument
    var tab: SidebarTab
    var selection: Set<UUID>
    var tool: Tool
    var style: SelectionStyle
    @Binding var activeLayer: UUID?
    var undoManager: UndoManager?
    /// Where the drawing is saved, which links to other drawings are written relative to.
    var fileURL: URL?
    var onSelect: (Set<UUID>) -> Void = { _ in }
    var onJump: (UUID) -> Void = { _ in }
    var onOpenOutside: (OutsideLink) -> Void = { _ in }
    @AppStorage(Pref.showRulers) private var showRulers = false

    private var selected: [Element] { style.selected }

    var body: some View {
        Form {
            switch tab {
            case .style: styleTab
            case .behavior: behaviorTab
            case .layers:
                LayersSection(document: document, selection: selection, activeLayer: $activeLayer, undoManager: undoManager,
                              onSelect: onSelect)
            case .page: pageTab
            case .anchors, .library: EmptyView()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Style

    @ViewBuilder private var styleTab: some View {
        if selected.count == 1, let e = selected.first, let ref = e.extension {
            ExtensionShapeSection(document: document, elementID: e.id, ref: ref, undoManager: undoManager)
        }
        Section(selected.isEmpty ? "Style for New Shapes" : "Style") {
            Picker("Look", selection: style.look) {
                Text("Sketchy").tag(true)
                Text("Clean").tag(false)
            }
            .pickerStyle(.segmented)
            ColorPicker("Stroke", selection: style.color(\.stroke, "Change Stroke Color"))
            if style.hasFill {
                ColorPicker("Fill", selection: style.color(\.fill, "Change Fill Color"), supportsOpacity: true)
                Picker("Fill pattern", selection: style.binding(\.fillStyle, "Change Fill Pattern")) {
                    ForEach(StyleChoices.fills, id: \.0) { Text($0.1).tag($0.0) }
                }
                if style.binding(\.fillStyle, "").wrappedValue == .grid {
                    let cell = style.binding(\.cellSize, "Change Grid Size")
                    Stepper(value: cell, in: 10...200, step: 5) {
                        LabeledContent("Grid cell", value: "\(Int(cell.wrappedValue)) pt")
                    }
                }
            }
            ValueSlider(title: "Width", value: style.binding(\.strokeWidth, "Change Stroke Width"), range: 1...12, format: Self.points)
            ValueSlider(title: "Opacity", value: style.binding(\.opacityLevel, "Change Opacity"), range: 0...1, format: Self.percent)
            Picker("Line", selection: style.binding(\.dash, "Change Line Style")) {
                ForEach(StyleChoices.dashes, id: \.0) { Text($0.1).tag($0.0) }
            }
        }
        // Roughness and bowing mean nothing to a clean drawing, so they only show while it is sketchy.
        if style.isSketchy {
            Section("Sketchiness") {
                ValueSlider(title: "Roughness", value: style.binding(\.roughness, "Change Roughness"), range: 0.2...3, format: Self.decimal)
                ValueSlider(title: "Bowing", value: style.binding(\.bowing, "Change Bowing"), range: 0...3, format: Self.decimal)
            }
        }
        if tool == .note || (!selected.isEmpty && selected.allSatisfy { $0.kind == .note }) {
            Section("Note") { NoteSwatches(fill: style.binding(\.fill, "Change Note Color")) }
        }
        if tool == .connector || !style.selectedConnectors.isEmpty {
            Section("Connector") {
                Picker("Routing", selection: style.routing) {
                    ForEach(StyleChoices.routings, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                Picker("Start", selection: style.head(\.startHead, "Change Start Arrowhead")) {
                    ForEach(StyleChoices.heads, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("End", selection: style.head(\.endHead, "Change End Arrowhead")) {
                    ForEach(StyleChoices.heads, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
        }
    }

    static func points(_ v: Double) -> String { decimal(v) + " pt" }
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func decimal(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    // MARK: Behavior

    @ViewBuilder private var behaviorTab: some View {
        if selected.isEmpty {
            Section {
                Text("Select something to link it to another shape, choose what clicking it does on the web, or, for a symbol's copy, how it plays.")
                    .foregroundStyle(.secondary)
            }
        } else {
            if selected.count == 1, let e = selected.first, e.kind == .symbol {
                SymbolSection(document: document, instance: e, undoManager: undoManager, onBreakApart: onSelect)
            }
            Section("Link") {
                let targets = linkTargets   // every titled shape in the file: worked out once per update
                Picker("Jumps to", selection: linkBinding) {
                    Text("None").tag(UUID?.none)
                    if let id = selectedLink, !targets.contains(where: { $0.id == id }) {
                        Text(linkTitle(id) ?? "Missing element").tag(UUID?.some(id))
                    }
                    ForEach(targets) { t in Text(t.title).tag(UUID?.some(t.id)) }
                }
                .help("Click the badge beside the shape, or ⌘-click the shape, to go there")
                LinkURLField(value: selectedURL, mixed: selectedURL == nil && selected.contains { $0.url != nil },
                             identity: selection, commit: setURL)
                if let link = selectedURL.flatMap(OutsideLink.init), case .drawing = link {
                    DrawingAnchorPicker(link: link, base: fileURL) { anchor in
                        guard case .drawing(let path, _) = link else { return }
                        setURL(OutsideLink.drawing(path: path, anchor: anchor).string)
                    }
                }
                HStack {
                    Button("Choose Drawing…", action: chooseDrawing)
                        .help("Link to another Dottie drawing, written relative to this one so they can move together")
                    if let id = selectedLink {
                        Button("Go") { onJump(id) }
                    } else if let link = selectedURL.flatMap(OutsideLink.init) {
                        Button("Go") { onOpenOutside(link) }
                    }
                }
                if selected.count == 1, let e = selected.first {
                    AnchorField(element: e) { anchor in
                        var next = document.model
                        guard let i = next.elements.firstIndex(where: { $0.id == e.id }) else { return }
                        next.elements[i].anchor = anchor.isEmpty ? nil : anchor
                        document.commit(next, actionName: "Set Anchor", undoManager: undoManager)
                    }
                }
            }
            // Shapes inside a symbol can't be clicked on the web: give the click to its copy instead.
            if document.editingSymbol == nil {
                ClickSection(document: document, selection: selection, undoManager: undoManager)
            }
        }
    }

    // MARK: Page

    @ViewBuilder private var pageTab: some View {
        Section("Page") {
            Picker("Theme", selection: themeBinding) {
                Text("Automatic").tag("")
                ForEach(Theme.all) { t in Text(t.name).tag(t.id) }
            }
            Toggle("Rulers and guides", isOn: $showRulers)
            if showRulers { GuidesEditor(document: document, undoManager: undoManager) }
        }
    }

    private var themeBinding: Binding<String> {
        Binding(get: { document.model.theme ?? "" },
                set: { id in
                    var next = document.model
                    next.theme = id.isEmpty ? nil : id
                    document.commit(next, actionName: "Change Theme", undoManager: undoManager)
                })
    }

    private static let linkTargetLimit = 200

    /// The outside link the selection shares, if every selected element has the same one.
    private var selectedURL: String? {
        guard let first = selected.first?.url, selected.allSatisfy({ $0.url == first }) else { return nil }
        return first
    }

    /// Points the selection at `text`, a web address or another drawing; empty removes the link. A drawing given by
    /// its full path is written relative to this one when they share a folder tree. Beeps at anything else.
    private func setURL(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .drawing(let path, let anchor)? = OutsideLink(value), path.hasPrefix("/") {
            value = OutsideLink.drawing(at: URL(fileURLWithPath: path), from: fileURL, anchor: anchor).string
        }
        var next = document.model
        guard (try? next.setURL(selection, to: value)) != nil else { NSSound.beep(); return }
        guard next != document.model else { return }
        document.commit(next, actionName: value.isEmpty ? "Remove Link" : "Link", undoManager: undoManager)
    }

    private func chooseDrawing() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dottie") ?? .json]
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.prompt = "Link"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setURL(OutsideLink.drawing(at: url, from: fileURL).string)
    }

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
                .map { LinkTarget(id: $0.id, title: $0.displayTitle) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { LinkTarget(id: $0.id, title: prefix + $0.title) }
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
            IconButton("xmark.circle", help: "Remove guide") {
                edit("Remove Guide") { if vertical { _ = $0.guidesX?.remove(at: index) } else { _ = $0.guidesY?.remove(at: index) } }
            }
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
    /// The layer whose name field Rename… in its context menu focuses.
    @State private var renaming: UUID?

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

    /// The same commands as the buttons under the list, for the layer right-clicked rather than the active one.
    @ViewBuilder private func layerMenu(_ layer: Layer) -> some View {
        let i = layers.firstIndex { $0.id == layer.id } ?? 0
        Button("Rename…") { renaming = layer.id }
        Button(layer.visible ? "Hide" : "Show") { edit("Toggle Layer Visibility") { $0.editLayer(layer.id) { $0.visible.toggle() } } }
        Button(layer.locked ? "Unlock" : "Lock") { edit("Toggle Layer Lock") { $0.editLayer(layer.id) { $0.locked.toggle() } } }
        Divider()
        Button("Move Up") { edit("Move Layer Up") { $0.moveLayer(layer.id, by: 1) } }
            .disabled(i == layers.count - 1)
        Button("Move Down") { edit("Move Layer Down") { $0.moveLayer(layer.id, by: -1) } }
            .disabled(i == 0)
        Button("Move Selection Here") { edit("Move to Layer") { $0.move(selection, toLayer: layer.id) } }
            .disabled(selection.isEmpty)
        Divider()
        Button("New Layer") { edit("Add Layer") { activeLayer = $0.addLayer(above: layer.id) } }
        Button("Delete Layer") { edit("Delete Layer") { if $0.removeLayer(layer.id), activeLayer == layer.id { activeLayer = nil } } }
            .disabled(layers.count < 2)
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
                         toggleLocked: { edit("Toggle Layer Lock") { $0.editLayer(layer.id) { $0.locked.toggle() } } },
                         renameRequested: renaming == layer.id, didStartRename: { renaming = nil })
                    .contextMenu { layerMenu(layer) }
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
        case .note: "note.text"
        case .connector: "arrow.right"
        case .freehand: "scribble"
        case .path: "scribble.variable"
        case .image: "photo"
        case .symbol: "square.on.square.dashed"
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
    /// The context menu's Rename… asked for the name field; `didStartRename` says it has focus.
    var renameRequested = false
    var didStartRename: () -> Void = {}
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            DisclosureButton(isExpanded: isExpanded, expandHelp: "Show elements", collapseHelp: "Hide elements", action: toggleExpanded)
            Button(action: toggleVisible) { Image(systemName: layer.visible ? "eye" : "eye.slash") }
                .help(layer.visible ? "Hide layer" : "Show layer")
            Button(action: toggleLocked) { Image(systemName: layer.locked ? "lock.fill" : "lock.open") }
                .help(layer.locked ? "Unlock layer" : "Lock layer")
            TextField("Layer", text: $name)
                .textFieldStyle(.plain)
                .focused($nameFocused)
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
        .onChange(of: renameRequested) { _, now in if now { nameFocused = true; didStartRename() } }
        .opacity(layer.visible ? 1 : 0.55)
    }
}

extension Style {
    /// `opacity` as a slider value: 1 (the default) is stored as nil.
    var opacityLevel: Double {
        get { opacity ?? 1 }
        set { opacity = newValue >= 0.999 ? nil : max(0, newValue) }
    }
}

/// The last posed frame and what it was posed from.
final class FrameCache {
    private var page: DottieDocument?
    private var time = 0.0
    private var frame: DottieDocument?

    func frame(of page: DottieDocument, at t: Double) -> DottieDocument {
        if let frame, t == time, page == self.page { return frame }
        let f = page.posed(at: t)
        self.page = page; time = t; frame = f
        return f
    }
}
