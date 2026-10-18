import SwiftUI
import AppKit
import DottieKit

/// A command with parameters, waiting for its form. `base` is the page as it was when the form opened: the live
/// preview always runs from it, so changing the values never stacks one run on another.
struct PendingCommand: Identifiable {
    let id = UUID()
    let runtime: ExtensionRuntime
    let command: CommandDefinition
    let base: DottieDocument
    let file: DottieFile
    let selection: [UUID]
}

extension ContentView {
    /// Runs a command at once when it has no parameters; otherwise opens its form, which previews as it changes.
    @MainActor
    func startCommand(_ runtime: ExtensionRuntime, _ command: CommandDefinition, selection ids: Set<UUID>) {
        if command.parameters.isEmpty {
            runCommand(runtime, command, params: [:], selection: Array(ids))
        } else {
            pendingCommand = PendingCommand(runtime: runtime, command: command, base: document.model,
                                            file: document.file, selection: Array(ids))
        }
    }

    /// Runs a command that needs no form, and commits its result as one undo step. Its output goes to the console.
    @MainActor
    func runCommand(_ runtime: ExtensionRuntime, _ command: CommandDefinition, params: [String: ExtensionValue], selection: [UUID]) {
        let run = ExtensionHost.shared.run(runtime, command, params: params, on: document.model, file: document.file, selection: selection)
        if run.error == nil {
            ExtensionHost.shared.remember(runtime, command, params: params)
            if run.changed { document.commit(run.page, actionName: command.name, undoManager: undoManager) }
        }
        scriptOutput = run.output.joined(separator: "\n")
        showScriptConsole = true
    }

    /// Shows a command's result on the canvas without an undo step. Returns the problem, if the command failed.
    @MainActor
    func previewCommand(_ p: PendingCommand, _ params: [String: ExtensionValue]) -> String? {
        let run = ExtensionHost.shared.run(p.runtime, p.command, params: params, on: p.base, file: p.file, selection: p.selection)
        document.preview(run.error == nil ? run.page : p.base)
        return run.error
    }

    /// Commits a form's command as one undo step. Returns the problem, leaving the form open, if it failed.
    @MainActor
    func runPendingCommand(_ p: PendingCommand, _ params: [String: ExtensionValue]) -> String? {
        let run = ExtensionHost.shared.run(p.runtime, p.command, params: params, on: p.base, file: p.file, selection: p.selection)
        document.preview(p.base) // drop the preview; the commit below is the change
        scriptOutput = run.output.joined(separator: "\n")
        if let error = run.error { return error }
        ExtensionHost.shared.remember(p.runtime, p.command, params: params)
        if run.changed { document.commit(run.page, actionName: p.command.name, undoManager: undoManager) }
        return nil
    }

    /// Reruns the last command with the same parameters, on the current selection.
    @MainActor
    func repeatLastExtensionCommand() {
        guard let last = ExtensionHost.shared.last, let rt = ExtensionHost.shared.runtime(for: last.extensionID),
              let command = rt.commands.first(where: { $0.id == last.command }) else { return NSSound.beep() }
        runCommand(rt, command, params: last.params, selection: Array(selection))
    }

    /// Regenerates every extension shape in the drawing from its stored parameters, as one undo step.
    @MainActor
    func updateExtensionShapes() {
        var next = document.file
        let result = ExtensionHost.shared.updateAll(&next)
        if next != document.file { document.commitFile(next, actionName: "Update Shapes from Extensions", undoManager: undoManager) }
        scriptOutput = (result.problems + ["Updated \(result.updated) extension shapes."]).joined(separator: "\n")
        showScriptConsole = true
    }
}
