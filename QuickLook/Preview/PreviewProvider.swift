import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import DottieKit

/// Space bar in Finder: a data-based preview of a `.dottie` drawing as a PDF, one PDF page per Dottie page,
/// or of a `.dottielib` stencil library as a sheet of its items.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let file: DottieFile
        if request.fileURL.pathExtension.lowercased() == "dottielib" {
            file = DottieFile(pages: [try StencilLibrary.decode(data).sheet()])
        } else {
            file = try DottieFile.decode(data)
        }
        guard let pdf = Exporter.pdf(file) else { throw CocoaError(.fileReadCorruptFile) }
        let size = Exporter.bounds(of: file.pages[0]).size
        return QLPreviewReply(dataOfContentType: .pdf, contentSize: size) { _ in pdf }
    }
}
