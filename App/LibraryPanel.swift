import SwiftUI
import UniformTypeIdentifiers
import DottieKit

extension UTType {
    static let dottieLibrary = UTType(exportedAs: "tech.phin.dottielib", conformingTo: .json)
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
    /// The name being asked for, in a popover by what it names.
    @State private var naming: Naming?

    private enum Naming: Equatable {
        case library, newItem, item(UUID), tags(UUID)
    }

    /// Whether the popover asking for `n` is showing; closing it stops asking.
    private func asking(_ n: Naming) -> Binding<Bool> {
        Binding(get: { naming == n }, set: { if !$0, naming == n { naming = nil } })
    }

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
                    Button("Rename Library…") { naming = .library }
                        .disabled(entry?.isBuiltIn != false)
                    Button("Add Selection to Library…") { naming = .newItem }
                        .disabled(selection.isEmpty || entry?.isBuiltIn != false)
                    Divider()
                    Button("New Library from SVGs…", action: importSVGs)
                    Button("New Library from Excalidraw Library…", action: importExcalidrawLibrary)
                    Button("New Library from draw.io File…", action: importDrawio)
                    Button("Open Library File…", action: openLibraryFile)
                    Divider()
                    Button("Open Library in Viewer") {
                        if let url = entry?.url { NSWorkspace.shared.open(url) }
                    }
                    .disabled(entry?.url == nil)
                    Button("Show Libraries in Finder") {
                        try? FileManager.default.createDirectory(at: LibraryStore.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(LibraryStore.directory)
                    }
                    Button("Reload") { store.reload() }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .popover(isPresented: asking(.library), arrowEdge: .bottom) {
                if let e = entry {
                    NamePopover(title: "Rename Library", systemImage: "books.vertical", name: e.library.name) { n in
                        change(e.id) { $0.name = n }
                    }
                }
            }
            .popover(isPresented: asking(.newItem), arrowEdge: .bottom) {
                if let e = entry {
                    NamePopover(title: "Add to “\(e.library.name)”", systemImage: "plus.square.on.square", name: "Untitled",
                                hint: "The selection becomes a new item in this library.", commitTitle: "Add") { addSelection(named: $0) }
                }
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
                            .popover(isPresented: asking(.item(item.id)), arrowEdge: .bottom) {
                                if let e = entry {
                                    NamePopover(title: "Rename Item", systemImage: "square.on.square", name: item.name) { n in
                                        change(e.id) { $0.renameItem(item.id, to: n) }
                                    }
                                }
                            }
                            .popover(isPresented: asking(.tags(item.id)), arrowEdge: .bottom) {
                                if let e = entry {
                                    NamePopover(title: "Edit Tags", systemImage: "tag", name: item.tags.joined(separator: ", "),
                                                placeholder: "Tags", hint: "Separate tags with commas. Search finds items by them.",
                                                commitTitle: "Save", problem: { _ in nil }) { t in
                                        change(e.id) { $0.setTags(item.id, t.split(separator: ",").map(String.init)) }
                                    }
                                }
                            }
                            .contextMenu {
                                Button("Place on Canvas") { place(item, keepColors) }
                                if let e = entry, !e.isBuiltIn {
                                    Divider()
                                    Button("Rename…") { naming = .item(item.id) }
                                    Button("Edit Tags…") { naming = .tags(item.id) }
                                    Button("Duplicate") { change(e.id) { $0.duplicateItem(item.id) } }
                                    Button("Move to Start") { change(e.id) { $0.moveItem(item.id, to: 0) } }
                                    Button("Move to End") { change(e.id) { $0.moveItem(item.id, to: .max) } }
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

    private func addSelection(named name: String) {
        guard let e = entry, !e.isBuiltIn,
              let item = StencilLibrary.item(from: document.model, ids: selection, name: name) else { return }
        do { try store.append(item, to: e.id); message = "Added “\(item.name)”." } catch { Alerts.show(error) }
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

    private func importExcalidrawLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "excalidrawlib") ?? .json, .json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Excalidraw library (.excalidrawlib)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            selectedID = try store.importExcalidrawLibrary(file: url)
            message = nil
        } catch {
            message = "That file is not an Excalidraw library, or it is empty."
        }
    }

    private func importDrawio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["drawio", "xml"].compactMap { UTType(filenameExtension: $0) } + [.xml]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a draw.io file; each page becomes one item"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            selectedID = try store.importDrawio(file: url)
            message = nil
        } catch {
            message = "That file is not a draw.io diagram, or it is empty."
        }
    }

    private func openLibraryFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.dottieLibrary]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { selectedID = try store.importLibrary(file: url) } catch { Alerts.show(error) }
    }

    private func change(_ id: String, _ edit: (inout StencilLibrary) -> Void) {
        do { try store.update(id, edit) } catch { Alerts.show(error) }
    }

    private func remove(_ item: StencilItem, from id: String) {
        do { try store.remove(item, from: id) } catch { Alerts.show(error) }
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
