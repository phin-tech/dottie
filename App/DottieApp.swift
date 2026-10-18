import SwiftUI

@main
struct DottieApp: App {
    init() {
        #if DEBUG
        LiveRegistry.shared.debugHandler = { DebugDriver.shared.handle($0) }   // before any window, so `open` works
        #endif
        LiveServer.shared.start()
        AppearanceMode.stored.apply()
        ScriptLibrary.refreshTypes()
        ExtensionHost.shared.start()
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
