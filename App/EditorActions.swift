import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DottieKit

enum ExportFormat: String, CaseIterable {
    case png = "PNG", svg = "SVG", pdf = "PDF"
    var contentType: UTType { switch self { case .png: .png; case .svg: .svg; case .pdf: .pdf } }
}

/// Window-level commands that act on the document and selection. Reached from the menu bar through
/// a focused scene value, so each window's commands target its own document.
struct EditorActions {
    var selectionCount: Int
    var group: () -> Void
    var ungroup: () -> Void
    var align: (AlignEdge) -> Void
    var distribute: (DistributeAxis) -> Void
    var reorder: (DottieDocument.ZMove) -> Void
    var export: (ExportFormat) -> Void
    var openScriptConsole: () -> Void
    var runScriptFile: (URL) -> Void
    var pageCount: Int
    var newPage: () -> Void
    var duplicatePage: () -> Void
    var deletePage: () -> Void
    var showPage: (_ offset: Int) -> Void
}

private struct EditorActionsKey: FocusedValueKey { typealias Value = EditorActions }

extension FocusedValues {
    var editor: EditorActions? {
        get { self[EditorActionsKey.self] }
        set { self[EditorActionsKey.self] = newValue }
    }
}

extension ContentView {
    /// Applies `change` to a copy of the model and commits it as one undo step.
    @MainActor
    private func edit(_ name: String, _ change: (inout DottieDocument) -> Void) {
        var next = document.model
        change(&next)
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    @MainActor
    var editorActions: EditorActions {
        let ids = selection
        return EditorActions(
            selectionCount: ids.count,
            group: { edit("Group") { $0.group(ids) } },
            ungroup: { edit("Ungroup") { $0.ungroup(ids) } },
            align: { edge in edit("Align") { $0.align(ids, to: edge) } },
            distribute: { axis in edit("Distribute") { $0.distribute(ids, along: axis) } },
            reorder: { move in edit("Arrange") { $0.reorder(ids, move) } },
            export: { format in exportDocument(format) },
            openScriptConsole: { openScriptConsole() },
            runScriptFile: { openScriptConsole(running: $0) },
            pageCount: document.file.pages.count,
            newPage: { document.addPage(undoManager: undoManager) },
            duplicatePage: { document.duplicatePage(document.currentPageID, undoManager: undoManager) },
            deletePage: { document.deletePage(document.currentPageID, undoManager: undoManager) },
            showPage: { document.showPage(offset: $0) })
    }

    @MainActor
    private func exportDocument(_ format: ExportFormat) {
        let model = document.model
        guard !model.elements.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let base = document.file.pages.count > 1 ? model.name : "Drawing"
        panel.nameFieldStringValue = "\(base).\(format.rawValue.lowercased())"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data?
        switch format {
        case .png: data = Exporter.png(model)
        case .svg: data = Exporter.svg(model).data(using: .utf8)
        case .pdf: data = Exporter.pdf(model)
        }
        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
