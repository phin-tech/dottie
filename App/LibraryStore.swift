import AppKit
import DottieKit

/// The stencil libraries on this Mac: the built-in shapes, plus every `.dottielib` in
/// ~/Library/Application Support/Dottie/Libraries. Shared by all windows.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    struct Entry: Identifiable, Equatable {
        var id: String
        var library: StencilLibrary
        /// nil for the built-in library, which is never written.
        var url: URL?
        var isBuiltIn: Bool { url == nil }
    }

    @Published private(set) var entries: [Entry] = []
    private struct Thumb: Hashable { var id: UUID; var original: Bool; var roughness: Double }
    private var thumbnails: [Thumb: NSImage] = [:]

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dottie/Libraries", isDirectory: true)
    }

    init() { reload() }

    func reload() {
        var found = [Entry(id: "builtin", library: .starter, url: nil)]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        where url.pathExtension == "dottielib" {
            guard let data = try? Data(contentsOf: url), let lib = try? StencilLibrary.decode(data) else { continue }
            found.append(Entry(id: url.path, library: lib, url: url))
        }
        entries = found
        thumbnails = [:]
    }

    func entry(_ id: String?) -> Entry? { entries.first { $0.id == id } ?? entries.first }

    /// The item drawn the way it will be placed (the caller sets it on a white tile).
    func thumbnail(for item: StencilItem, keepOriginalColors: Bool, roughness: Double = Style().roughness) -> NSImage? {
        let key = Thumb(id: item.id, original: keepOriginalColors, roughness: roughness)
        if let hit = thumbnails[key] { return hit }
        guard let data = Exporter.png(item.document(keepOriginalColors: keepOriginalColors, roughness: roughness), scale: 2),
              let image = NSImage(data: data) else { return nil }
        thumbnails[key] = image
        return image
    }

    private func fileURL(forName name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safe.isEmpty ? "Library" : safe
        var url = Self.directory.appendingPathComponent(base + ".dottielib")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.directory.appendingPathComponent("\(base) \(n).dottielib"); n += 1
        }
        return url
    }

    private func write(_ lib: StencilLibrary, to url: URL) throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try lib.encoded().write(to: url, options: .atomic)
    }

    /// Creates a library file and returns its entry id.
    @discardableResult
    func create(_ lib: StencilLibrary) throws -> String {
        let url = fileURL(forName: lib.name)
        try write(lib, to: url)
        reload()
        return url.path
    }

    func append(_ item: StencilItem, to entryID: String) throws {
        guard let e = entries.first(where: { $0.id == entryID }), let url = e.url else { return }
        var lib = e.library
        lib.items.append(item)
        try write(lib, to: url)
        reload()
    }

    /// Applies `change` to a user library and saves it. The built-in library is never written.
    func update(_ entryID: String, _ change: (inout StencilLibrary) -> Void) throws {
        guard let e = entries.first(where: { $0.id == entryID }), let url = e.url else { return }
        var lib = e.library
        change(&lib)
        try write(lib, to: url)
        reload()
    }

    func remove(_ item: StencilItem, from entryID: String) throws {
        guard let e = entries.first(where: { $0.id == entryID }), let url = e.url else { return }
        var lib = e.library
        lib.items.removeAll { $0.id == item.id }
        try write(lib, to: url)
        reload()
    }

    /// Imports `.svg` files (looking inside folders, one level of nesting at a time) as a new library.
    /// Returns the new entry id and how many files could not be read.
    func importSVGs(from urls: [URL], name: String) throws -> (id: String, failed: Int) {
        var files: [URL] = []
        func collect(_ url: URL, depth: Int) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            if isDir.boolValue, depth < 4 {
                let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { collect(k, depth: depth + 1) }
            } else if url.pathExtension.lowercased() == "svg" {
                files.append(url)
            }
        }
        urls.forEach { collect($0, depth: 0) }
        let named = files.prefix(5000).compactMap { url -> (name: String, data: Data)? in
            guard let d = try? Data(contentsOf: url) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, d)
        }
        let (lib, failed) = StencilLibrary.fromSVGs(name: name, files: Array(named))
        guard !lib.items.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let id = try create(lib)
        return (id, failed.count + (files.count - named.count))
    }

    /// Imports an `.excalidrawlib` as a new library named for the file.
    func importExcalidrawLibrary(file: URL) throws -> String {
        let lib = try StencilLibrary.fromExcalidraw(name: file.deletingPathExtension().lastPathComponent,
                                                    data: Data(contentsOf: file))
        return try create(lib)
    }

    /// Imports a draw.io file as a library with one item per page.
    func importDrawio(file: URL) throws -> String {
        let lib = try StencilLibrary.fromDrawio(name: file.deletingPathExtension().lastPathComponent,
                                                data: Data(contentsOf: file))
        return try create(lib)
    }

    func importLibrary(file: URL) throws -> String {
        let lib = try StencilLibrary.decode(Data(contentsOf: file))
        return try create(lib)
    }
}
