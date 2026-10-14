import SwiftUI
import AppKit
import DottieKit

/// Settings ▸ MCP: where the agent server is, whether the app is accepting live edits, and the
/// command that registers it with an MCP client.
struct MCPSettings: View {
    @AppStorage(Pref.mcpBinaryPath) private var customPath = ""

    /// Best guess for a dev setup: the SwiftPM build next to this source tree, or a bundled helper.
    private static var guessedPath: String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dottie-mcp").path,
            root.appendingPathComponent(".build/release/dottie-mcp").path,
            root.appendingPathComponent(".build/debug/dottie-mcp").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[1]
    }

    private var binaryPath: String { customPath.isEmpty ? Self.guessedPath : customPath }
    private var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binaryPath) }
    private var addCommand: String { "claude mcp add dottie -- \(shellQuoted(binaryPath))" }
    private var jsonConfig: String {
        "{\n  \"mcpServers\": {\n    \"dottie\": { \"command\": \(jsonQuoted(binaryPath)) }\n  }\n}"
    }

    var body: some View {
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let open = LiveRegistry.shared.openPaths
                    LabeledContent("Status") {
                        Label(LiveServer.shared.isListening ? "Accepting live edits" : "Not listening",
                              systemImage: LiveServer.shared.isListening ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(LiveServer.shared.isListening ? Color.green : Color.orange)
                    }
                    LabeledContent("Open documents", value: "\(open.count)")
                }
                LabeledContent("Socket") {
                    Text(LiveSocket.path).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
            } header: {
                Text("Live mode")
            } footer: {
                Text("While a document is open here, agent edits apply to it directly and show up in Edit ▸ Undo. Save to keep them.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Path") {
                    Text(binaryPath).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
                LabeledContent("Binary") {
                    Label(binaryExists ? "Found" : "Not built",
                          systemImage: binaryExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(binaryExists ? Color.green : Color.red)
                }
                HStack {
                    Button("Choose…", action: chooseBinary)
                    if !customPath.isEmpty { Button("Use Default") { customPath = "" } }
                    Spacer()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: binaryPath)]) }
                        .disabled(!binaryExists)
                }
            } header: {
                Text("Server")
            } footer: {
                if !binaryExists {
                    Text("Build it with: swift build -c release --product dottie-mcp").foregroundStyle(.secondary)
                }
            }

            Section("Add to an MCP client") {
                snippet("Claude Code", addCommand)
                snippet("JSON config (Claude Desktop and others)", jsonConfig)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the dottie-mcp executable"
        if panel.runModal() == .OK, let url = panel.url { customPath = url.path }
    }

    private func shellQuoted(_ s: String) -> String {
        s.contains(where: { " '\"\\$`".contains($0) }) ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
    }

    private func jsonQuoted(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(s)\""
    }
}
