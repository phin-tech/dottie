import Foundation
import QuickLookThumbnailing
import DottieKit

/// Finder icons for `.dottie` drawings (the first page, on its theme's page color) and `.dottielib` libraries.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let doc: DottieDocument
        do {
            let data = try Data(contentsOf: request.fileURL)
            if request.fileURL.pathExtension.lowercased() == "dottielib" {
                doc = try StencilLibrary.decode(data).sheet()
            } else {
                doc = try DottieFile.decode(data).pages[0]
            }
        } catch {
            return handler(nil, error)
        }
        // Size the reply to the drawing, not the square maximum, so Finder doesn't letterbox it.
        let size = Exporter.fittedSize(of: doc, in: request.maximumSize)
        guard size.width > 0, size.height > 0 else { return handler(nil, CocoaError(.fileReadCorruptFile)) }
        handler(QLThumbnailReply(contextSize: size) { ctx in
            Exporter.draw(doc, in: ctx, size: size)
            return true
        }, nil)
    }
}
