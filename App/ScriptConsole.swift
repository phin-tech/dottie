import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DottieKit

/// Where user scripts live: `~/Library/Application Support/Dottie/Scripts/*.js`.
enum ScriptLibrary {
    static var directory: URL {
        DottieScript.scriptsDirectory
    }

    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "js" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func reveal() {
        try? FileManager.default.createDirectory(at: DottieScript.modulesDirectory, withIntermediateDirectories: true)
        // dottie.d.ts and a tsconfig.json, so an editor opened on the folder completes and checks the scripts.
        try? DottieScript.writeTypes(to: directory)
        NSWorkspace.shared.open(directory)
    }

    /// After an update, brings a dottie.d.ts written by an older version up to date. A folder without one is
    /// left alone until it is revealed.
    static func refreshTypes() {
        let types = directory.appendingPathComponent("dottie.d.ts")
        guard let current = try? String(contentsOf: types, encoding: .utf8), current != DottieScript.typeDefinitions else { return }
        try? DottieScript.writeTypes(to: directory)
    }

    static let starter = """
    // Runs against this drawing as one undo step. Selected elements: dottie.selection
    // Press the Help button for the full API.
    const boxes = ["Idea", "Draft", "Review", "Ship"].map((text, i) =>
      dottie.rect({ x: i * 200, y: 0, text, fill: "#e8f0ff" }));
    boxes.slice(1).forEach((b, i) => dottie.connect(boxes[i], b, { routing: "straight" }));
    return boxes.length;
    """
}

/// Editor, output and run button for a script. State lives in the owning window so menu commands can drive it.
struct ScriptConsole: View {
    @Binding var source: String
    @Binding var output: String
    var selectionCount: Int
    var running: Bool
    var run: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showHelp = false

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .plainText]
        panel.directoryURL = ScriptLibrary.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let text = try? String(contentsOf: url, encoding: .utf8) { source = text }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: ScriptLibrary.directory, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .plainText]
        panel.directoryURL = ScriptLibrary.directory
        panel.nameFieldStringValue = "Script.js"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try source.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .frame(minHeight: 220)
            Divider()
            ScrollView {
                Text(output.isEmpty ? "Output appears here." : output)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 110)
            Divider()
            HStack {
                Button("Open…", action: open)
                Button("Save…", action: save)
                Button("Help") { showHelp.toggle() }
                    .popover(isPresented: $showHelp) {
                        ScrollView {
                            Text(DottieScript.apiReference)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                        }
                        .frame(width: 560, height: 420)
                    }
                Spacer()
                Text(selectionCount == 0 ? "No selection" : "\(selectionCount) selected")
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(running ? "Running…" : "Run", action: run)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(running)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

extension ContentView {
    /// Runs the console's script on a copy of the drawing off the main thread (it is time-limited, but
    /// should not freeze the UI while it runs) and commits the result as one undo step.
    @MainActor
    func runScript() {
        guard !scriptRunning else { return }
        scriptRunning = true
        scriptOutput = ""
        let source = scriptSource
        let original = document.model
        let file = document.file
        let ids = Array(selection)
        Task {
            let (doc, result, typeCheck) = await Task.detached(priority: .userInitiated) { () -> (DottieDocument, ScriptResult, [String]?) in
                var working = original
                let r = DottieScript.run(source, on: &working, in: file, selection: ids)
                return (working, r, DottieScript.typeCheckSummary(source))
            }.value
            if result.succeeded { document.commit(doc, actionName: "Run Script", undoManager: undoManager) }
            var lines = result.logs
            if let error = result.error {
                lines.append("Error: \(error)")
                lines.append("Nothing was changed.")
            } else {
                if let value = result.value { lines.append("→ \(value)") }
                lines.append(doc == original ? "No changes." : "Applied (\(result.operations) calls); undo with ⌘Z.")
            }
            lines += typeCheck ?? []
            scriptOutput = lines.joined(separator: "\n")
            scriptRunning = false
        }
    }

    @MainActor
    func openScriptConsole(running file: URL? = nil) {
        if let file, let text = try? String(contentsOf: file, encoding: .utf8) {
            scriptSource = text
            showScriptConsole = true
            runScript()
        } else {
            if scriptSource.isEmpty { scriptSource = ScriptLibrary.starter }
            showScriptConsole = true
        }
    }
}
