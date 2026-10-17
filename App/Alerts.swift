import AppKit

/// Telling the person something went wrong or can't be done, the same way everywhere.
@MainActor
enum Alerts {
    /// `title` in bold, `message` under it: as a sheet on `window` when there is one, otherwise on its own.
    static func show(_ title: String, _ message: String, over window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        present(alert, over: window)
    }

    /// An error, under `title` when given; otherwise the error says what happened itself.
    static func show(_ error: Error, title: String? = nil, over window: NSWindow? = nil) {
        if let title { return show(title, error.localizedDescription, over: window) }
        present(NSAlert(error: error), over: window)
    }

    private static func present(_ alert: NSAlert, over window: NSWindow?) {
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
