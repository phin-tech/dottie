import SwiftUI

@main
struct DottieApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { DrawingDocument() }) { file in
            ContentView(document: file.document)
        }
        .commands { DottieCommands() }
        Settings {
            SettingsView()
        }
    }
}
