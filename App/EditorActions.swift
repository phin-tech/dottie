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

/// The ways File ▸ Export Animation writes the page's timeline.
enum AnimationExportFormat: CaseIterable {
    case gif, apng, mp4, player, lottieSmooth, lottieExact
    var title: String {
        switch self {
        case .gif: "GIF"
        case .apng: "Animated PNG"
        case .mp4: "MP4 Movie"
        case .player: "Web Page with Player"
        case .lottieSmooth: "Lottie (Smooth)"
        case .lottieExact: "Lottie (Exact)"
        }
    }
    var help: String {
        switch self {
        case .gif: "A looping GIF, for chat and email"
        case .apng: "Like a GIF, in full color"
        case .mp4: "A movie, for slides and video"
        case .player: "One HTML file with play, pause and a scrubber; steps through scenes like slides"
        case .lottieSmooth: "Vector animation for websites and apps, tweened smoothly, lines held steady"
        case .lottieExact: "Vector animation with every frame exactly as Dottie draws it, boil included"
        }
    }
    var fileExtension: String {
        switch self {
        case .gif: "gif"
        case .apng: "png"
        case .mp4: "mp4"
        case .player: "html"
        case .lottieSmooth, .lottieExact: "json"
        }
    }
    /// Draws `model`'s animation in this format and writes it to `url`. Slow for long animations: call it off
    /// the main thread.
    func write(_ model: DottieDocument, to url: URL) throws {
        let data: Data? = switch self {
        case .gif: Exporter.gif(model, scale: 1.5)
        case .apng: Exporter.apng(model, scale: 1.5)
        case .mp4: Exporter.mp4(model, scale: 2)
        case .player: Exporter.player(model, title: model.name).map { Data($0.utf8) }
        case .lottieSmooth: Exporter.lottie(model, mode: .smooth, name: model.name)
        case .lottieExact: Exporter.lottie(model, mode: .exact, name: model.name)
        }
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
    var contentType: UTType {
        switch self {
        case .gif: .gif
        case .apng: .png
        case .mp4: .mpeg4Movie
        case .player: .html
        case .lottieSmooth, .lottieExact: .json
        }
    }
}

/// Window-level commands that act on the document and selection. Reached from the menu bar through
/// a focused scene value, so each window's commands target its own document.
struct EditorActions {
    var selectionCount: Int
    /// Some of the selection is in a group.
    var grouped: Bool
    var group: () -> Void
    var ungroup: () -> Void
    // Symbols
    var instanceSelected: Bool
    var editingSymbol: Bool
    var makeSymbol: () -> Void
    var breakApart: () -> Void
    var editSymbol: () -> Void
    var doneEditingSymbol: () -> Void
    var align: (AlignEdge) -> Void
    var distribute: (DistributeAxis) -> Void
    var reorder: (DottieDocument.ZMove) -> Void
    var export: (ExportFormat) -> Void
    var exportAnimation: (AnimationExportFormat) -> Void
    var openScriptConsole: () -> Void
    var runScriptFile: (URL) -> Void
    var pageCount: Int
    var newPage: () -> Void
    var duplicatePage: () -> Void
    var deletePage: () -> Void
    var showPage: (_ offset: Int) -> Void
    var renamePage: () -> Void
    var movePage: (_ offset: Int) -> Void
    var pageIndex: Int
    // Links
    var linkSelected: Bool
    var linkToElement: () -> Void
    var removeLink: () -> Void
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
    var hasNextPage: Bool
    var magicMove: () -> Void
    var marchSelection: () -> Void
    var toggleBoil: () -> Void
    var toggleSettle: () -> Void
    var clearKeys: () -> Void
    var hasCamera: Bool
    /// The page's scenes, in time order.
    var scenes: [Marker]
    /// Adds a scene marker at a time, or at the playhead when nil.
    var addScene: (Double?) -> Void
    /// Shows the scene before (-1) or after (1) the playhead.
    var showScene: (_ offset: Int) -> Void
    var playScene: (Marker) -> Void
    var frameCamera: () -> Void
    var removeCamera: () -> Void
    var repeatSelection: () -> Void
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
            } })
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
            let alert = NSAlert()
            alert.messageText = "This animation is too long to export"
            alert.informativeText = "It has more than \(Exporter.maxAnimationFrames) frames. Shorten it or lower its frame rate."
            alert.runModal()
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
                let alert = NSAlert()
                alert.messageText = "Couldn't export the animation"
                alert.informativeText = failure
                alert.runModal()
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
            NSAlert(error: error).runModal()
        }
    }
}
