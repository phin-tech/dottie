import SwiftUI

@main
struct DottieApp: App {
    init() { LiveServer.shared.start() }

    var body: some Scene {
        DocumentGroup(newDocument: { DrawingDocument() }) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
        }
        .commands { DottieCommands() }
        Settings {
            SettingsView()
        }
    }
}
