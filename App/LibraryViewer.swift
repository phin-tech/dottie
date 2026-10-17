import SwiftUI
import UniformTypeIdentifiers
import DottieKit

/// A `.dottielib` opened for viewing. Read-only: installing it copies it into the app's libraries.
final class LibraryFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.dottieLibrary]
    static let writableContentTypes: [UTType] = []

    let library: StencilLibrary

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        library = try StencilLibrary.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}

/// Browse every item of a library at a readable size, see what it holds, and take items out of it.
struct LibraryViewer: View {
    var library: StencilLibrary
    @ObservedObject private var store = LibraryStore.shared
    @State private var query = ""
    @State private var tag: String?
    @State private var selected: UUID?
    @State private var keepColors = false
    @State private var roughness = Style().roughness
    @State private var message: String?

    private var tags: [String] { Array(Set(library.items.flatMap(\.tags))).sorted() }

    private var items: [StencilItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return library.items.filter { item in
            (tag == nil || item.tags.contains(tag!))
                && (q.isEmpty || item.name.lowercased().contains(q) || item.tags.contains { $0.lowercased().contains(q) })
        }
    }

    private var current: StencilItem? { library.items.first { $0.id == selected } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Search \(library.items.count) items", text: $query).textFieldStyle(.roundedBorder)
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Chip(title: "All", on: tag == nil) { tag = nil }
                            ForEach(tags, id: \.self) { t in Chip(title: t, on: tag == t) { tag = tag == t ? nil : t } }
                        }
                    }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(items) { item in
                            ViewerTile(item: item, keepColors: keepColors, roughness: roughness, isSelected: item.id == selected)
                                .onTapGesture { selected = item.id }
                        }
                    }
                    .padding(2)
                    if items.isEmpty {
                        Text("No matches.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 360)

            Detail(item: current, keepColors: $keepColors, roughness: $roughness, message: $message, libraryName: library.name,
                   install: install)
                .frame(minWidth: 260, idealWidth: 300)
        }
        .frame(minWidth: 700, minHeight: 440)
        .onAppear { if selected == nil { selected = library.items.first?.id } }
    }

    private func install() {
        do {
            try store.create(library)
            message = "Installed “\(library.name)”. It is in the Library tab of every drawing."
        } catch {
            Alerts.show(error)
        }
    }

    private struct Chip: View {
        var title: String
        var on: Bool
        var action: () -> Void
        var body: some View {
            Button(action: action) {
                Text(title).font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private struct ViewerTile: View {
        var item: StencilItem
        var keepColors: Bool
        var roughness: Double
        var isSelected: Bool
        @ObservedObject private var store = LibraryStore.shared

        var body: some View {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.white)
                    if let img = store.thumbnail(for: item, keepOriginalColors: keepColors, roughness: roughness) {
                        Image(nsImage: img).resizable().scaledToFit().padding(10)
                    }
                }
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                  lineWidth: isSelected ? 2 : 1))
                Text(item.name).font(.caption).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
    }

    private struct Detail: View {
        var item: StencilItem?
        @Binding var keepColors: Bool
        @Binding var roughness: Double
        @Binding var message: String?
        var libraryName: String
        var install: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                if let item {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.white)
                        if let img = preview(item) { Image(nsImage: img).resizable().scaledToFit().padding(16) }
                    }
                    .frame(height: 220)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))

                    Text(item.name).font(.title3.weight(.semibold))
                    Text("\(Int(item.width.rounded())) × \(Int(item.height.rounded())) · \(item.elements.count) element\(item.elements.count == 1 ? "" : "s")"
                         + (item.tags.isEmpty ? "" : " · " + item.tags.joined(separator: ", ")))
                        .font(.callout).foregroundStyle(.secondary)

                    if item.imported {
                        Toggle("Original colors and clean lines", isOn: $keepColors)
                        Slider(value: $roughness, in: 0...3) { Text("Sketchiness") }.disabled(keepColors)
                    } else {
                        Text("Drawn in its own style.").font(.caption).foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Copy", action: { copy(item) }).help("Copy, then paste into a drawing")
                        Menu("Export") {
                            Button("PNG…") { export(item, png: true) }
                            Button("SVG…") { export(item, png: false) }
                        }
                    }
                } else {
                    Text("Select an item").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer(minLength: 0)
                Divider()
                Button("Install “\(libraryName)” in Dottie", action: install)
                    .help("Add this library to the Library tab of every drawing")
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(14)
        }

        private func doc(_ item: StencilItem) -> DottieDocument {
            item.document(keepOriginalColors: keepColors, roughness: roughness)
        }

        private func preview(_ item: StencilItem) -> NSImage? {
            Exporter.png(doc(item), scale: 3).flatMap { NSImage(data: $0) }
        }

        /// Same pasteboard format as copying shapes on the canvas, so ⌘V in a drawing places the item.
        private func copy(_ item: StencilItem) {
            let k = item.readableScale
            let els = item.placed(keepOriginalColors: keepColors, roughness: roughness, scale: k)
            guard let data = try? JSONEncoder().encode(els) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: CanvasNSView.pasteboardType)
            message = "Copied “\(item.name)”. Paste it into a drawing."
        }

        private func export(_ item: StencilItem, png: Bool) {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [png ? .png : .svg]
            panel.nameFieldStringValue = item.name + (png ? ".png" : ".svg")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let d = doc(item)
            let data = png ? Exporter.png(d, scale: 3) : Exporter.svg(d).data(using: .utf8)
            do {
                guard let data else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            } catch { Alerts.show(error) }
        }
    }
}
