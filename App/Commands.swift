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

    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }

    var body: some Commands {
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
            Button("Import SVG…") { send(#selector(CanvasNSView.importSVG(_:))) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Import Excalidraw…") { send(#selector(CanvasNSView.importExcalidrawScene(_:))) }
            Button("Import draw.io…") { send(#selector(CanvasNSView.importDrawioFile(_:))) }
            Menu("Export As") {
                ForEach(ExportFormat.allCases, id: \.self) { f in
                    Button("\(f.rawValue)…") { editor?.export(f) }
                }
            }
            .disabled(editor == nil)
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
