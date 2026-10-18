import AppKit
import DottieKit

extension Notification.Name {
    /// A drawing link opened a file whose window should go to an anchor (see `OutsideLinks.take(for:)`).
    static let followDrawingAnchor = Notification.Name("tech.phin.dottie.followDrawingAnchor")
}

/// Following links out of a drawing (`Element.url`): web addresses open in the browser or mail app, and drawings
/// open in Dottie, at the shape or page their `#anchor` names.
@MainActor
enum OutsideLinks {
    /// Anchors to go to in drawings a link is opening, by file. The window showing the file takes its own: when it
    /// appears, or, if it was open already, when told the file has opened.
    private static var pending: [URL: String] = [:]

    private static func key(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    /// Follows `link` from the drawing saved at `base` (nil while it is unsaved). Beeps when there is nothing there.
    static func open(_ link: OutsideLink, from base: URL?) {
        switch link {
        case .web(let address):
            guard let url = URL(string: address) else { NSSound.beep(); return }
            NSWorkspace.shared.open(url)
        case .drawing(_, let anchor):
            guard let url = link.fileURL(relativeTo: base), FileManager.default.fileExists(atPath: url.path) else {
                NSSound.beep(); return
            }
            if let anchor { pending[key(url)] = anchor }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error {
                    pending[key(url)] = nil
                    NSApp.presentError(error)
                    return
                }
                NotificationCenter.default.post(name: .followDrawingAnchor, object: nil)
            }
        }
    }

    /// The anchor a link is waiting to go to in the drawing at `url`, if any; it is handed out once.
    static func take(for url: URL?) -> String? {
        guard let url, !pending.isEmpty else { return nil }
        return pending.removeValue(forKey: key(url))
    }

    /// Whether `link` leads nowhere from the drawing at `base`: another drawing that isn't there.
    static func isBroken(_ link: OutsideLink, from base: URL?) -> Bool {
        guard case .drawing = link else { return false }
        guard let url = link.fileURL(relativeTo: base) else { return true }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
