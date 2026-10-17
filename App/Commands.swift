import SwiftUI
import AppKit
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

    /// The page's animation as a GIF, movie, web page or Lottie: in the File menu and again in Animate.
    private var exportAnimationMenu: some View {
        Menu("Export Animation") {
            ForEach(AnimationExportFormat.allCases, id: \.self) { f in
                Button("\(f.title)…") { editor?.exportAnimation(f) }
                    .help(f.help)
                if f == .player { Divider() }
            }
        }
        .disabled(editor?.hasAnimation != true)
    }

    /// Entrances, exits, then emphasis; a Section would add separators of its own on top of these.
    private var transitionMenu: some View {
        Menu("Add Transition") {
            ForEach(DottieKit.Transition.entrances, id: \.self) { t in Button(t.title) { editor?.addTransition(t) } }
            Divider()
            ForEach(DottieKit.Transition.exits, id: \.self) { t in Button(t.title) { editor?.addTransition(t) } }
            Divider()
            ForEach(DottieKit.Transition.emphasis, id: \.self) { t in Button(t.title) { editor?.addTransition(t) } }
        }
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateChecker.shared.checkForUpdates() }
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { send(#selector(CanvasNSView.zoomIn(_:))) }
                .keyboardShortcut("=")
            Button("Zoom Out") { send(#selector(CanvasNSView.zoomOut(_:))) }
                .keyboardShortcut("-")
            Button("Actual Size") { send(#selector(CanvasNSView.zoomActualSize(_:))) }
                .keyboardShortcut("0")
            Button("Zoom to Fit") { send(#selector(CanvasNSView.zoomToFit(_:))) }
                .help("Fit the whole page in the window (⇧1 on the canvas)")
            Toggle("Show Rulers", isOn: $showRulers)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Toggle("Onion Skin", isOn: $onionSkin)
                .help("While posing, show the frames just before and after faintly")
            Divider()
            Button("Follow Link") { send(#selector(CanvasNSView.followLink(_:))) }
            Button("Back") { send(#selector(CanvasNSView.jumpBack(_:))) }
                .keyboardShortcut("[")
            Button("Forward") { send(#selector(CanvasNSView.jumpForward(_:))) }
                .keyboardShortcut("]")
        }
        InspectorCommands()
        CommandGroup(after: .pasteboard) {
            Button("Duplicate") { send(#selector(CanvasNSView.duplicate(_:))) }
                .keyboardShortcut("d")
            Divider()
            Button("Link to Element…") { editor?.linkToElement() }
                .disabled((editor?.selectionCount ?? 0) == 0)
                .help("Click the shape it should jump to; it can be on another page")
            Button("Remove Link") { editor?.removeLink() }
                .disabled(editor?.linkSelected != true)
        }
        CommandGroup(replacing: .importExport) {
            Button("Insert Image…") { send(#selector(CanvasNSView.insertImage(_:))) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Menu("Import") {
                Button("SVG…") { send(#selector(CanvasNSView.importSVG(_:))) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Excalidraw…") { send(#selector(CanvasNSView.importExcalidrawScene(_:))) }
                Button("draw.io…") { send(#selector(CanvasNSView.importDrawioFile(_:))) }
                Button("Mermaid…") { send(#selector(CanvasNSView.importMermaidFile(_:))) }
            }
            .disabled(editor == nil)
            Divider()
            Menu("Export As") {
                ForEach(ExportFormat.allCases, id: \.self) { f in
                    Button("\(f.rawValue)…") { editor?.export(f) }
                }
            }
            .disabled(editor == nil)
            exportAnimationMenu
        }
        CommandMenu("Page") {
            let pages = editor?.pageCount ?? 0
            Button("New Page") { editor?.newPage() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button("Duplicate Page") { editor?.duplicatePage() }
                .disabled(editor == nil)
            Button("Rename Page…") { editor?.renamePage() }
                .disabled(editor == nil)
            Divider()
            Button("Previous Page") { editor?.showPage(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(pages < 2)
            Button("Next Page") { editor?.showPage(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(pages < 2)
            Divider()
            Button("Move Page Left") { editor?.movePage(-1) }
                .disabled((editor?.pageIndex ?? 0) == 0)
            Button("Move Page Right") { editor?.movePage(1) }
                .disabled(editor.map { $0.pageIndex >= $0.pageCount - 1 } ?? true)
            Divider()
            Button("Delete Page") { editor?.deletePage() }
                .disabled(pages < 2)
        }
        CommandMenu("Arrange") {
            let n = editor?.selectionCount ?? 0
            Button("Group") { editor?.group() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(n < 2)
            Button("Ungroup") { editor?.ungroup() }
                .keyboardShortcut("g", modifiers: [.command, .option, .shift])
                .disabled(editor?.grouped != true)
            Divider()
            Button("Convert to Symbol") { editor?.makeSymbol() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [])
                .disabled(n < 1)
            Button("Edit Symbol") { editor?.editSymbol() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(editor?.instanceSelected != true)
            Button("Break Apart") { editor?.breakApart() }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(editor?.instanceSelected != true)
            Button("Done Editing Symbol") { editor?.doneEditingSymbol() }
                .disabled(editor?.editingSymbol != true)
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
            let animated = editor?.hasAnimation == true
            Button("New Animation") { editor?.newAnimation() }
                .disabled(editor == nil || animated)
            Button("Timing…") { editor?.editTiming() }
                .disabled(!animated)
                .help("The animation's length and frame rate")
            Divider()
            // Ways to make keys for you: the selection's, the page's, or the next page's.
            transitionMenu.disabled(n == 0)
            Menu("Build Diagram") {
                ForEach(BuildStyle.allCases, id: \.self) { s in Button(s.title) { editor?.buildDiagram(s) } }
            }
            .disabled(editor == nil)
            Button("Magic Move to Next Page") { editor?.magicMove() }
                .disabled(editor?.hasNextPage != true)
                .help("Tween this page into the next one: shapes with the same anchor, seed or text move, the rest fade")
            Divider()
            Button("Send Packet Along Arrow") { editor?.sendPacket() }
                .disabled((editor?.connectorsSelected ?? 0) == 0)
            Button("March Selected Lines") { editor?.marchSelection() }
                .disabled(n == 0)
                .help("Marching ants: the dashes travel along the line (again to stop)")
            Button("Repeat Selection's Animation") { editor?.repeatSelection() }
                .disabled(n == 0 || !animated)
                .help("Play the selected shapes' keys over and over")
            Button("Clear Keys from Selection") { editor?.clearKeys() }
                .disabled(n == 0 || !animated)
            Divider()
            Button("Add Scene Marker") { editor?.addScene(nil) }
                .disabled(editor == nil)
                .help("A stop at the playhead for click-through presentations (in the HTML export)")
            Menu("Go to Scene") {
                Button("Previous Scene") { editor?.showScene(-1) }
                Button("Next Scene") { editor?.showScene(1) }
                Divider()
                ForEach(Array((editor?.scenes ?? []).enumerated()), id: \.offset) { _, m in
                    Button(m.name) { editor?.playScene(m) }
                }
            }
            .disabled((editor?.scenes ?? []).isEmpty)
            Button("Frame Camera on Selection") { editor?.frameCamera() }
                .disabled(n == 0)
                .help("Exports look at the selection from the playhead on, easing from the last camera key")
            Button("Remove Camera") { editor?.removeCamera() }
                .disabled(editor?.hasCamera != true)
            Divider()
            Toggle("Boil Lines", isOn: Binding(get: { editor?.boils ?? false }, set: { _ in editor?.toggleBoil() }))
                .disabled(editor == nil)
            Toggle("Settle When Still", isOn: Binding(get: { editor?.settles ?? false }, set: { _ in editor?.toggleSettle() }))
                .disabled(!animated)
            Divider()
            exportAnimationMenu
            Divider()
            Button("Remove Animation") { editor?.removeAnimation() }
                .disabled(!animated)
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
