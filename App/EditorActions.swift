import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DottieKit

enum ExportFormat: String, CaseIterable {
    case png = "PNG", svg = "SVG", pdf = "PDF", mermaid = "Mermaid"
    var contentType: UTType {
        switch self {
        case .png: .png
        case .svg: .svg
        case .pdf: .pdf
        case .mermaid: UTType(filenameExtension: "mmd", conformingTo: .plainText) ?? .plainText
        }
    }
    var fileExtension: String { self == .mermaid ? "mmd" : rawValue.lowercased() }
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
    // Animate
    var hasAnimation: Bool
    var boils: Bool
    var settles: Bool
    var connectorsSelected: Int
    var newAnimation: () -> Void
    var removeAnimation: () -> Void
    var addTransition: (DottieKit.Transition) -> Void
    var sendPacket: () -> Void
    var buildDiagram: (BuildStyle) -> Void
    var toggleBoil: () -> Void
    var toggleSettle: () -> Void
    var clearKeys: () -> Void
}

/// The ways Animate ▸ Build Diagram reveals a page.
enum BuildStyle: CaseIterable {
    case popIn, drawIn, packets
    var title: String {
        switch self {
        case .popIn: "Pop In"
        case .drawIn: "Draw In"
        case .packets: "Pop In with Packets"
        }
    }
}

extension DottieKit.Transition {
    /// "popIn" -> "Pop In", for menus.
    var title: String {
        rawValue.reduce(into: "") { s, c in
            if c.isUppercase { s += " " }
            s += s.isEmpty ? c.uppercased() : String(c)
        }
    }
    static let entrances: [DottieKit.Transition] = [.popIn, .growIn, .wipeIn, .dropIn, .slideIn, .drawIn, .fadeIn]
    static let exits: [DottieKit.Transition] = [.popOut, .shrinkOut, .wipeOut, .fadeOut]
    static let emphasis: [DottieKit.Transition] = [.pulse, .wiggle]
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
            showPage: { document.showPage(offset: $0) },
            hasAnimation: document.model.timeline != nil,
            boils: document.model.timeline?.boil != nil,
            settles: document.model.timeline?.settle == true,
            connectorsSelected: document.model.elements.filter { ids.contains($0.id) && $0.kind == .connector }.count,
            newAnimation: { edit("New Animation") { $0.startAnimation() } },
            removeAnimation: {
                playing = false; playhead = nil
                edit("Remove Animation") { $0.timeline = nil }
            },
            addTransition: { transition in animate(transition.title) { doc in
                // Selected shapes in reading order, starting at the playhead.
                let ordered = doc.elements.filter { ids.contains($0.id) }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.id)
                return try doc.addTransition(transition, to: ordered, at: playhead ?? 0) > 0
            } },
            sendPacket: { animate("Send Packet") { doc in
                let arrows = doc.elements.filter { ids.contains($0.id) && $0.kind == .connector }.map(\.id)
                for (i, c) in arrows.enumerated() { try doc.addPacket(along: c, at: (playhead ?? 0) + Double(i) * 0.15) }
                return !arrows.isEmpty
            } },
            buildDiagram: { style in animate("Build Diagram") { doc in
                doc.startAnimation()
                switch style {
                case .popIn: try doc.addBuild(.popIn, at: playhead ?? 0)
                case .drawIn: try doc.addBuild(.drawIn, at: playhead ?? 0, drawArrows: true)
                case .packets: try doc.addBuild(.popIn, at: playhead ?? 0, packets: true)
                }
                return true
            } },
            toggleBoil: { edit("Boil Lines") { $0.startAnimation(); $0.timeline!.boil = $0.timeline!.boil == nil ? 2 : nil } },
            toggleSettle: { edit("Settle When Still") { $0.startAnimation(); $0.timeline!.settle = $0.timeline!.settle == true ? nil : true } },
            clearKeys: { edit("Clear Keys") { $0.clearAnimation(of: ids) } })
    }

    /// An animation edit that can fail or do nothing: beeps instead of committing in either case.
    @MainActor
    private func animate(_ name: String, _ change: (inout DottieDocument) throws -> Bool) {
        var next = document.model
        guard (try? change(&next)) == true else { NSSound.beep(); return }
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    @MainActor
    private func exportDocument(_ format: ExportFormat) {
        // An animated page exports its poster frame.
        let model = document.model.still
        guard !model.elements.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let base = document.file.pages.count > 1 ? model.name : "Drawing"
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data?
        switch format {
        case .png: data = Exporter.png(model)
        case .svg: data = Exporter.svg(model).data(using: .utf8)
        case .pdf: data = Exporter.pdf(model)
        case .mermaid: data = Data(Exporter.mermaid(model).utf8)
        }
        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
