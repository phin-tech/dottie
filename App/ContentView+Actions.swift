import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DottieKit

extension ContentView {
    /// Applies `change` to a copy of the model and commits it as one undo step.
    @MainActor
    private func edit(_ name: String, _ change: (inout DottieDocument) -> Void) {
        var next = document.model
        change(&next)
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    @MainActor
    var editorActions: EditorActions { editorActions(for: selection) }

    /// The commands acting on `ids`: the canvas's context menu passes the selection it just made, which reaches
    /// `selection` only on the next turn of the run loop.
    @MainActor
    func editorActions(for ids: Set<UUID>) -> EditorActions {
        EditorActions(
            selectionCount: ids.count,
            grouped: document.model.elements.contains { ids.contains($0.id) && $0.groupID != nil },
            group: { edit("Group") { $0.group(ids) } },
            ungroup: { edit("Ungroup") { $0.ungroup(ids) } },
            instanceSelected: ids.count == 1 && document.model.elements.contains { ids.contains($0.id) && $0.kind == .symbol },
            editingSymbol: document.editingSymbol != nil,
            makeSymbol: {
                var next = document.model
                let n = (next.symbols?.count ?? 0) + 1
                guard let made = next.makeSymbol(of: ids, name: "Symbol \(n)") else { NSSound.beep(); return }
                document.commit(next, actionName: "Convert to Symbol", undoManager: undoManager)
                selection = [made.instance.id]
            },
            breakApart: {
                var next = document.model
                var parts = Set<UUID>()
                for id in ids { parts.formUnion(next.breakApart(id)) }
                guard !parts.isEmpty else { NSSound.beep(); return }
                document.commit(next, actionName: "Break Apart", undoManager: undoManager)
                selection = parts
            },
            editSymbol: { if let id = ids.first { document.editSymbol(of: id) } },
            doneEditingSymbol: { document.editingSymbol = nil },
            align: { edge in edit("Align") { $0.align(ids, to: edge) } },
            distribute: { axis in edit("Distribute") { $0.distribute(ids, along: axis) } },
            reorder: { move in edit("Arrange") { $0.reorder(ids, move) } },
            export: { format in exportDocument(format) },
            exportAnimation: { format in exportAnimation(format) },
            openScriptConsole: { openScriptConsole() },
            runScriptFile: { openScriptConsole(running: $0) },
            pageCount: document.file.pages.count,
            newPage: { document.addPage(undoManager: undoManager) },
            duplicatePage: { document.duplicatePage(document.currentPageID, undoManager: undoManager) },
            deletePage: { document.deletePage(document.currentPageID, undoManager: undoManager) },
            showPage: { document.showPage(offset: $0) },
            renamePage: { document.renamingPage = document.currentPageID },
            movePage: { offset in
                guard let i = document.file.index(of: document.currentPageID) else { return }
                document.movePage(document.currentPageID, to: i + offset, undoManager: undoManager)
            },
            pageIndex: document.file.index(of: document.currentPageID) ?? 0,
            linkSelected: document.model.elements.contains { ids.contains($0.id) && $0.link != nil },
            linkToElement: { NSApp.sendAction(#selector(CanvasNSView.linkToElement(_:)), to: nil, from: nil) },
            removeLink: { edit("Remove Link") { try? $0.setLink(ids, to: nil) } },
            hasAnimation: document.model.timeline != nil,
            boils: document.model.timeline?.boil != nil,
            settles: document.model.timeline?.settle == true,
            connectorsSelected: document.model.elements.filter { ids.contains($0.id) && $0.kind == .connector }.count,
            newAnimation: { edit("New Animation") { $0.startAnimation() } },
            editTiming: { editingTiming = true },
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
            hasNextPage: document.file.pages.last?.id != document.currentPageID,
            magicMove: { animate("Magic Move") { doc in
                let pages = document.file.pages
                guard let i = pages.firstIndex(where: { $0.id == doc.id }), i + 1 < pages.count else { return false }
                try doc.magicMove(to: pages[i + 1])
                return true
            } },
            marchSelection: { animate("March") { doc in
                // Selected lines march, or stop if they all already do.
                let lines = doc.elements.filter { ids.contains($0.id) && ($0.kind == .connector || $0.kind == .freehand) }.map(\.id)
                guard !lines.isEmpty else { return false }
                doc.startAnimation()
                let stop = lines.allSatisfy { doc.timeline!.track(for: $0)?.march != nil }
                for id in lines {
                    doc.timeline!.setMarch(stop ? nil : 40, for: id)
                    if !stop, let i = doc.elements.firstIndex(where: { $0.id == id }), doc.elements[i].style.dash == .solid {
                        doc.elements[i].style.dash = .dashed
                    }
                }
                return true
            } },
            toggleBoil: { edit("Boil Lines") { $0.startAnimation(); $0.timeline!.boil = $0.timeline!.boil == nil ? 2 : nil } },
            toggleSettle: { edit("Settle When Still") { $0.startAnimation(); $0.timeline!.settle = $0.timeline!.settle == true ? nil : true } },
            clearKeys: { edit("Clear Keys") { $0.clearAnimation(of: ids) } },
            hasCamera: !(document.model.timeline?.camera ?? []).isEmpty,
            scenes: document.model.timeline?.markers ?? [],
            addScene: { at in animate("Add Scene") { doc in
                doc.startAnimation()
                return doc.timeline!.addScene(at: at ?? playhead ?? 0)
            } },
            showScene: { offset in
                let markers = document.model.timeline?.markers ?? [], t = playhead ?? 0
                let to = offset < 0 ? markers.last { $0.t < t - 1e-6 }?.t ?? 0 : markers.first { $0.t > t + 1e-6 }?.t
                guard let to else { NSSound.beep(); return }
                playing = false
                playhead = to
            },
            playScene: { m in playing = false; playhead = m.t },
            frameCamera: { animate("Frame Camera") { doc in
                let index = doc.elementIndex
                let boxes = doc.posed(at: playhead ?? 0).elements.filter { ids.contains($0.id) }
                    .map { $0.kind == .connector ? Connector.bounds(of: $0, in: doc, index: index) : $0.rotatedBounds }
                guard !boxes.isEmpty else { return false }
                doc.startAnimation()
                let view = boxes.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -40)
                doc.timeline!.setCamera(CameraKey(t: playhead ?? 0, rect: view))
                return true
            } },
            removeCamera: { edit("Remove Camera") { $0.timeline?.camera = nil } },
            repeatSelection: { animate("Repeat Animation") { doc in
                guard var tl = doc.timeline else { return false }
                var any = false
                for id in ids {
                    guard let keys = tl.track(for: id)?.keys, let first = keys.first?.t, let last = keys.last?.t, last > first else { continue }
                    tl.addRepeat(for: id, from: first, to: last)
                    any = true
                }
                doc.timeline = tl
                return any
            } },
            runExtensionCommand: { rt, command in startCommand(rt, command, selection: ids) },
            repeatLastCommand: { repeatLastExtensionCommand() },
            updateExtensionShapes: { updateExtensionShapes() })
    }

    /// An animation edit that can fail or do nothing: beeps instead of committing in either case.
    @MainActor
    private func animate(_ name: String, _ change: (inout DottieDocument) throws -> Bool) {
        var next = document.model
        guard (try? change(&next)) == true else { NSSound.beep(); return }
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    /// Writes the page's animation, drawing the frames in the background so the window stays responsive.
    @MainActor
    private func exportAnimation(_ format: AnimationExportFormat) {
        let model = document.model
        guard model.timeline != nil, !model.elements.isEmpty else { NSSound.beep(); return }
        guard !Exporter.animationTooLong(model) else {
            Alerts.show("This animation is too long to export",
                        "It has more than \(Exporter.maxAnimationFrames) frames. Shorten it or lower its frame rate.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        let base = document.file.pages.count > 1 ? model.name : "Animation"
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do { try format.write(model, to: url); failure = nil } catch { failure = error.localizedDescription }
            await MainActor.run {
                guard let failure else { return }
                Alerts.show("Couldn't export the animation", failure)
            }
        }
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
            Alerts.show(error)
        }
    }
}
