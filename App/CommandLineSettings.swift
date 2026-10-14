import SwiftUI
import AppKit
import DottieKit

/// Settings ▸ Command Line: installs the `dottie` tool (render to png, svg, pdf, html; manage libraries)
/// as a symlink on the PATH, so app updates carry over.
struct CommandLineSettings: View {
    @State private var message: String?
    @State private var refresh = 0

    private static let linkName = "dottie"

    /// The tool shipped inside the app, or the SwiftPM build next to this source tree in a dev setup.
    private static var binaryURL: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dottie-cli"),
            root.appendingPathComponent(".build/release/dottie"),
            root.appendingPathComponent(".build/debug/dottie"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var candidateDirectories: [URL] {
        [URL(fileURLWithPath: "/usr/local/bin"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")]
    }

    /// Where a `dottie` link we made (or any `dottie`) currently sits, if anywhere.
    private static var installedLink: URL? {
        candidateDirectories.map { $0.appendingPathComponent(linkName) }
            .first { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil }
    }

    var body: some View {
        let _ = refresh
        let binary = Self.binaryURL
        let link = Self.installedLink
        Form {
            Section {
                LabeledContent("Tool") {
                    Label(binary == nil ? "Not built" : "Found", systemImage: binary == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(binary == nil ? Color.red : Color.green)
                }
                if let binary {
                    LabeledContent("Path") {
                        Text(binary.path).font(.caption.monospaced()).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
                LabeledContent("Installed") {
                    if let link { Text(link.path).font(.caption.monospaced()).textSelection(.enabled) }
                    else { Text("No").foregroundStyle(.secondary) }
                }
                HStack {
                    Button("Install in /usr/local/bin…") { install(binary, into: Self.candidateDirectories[0], admin: true) }
                        .disabled(binary == nil)
                    Button("Install in ~/.local/bin") { install(binary, into: Self.candidateDirectories[1], admin: false) }
                        .disabled(binary == nil)
                    Spacer()
                    if link != nil { Button("Uninstall") { uninstall() } }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("dottie command")
            } footer: {
                if binary == nil {
                    Text("Build it with: swift build -c release --product dottie").foregroundStyle(.secondary)
                } else {
                    Text("Then: dottie render drawing.dottie -o drawing.svg   (png, svg, pdf, html). Run dottie --help for more.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func install(_ binary: URL?, into dir: URL, admin: Bool) {
        guard let binary else { return }
        let link = dir.appendingPathComponent(Self.linkName)
        do {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try FileManager.default.removeItem(at: link)
            } else if FileManager.default.fileExists(atPath: link.path) {
                message = "\(link.path) exists and is not a link from Dottie. Remove it first."
                return
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
            message = "Installed \(link.path)." + (admin ? "" : " Make sure ~/.local/bin is on your PATH.")
        } catch {
            guard admin else { message = error.localizedDescription; return }
            // /usr/local/bin is often root-owned: retry through the system's admin prompt.
            let script = "do shell script \"mkdir -p \(shell(dir.path)) && ln -sf \(shell(binary.path)) \(shell(link.path))\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            message = err == nil ? "Installed \(link.path)." : "Could not install: \((err?[NSAppleScript.errorMessage] as? String) ?? "cancelled")"
        }
        refresh += 1
    }

    private func uninstall() {
        guard let link = Self.installedLink else { return }
        do {
            try FileManager.default.removeItem(at: link)
            message = "Removed \(link.path)."
        } catch {
            let script = "do shell script \"rm \(shell(link.path))\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            message = err == nil ? "Removed \(link.path)." : "Could not remove: \((err?[NSAppleScript.errorMessage] as? String) ?? "cancelled")"
        }
        refresh += 1
    }

    /// Single-quoted for the shell, then escaped for inside an AppleScript string.
    private func shell(_ s: String) -> String {
        ("'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
