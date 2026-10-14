import SwiftUI

@main
struct DottieApp: App {
    init() {
        LiveServer.shared.start()
        AppearanceMode.stored.apply()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { DrawingDocument() }) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
        }
        .commands { DottieCommands() }
        DocumentGroup(viewing: LibraryFileDocument.self) { file in
            LibraryViewer(library: file.document.library)
                .navigationTitle(file.document.library.name)
        }
        Settings {
            SettingsView()
        }
    }
}
