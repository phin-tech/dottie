import SwiftUI
import DottieKit

private struct ToolKey: FocusedValueKey { typealias Value = Binding<Tool> }

extension FocusedValues {
    /// The active window's current tool, so menu commands can read and change it.
    var tool: Binding<Tool>? {
        get { self[ToolKey.self] }
        set { self[ToolKey.self] = newValue }
    }
}

/// Menu bar commands. Single-key tool shortcuts stay in the canvas `keyDown` (a bare-key menu
/// equivalent would swallow typing in the text editor); the menu lists them in the item titles.
struct DottieCommands: Commands {
    @FocusedBinding(\.tool) private var tool
    @FocusedValue(\.editor) private var editor
    @AppStorage(Pref.showRulers) private var showRulers = false
    @AppStorage("onionSkin") private var onionSkin = false

    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await UpdateChecker.shared.check(userInitiated: true) } }
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { send(#selector(CanvasNSView.zoomIn(_:))) }
                .keyboardShortcut("=")
            Button("Zoom Out") { send(#selector(CanvasNSView.zoomOut(_:))) }
                .keyboardShortcut("-")
            Button("Actual Size") { send(#selector(CanvasNSView.zoomActualSize(_:))) }
                .keyboardShortcut("0")
            Toggle("Show Rulers", isOn: $showRulers)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Follow Link") { send(#selector(CanvasNSView.followLink(_:))) }
            Button("Back") { send(#selector(CanvasNSView.jumpBack(_:))) }
                .keyboardShortcut("[")
            Button("Forward") { send(#selector(CanvasNSView.jumpForward(_:))) }
                .keyboardShortcut("]")
            Divider()
        }
        InspectorCommands()
        CommandGroup(after: .pasteboard) {
            Button("Duplicate") { send(#selector(CanvasNSView.duplicate(_:))) }
                .keyboardShortcut("d")
        }
        CommandGroup(replacing: .importExport) {
            Button("Insert Image…") { send(#selector(CanvasNSView.insertImage(_:))) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Import SVG…") { send(#selector(CanvasNSView.importSVG(_:))) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Import Excalidraw…") { send(#selector(CanvasNSView.importExcalidrawScene(_:))) }
            Button("Import draw.io…") { send(#selector(CanvasNSView.importDrawioFile(_:))) }
            Button("Import Mermaid…") { send(#selector(CanvasNSView.importMermaidFile(_:))) }
            Menu("Export As") {
                ForEach(ExportFormat.allCases, id: \.self) { f in
                    Button("\(f.rawValue)…") { editor?.export(f) }
                }
            }
            .disabled(editor == nil)
        }
        CommandMenu("Page") {
            let pages = editor?.pageCount ?? 0
            Button("New Page") { editor?.newPage() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Duplicate Page") { editor?.duplicatePage() }
                .disabled(editor == nil)
            Button("Delete Page") { editor?.deletePage() }
                .disabled(pages < 2)
            Divider()
            Button("Previous Page") { editor?.showPage(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(pages < 2)
            Button("Next Page") { editor?.showPage(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(pages < 2)
        }
        CommandMenu("Arrange") {
            let n = editor?.selectionCount ?? 0
            Button("Group") { editor?.group() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(n < 2)
            Button("Ungroup") { editor?.ungroup() }
                .keyboardShortcut("g", modifiers: [.command, .option, .shift])
                .disabled(n < 1)
            Divider()
            Button("Bring to Front") { editor?.reorder(.toFront) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(n < 1)
            Button("Bring Forward") { editor?.reorder(.forward) }.disabled(n < 1)
            Button("Send Backward") { editor?.reorder(.backward) }.disabled(n < 1)
            Button("Send to Back") { editor?.reorder(.toBack) }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(n < 1)
            Divider()
            Menu("Align") {
                Button("Left") { editor?.align(.left) }
                Button("Center Horizontally") { editor?.align(.centerX) }
                Button("Right") { editor?.align(.right) }
                Divider()
                Button("Top") { editor?.align(.top) }
                Button("Center Vertically") { editor?.align(.centerY) }
                Button("Bottom") { editor?.align(.bottom) }
            }
            .disabled(n < 2)
            Menu("Distribute") {
                Button("Horizontally") { editor?.distribute(.horizontal) }
                Button("Vertically") { editor?.distribute(.vertical) }
            }
            .disabled(n < 3)
        }
        CommandMenu("Animate") {
            let n = editor?.selectionCount ?? 0
            Button("New Animation") { editor?.newAnimation() }
                .disabled(editor == nil || editor?.hasAnimation == true)
            Menu("Add Transition") {
                // Entrances, exits, then emphasis; a Section would add separators of its own on top of these.
                ForEach(DottieKit.Transition.entrances, id: \.self) { t in Button(t.title) { editor?.addTransition(t) } }
                Divider()
                ForEach(DottieKit.Transition.exits, id: \.self) { t in Button(t.title) { editor?.addTransition(t) } }
                Divider()
                ForEach(DottieKit.Transition.emphasis, id: \.self) { t in Button(t.title) { editor?.addTransition(t) } }
            }
            .disabled(n == 0)
            Button("Send Packet Along Arrow") { editor?.sendPacket() }
                .disabled((editor?.connectorsSelected ?? 0) == 0)
            Menu("Build Diagram") {
                ForEach(BuildStyle.allCases, id: \.self) { s in Button(s.title) { editor?.buildDiagram(s) } }
            }
            .disabled(editor == nil)
            Divider()
            Toggle("Boil Lines", isOn: Binding(get: { editor?.boils ?? false }, set: { _ in editor?.toggleBoil() }))
                .disabled(editor == nil)
            Toggle("Settle When Still", isOn: Binding(get: { editor?.settles ?? false }, set: { _ in editor?.toggleSettle() }))
                .disabled(editor?.hasAnimation != true)
            Button("Repeat Selection's Animation") { editor?.repeatSelection() }
                .disabled(n == 0 || editor?.hasAnimation != true)
                .help("Play the selected shapes' keys over and over")
            Divider()
            Button("Add Scene Marker") { editor?.addScene() }
                .disabled(editor == nil)
                .help("A stop at the playhead for click-through presentations (in the HTML export)")
            Button("Frame Camera on Selection") { editor?.frameCamera() }
                .disabled(n == 0)
                .help("Exports look at the selection from the playhead on, easing from the last camera key")
            Button("Remove Camera") { editor?.removeCamera() }
                .disabled(editor?.hasCamera != true)
            Divider()
            Toggle("Onion Skin", isOn: $onionSkin)
                .help("While posing, show the frames just before and after faintly")
            Divider()
            Button("Clear Keys from Selection") { editor?.clearKeys() }
                .disabled(n == 0 || editor?.hasAnimation != true)
            Button("Remove Animation") { editor?.removeAnimation() }
                .disabled(editor?.hasAnimation != true)
        }
        CommandMenu("Script") {
            Button("Script Console…") { editor?.openScriptConsole() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(editor == nil)
            Divider()
            let scripts = ScriptLibrary.list()
            if scripts.isEmpty {
                Text("No Saved Scripts").foregroundStyle(.secondary)
            } else {
                ForEach(scripts, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { editor?.runScriptFile(url) }
                        .disabled(editor == nil)
                }
            }
            Divider()
            Button("Show Scripts Folder") { ScriptLibrary.reveal() }
        }
        CommandMenu("Tools") {
            Picker("Tool", selection: Binding(get: { tool ?? .select }, set: { tool = $0 })) {
                ForEach(Tool.allCases) { t in
                    Text("\(t.label)  \(String(t.shortcut).uppercased())").tag(t)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(tool == nil)
        }
    }
}
