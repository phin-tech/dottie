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

    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { send(#selector(CanvasNSView.zoomIn(_:))) }
                .keyboardShortcut("=")
            Button("Zoom Out") { send(#selector(CanvasNSView.zoomOut(_:))) }
                .keyboardShortcut("-")
            Button("Actual Size") { send(#selector(CanvasNSView.zoomActualSize(_:))) }
                .keyboardShortcut("0")
            Divider()
        }
        InspectorCommands()
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
