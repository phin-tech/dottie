import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DottieKit

extension UTType {
    static let dottie = UTType(exportedAs: "tech.phin.dottie", conformingTo: .json)
}

/// Reference document so edits can register with the window's UndoManager.
final class DrawingDocument: ReferenceFileDocument, ObservableObject, @unchecked Sendable {
    static let readableContentTypes: [UTType] = [.dottie]

    @Published private(set) var file: DottieFile {
        didSet { revision += 1; targetPages = nil }
    }
    /// Bumped on every change to `file`, so views can tell cheaply that something changed.
    private(set) var revision = 0
    private var targetPages: [UUID: UUID]?
    /// The tab on screen. Window state, not saved. Changing it leaves a symbol being edited.
    @Published var currentPageID: UUID {
        didSet { if currentPageID != oldValue { editingSymbol = nil } }
    }
    /// The symbol of the page on screen being edited in its own right (Edit Symbol), if any. Window state.
    @Published var editingSymbol: UUID?
    /// A page whose tab should start renaming (Page ▸ Rename Page…); the page bar takes it and clears it.
    @Published var renamingPage: UUID?

    /// The page on screen, or the symbol being edited as a page of its own.
    var model: DottieDocument {
        let page = file.page(currentPageID) ?? file.pages[0]
        guard let id = editingSymbol, let p = page.editingPage(of: id) else { return page }
        return p
    }

    /// The page on screen, even while one of its symbols is being edited.
    var page: DottieDocument { file.page(currentPageID) ?? file.pages[0] }

    /// The page holding each followable link target, across the file.
    var linkTargetPages: [UUID: UUID] {
        if let t = targetPages { return t }
        let t = file.linkTargetPages
        targetPages = t
        return t
    }

    init() {
        let file = DottieFile()
        self.file = file
        currentPageID = file.pages[0].id
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let file = try DottieFile.decode(data)
        self.file = file
        currentPageID = file.pages[0].id
    }

    func snapshot(contentType: UTType) throws -> Data { try file.encoded() }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    /// Replace one page (matched by id), registering one undo step that restores the previous state.
    @MainActor
    func commit(_ page: DottieDocument, actionName: String, undoManager: UndoManager?) {
        var next = file
        guard next.replacing(page, editing: editingSymbol, on: currentPageID) else { return }
        commitFile(next, actionName: actionName, undoManager: undoManager)
    }

    /// Replace the whole file (page edits, agent edits), as one undo step. `show` switches to that page.
    @MainActor
    func commitFile(_ new: DottieFile, actionName: String, undoManager: UndoManager?, show: UUID? = nil) {
        apply(new, actionName: actionName, undoManager: undoManager, show: show)
    }

    /// Undo and redo land on the page they change, so the change is never out of sight.
    @MainActor
    private func apply(_ new: DottieFile, actionName: String, undoManager: UndoManager?, show: UUID?) {
        let old = file
        guard old != new else { return }
        let oldIndex = old.index(of: currentPageID) ?? 0
        file = new
        if let show, new.index(of: show) != nil { currentPageID = show }
        if new.index(of: currentPageID) == nil {
            // The page went away: land on the one before it.
            currentPageID = new.pages[min(max(oldIndex - 1, 0), new.pages.count - 1)].id
        }
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                let changed = old.pages.first { p in doc.file.page(p.id) != p }?.id
                doc.apply(old, actionName: actionName, undoManager: undoManager, show: changed)
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Live preview of a page during a drag; not undoable until `commit` is called with the pre-drag baseline.
    @MainActor
    func preview(_ page: DottieDocument) {
        var next = file
        if next.replacing(page, editing: editingSymbol, on: currentPageID) { file = next }
    }
}

// MARK: Pages

extension DrawingDocument {
    @MainActor
    func addPage(undoManager: UndoManager?) {
        var next = file
        let id = next.addPage(after: currentPageID)
        commitFile(next, actionName: "New Page", undoManager: undoManager, show: id)
    }

    @MainActor
    func duplicatePage(_ id: UUID, undoManager: UndoManager?) {
        var next = file
        guard let copy = next.duplicatePage(id) else { return }
        commitFile(next, actionName: "Duplicate Page", undoManager: undoManager, show: copy)
    }

    @MainActor
    func deletePage(_ id: UUID, undoManager: UndoManager?) {
        var next = file
        guard next.removePage(id) else { NSSound.beep(); return }
        commitFile(next, actionName: "Delete Page", undoManager: undoManager)
    }

    @MainActor
    func renamePage(_ id: UUID, to name: String, undoManager: UndoManager?) {
        var next = file
        next.renamePage(id, to: name)
        commitFile(next, actionName: "Rename Page", undoManager: undoManager)
    }

    @MainActor
    func movePage(_ id: UUID, to index: Int, undoManager: UndoManager?) {
        var next = file
        next.movePage(id, to: index)
        commitFile(next, actionName: "Move Page", undoManager: undoManager)
    }

    /// Shows the page `offset` tabs away, wrapping around.
    @MainActor
    func showPage(offset: Int) {
        guard let i = file.index(of: currentPageID) else { return }
        let n = file.pages.count
        currentPageID = file.pages[((i + offset) % n + n) % n].id
    }
}

extension DottieFile {
    /// Replaces the page `page` (matched by id), or, when it is symbol `symbol` being edited on page `host`, stores it
    /// back into that symbol.
    mutating func replacing(_ page: DottieDocument, editing symbol: UUID?, on host: UUID) -> Bool {
        guard let symbol, page.id == symbol, var owner = self.page(host) else { return replace(page) }
        owner.storeSymbol(page)
        return replace(owner)
    }
}

// MARK: Symbols

extension DrawingDocument {
    /// Edits the symbol instance `id` shows, in its own right.
    @MainActor
    func editSymbol(of id: UUID) {
        guard let symbol = model.elements.first(where: { $0.id == id })?.symbol, page.symbolIndex[symbol] != nil else { return }
        editingSymbol = symbol
    }
}
