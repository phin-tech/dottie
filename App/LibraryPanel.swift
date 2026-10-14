import SwiftUI
import UniformTypeIdentifiers
import DottieKit

extension UTType {
    static let dottieLibrary = UTType(filenameExtension: "dottielib", conformingTo: .json) ?? .json
}

/// Browse stencil libraries and put their items on the canvas (click, or drag).
struct LibraryPanel: View {
    @ObservedObject var document: DrawingDocument
    var selection: Set<UUID>
    var place: (StencilItem, Bool) -> Void

    @ObservedObject private var store = LibraryStore.shared
    @AppStorage("library.selected") private var selectedID = "builtin"
    @AppStorage("library.keepColors") private var keepColors = false
    @State private var query = ""
    @State private var message: String?

    private var entry: LibraryStore.Entry? { store.entry(selectedID) }

    private var items: [StencilItem] {
        guard let lib = entry?.library else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return lib.items }
        return lib.items.filter { $0.name.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Library", selection: $selectedID) {
                    ForEach(store.entries) { e in Text(e.library.name).tag(e.id) }
                }
                .labelsHidden()
                Menu {
                    Button("Add Selection to Library…", action: addSelection)
                        .disabled(selection.isEmpty || entry?.isBuiltIn != false)
                    Divider()
                    Button("New Library from SVGs…", action: importSVGs)
                    Button("Open Library File…", action: openLibraryFile)
                    Divider()
                    Button("Show Libraries in Finder") {
                        try? FileManager.default.createDirectory(at: LibraryStore.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(LibraryStore.directory)
                    }
                    Button("Reload") { store.reload() }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            Toggle("Keep original colors", isOn: $keepColors)
                .help("Place items with their own colors and exact shapes instead of this drawing's look")
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                    ForEach(items) { item in
                        Tile(item: item, keepColors: keepColors)
                            .onTapGesture { place(item, keepColors) }
                            .onDrag { dragProvider(for: item) }
                            .contextMenu {
                                Button("Place on Canvas") { place(item, keepColors) }
                                if let e = entry, !e.isBuiltIn {
                                    Divider()
                                    Button("Remove from Library", role: .destructive) { remove(item, from: e.id) }
                                }
                            }
                    }
                }
                if items.isEmpty {
                    Text(query.isEmpty ? "This library is empty." : "No matches.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
        }
        .padding(12)
        .onChange(of: store.entries) { _, e in
            if !e.contains(where: { $0.id == selectedID }) { selectedID = "builtin" }
        }
    }

    // MARK: Actions

    private func dragProvider(for item: StencilItem) -> NSItemProvider {
        let data = (try? JSONEncoder().encode(DraggedStencil(item: item, keepOriginalColors: keepColors))) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: DraggedStencil.typeIdentifier, visibility: .all) { done in
            done(data, nil); return nil
        }
        return provider
    }

    private func addSelection() {
        guard let e = entry, !e.isBuiltIn else { return }
        let alert = NSAlert()
        alert.messageText = "Add to “\(e.library.name)”"
        alert.informativeText = "Name for the new item"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Untitled"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let item = StencilLibrary.item(from: document.model, ids: selection, name: field.stringValue)
        else { return }
        do { try store.append(item, to: e.id); message = "Added “\(item.name)”." } catch { NSAlert(error: error).runModal() }
    }

    private func importSVGs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose SVG files, or folders of them, to make a library"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let first = panel.urls[0]
        let name = panel.urls.count == 1 && first.pathExtension.lowercased() != "svg"
            ? first.lastPathComponent : "Imported SVGs"
        do {
            let (id, failed) = try store.importSVGs(from: panel.urls, name: name)
            selectedID = id
            message = failed > 0 ? "Imported with \(failed) unreadable file\(failed == 1 ? "" : "s")." : nil
        } catch {
            message = "No drawable SVGs found."
        }
    }

    private func openLibraryFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.dottieLibrary]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { selectedID = try store.importLibrary(file: url) } catch { NSAlert(error: error).runModal() }
    }

    private func remove(_ item: StencilItem, from id: String) {
        do { try store.remove(item, from: id) } catch { NSAlert(error: error).runModal() }
    }

    private struct Tile: View {
        var item: StencilItem
        var keepColors: Bool
        @ObservedObject private var store = LibraryStore.shared

        var body: some View {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.white)
                    if let img = store.thumbnail(for: item, keepOriginalColors: keepColors) {
                        Image(nsImage: img).resizable().scaledToFit().padding(6)
                    }
                }
                .frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text(item.name).font(.caption).lineLimit(1).truncationMode(.tail)
            }
            .contentShape(Rectangle())
            .help(item.name)
        }
    }
}
