import SwiftUI
import UniformTypeIdentifiers
import DottieKit

extension UTType {
    static let dottie = UTType(exportedAs: "tech.phin.dottie", conformingTo: .json)
}

/// Reference document so edits can register with the window's UndoManager.
final class DrawingDocument: ReferenceFileDocument, ObservableObject, @unchecked Sendable {
    static let readableContentTypes: [UTType] = [.dottie]

    @Published private(set) var model: DottieDocument

    init() { model = DottieDocument() }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        model = try DottieDocument.decode(data)
    }

    func snapshot(contentType: UTType) throws -> Data { try model.encoded() }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    /// Replace the model, registering one undo step that restores the previous state.
    @MainActor
    func commit(_ new: DottieDocument, actionName: String, undoManager: UndoManager?) {
        let old = model
        guard old != new else { return }
        model = new
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.commit(old, actionName: actionName, undoManager: undoManager) }
        }
        undoManager?.setActionName(actionName)
    }

    /// Live preview during a drag; not undoable until `commit` is called with the pre-drag baseline.
    @MainActor
    func preview(_ new: DottieDocument) { model = new }
}
