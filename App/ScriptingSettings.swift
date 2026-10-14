import SwiftUI
import CryptoKit
import DottieKit

/// A library the user added by name or URL, recorded so it can be listed and removed.
struct AddedLibrary: Codable, Identifiable, Equatable {
    var module: String
    var source: String
    var sha256: String
    var id: String { module }
}

/// Downloads and removes optional script libraries in the modules folder, one library at a time.
@MainActor
final class ScriptLibraryInstaller: ObservableObject {
    enum Phase: Equatable { case idle, working, failed(String) }

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var phases: [String: Phase] = [:]
    @Published private(set) var added: [AddedLibrary] = []
    @Published private(set) var addStatus: AddStatus = .idle

    enum AddStatus: Equatable { case idle, working(String), failed(String), done(String) }

    private var directory: URL { DottieScript.modulesDirectory }

    init() { refresh() }

    private var manifestURL: URL { directory.appendingPathComponent(".libraries.json") }

    func refresh() {
        installed = Set(OptionalLibraries.all.filter { lib in
            lib.files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.module + ".js").path) }
        }.map(\.id))
        let list = (try? JSONDecoder().decode([AddedLibrary].self, from: Data(contentsOf: manifestURL))) ?? []
        added = list.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.module + ".js").path) }
    }

    private func saveManifest(_ list: [AddedLibrary]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: manifestURL, options: .atomic)
    }

    func removeAdded(_ library: AddedLibrary) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(library.module + ".js"))
        try? saveManifest(added.filter { $0 != library })
        refresh()
    }

    func phase(_ id: String) -> Phase { phases[id] ?? .idle }

    func setInstalled(_ on: Bool, _ library: OptionalLibrary) {
        guard phase(library.id) != .working else { return }
        if on { install(library) } else { remove(library) }
    }

    private func remove(_ library: OptionalLibrary) {
        for f in library.files { try? FileManager.default.removeItem(at: directory.appendingPathComponent(f.module + ".js")) }
        phases[library.id] = .idle
        refresh()
    }

    private func install(_ library: OptionalLibrary) {
        phases[library.id] = .working
        let target = directory
        Task {
            do {
                // Fetch and verify everything before writing anything, so a failure leaves no half-installed library.
                var downloaded: [(String, Data)] = []
                for f in library.files {
                    let (data, response) = try await URLSession.shared.data(from: OptionalLibraries.baseURL.appendingPathComponent(f.path))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError.http(f.module) }
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest == f.sha256 else { throw InstallError.checksum(f.module) }
                    downloaded.append((f.module, data))
                }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for (module, data) in downloaded { try data.write(to: target.appendingPathComponent(module + ".js"), options: .atomic) }
                phases[library.id] = .idle
            } catch {
                phases[library.id] = .failed(error.localizedDescription)
            }
            refresh()
        }
    }

    // MARK: Add by name or URL

    private static let nodeBuiltins: Set<String> = [
        "fs", "path", "os", "util", "events", "stream", "crypto", "http", "https", "zlib", "buffer", "child_process",
        "url", "assert", "net", "tls", "process", "readline", "worker_threads", "vm", "querystring", "string_decoder",
    ]
    private static let packageName = try! NSRegularExpression(pattern: #"^(@[a-z0-9~][a-z0-9._~-]*/)?[a-z0-9~][a-z0-9._~-]*$"#)

    private struct Fetched { var module: String; var source: String; var data: Data }
    private struct AddError: LocalizedError { var errorDescription: String? }

    private func fetch(_ url: URL, limit: Int = 5_000_000) async throws -> Data {
        guard url.scheme == "https" else { throw AddError(errorDescription: "Only https:// addresses are allowed.") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AddError(errorDescription: "Not found: \(url.absoluteString)") }
        guard data.count <= limit else { throw AddError(errorDescription: "That file is larger than 5 MB.") }
        return data
    }

    /// Splits `name`, `name@range` and `@scope/name@range`.
    private func splitSpec(_ spec: String) -> (name: String, range: String) {
        let at = spec.dropFirst().firstIndex(of: "@")
        guard let at else { return (spec, "latest") }
        return (String(spec[..<at]), String(spec[spec.index(after: at)...]))
    }

    private func isPackageName(_ s: String) -> Bool {
        Self.packageName.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Fetches a published npm package's browser build from jsDelivr, pinned to the version that `range` resolves to.
    private func fetchPackage(_ spec: String) async throws -> Fetched {
        let (name, range) = splitSpec(spec)
        guard isPackageName(name) else { throw AddError(errorDescription: "'\(spec)' is not a package name or https address.") }
        let resolve = URL(string: "https://data.jsdelivr.com/v1/package/resolve/npm/\(name)@\(range)")!
        guard let version = (try? JSONSerialization.jsonObject(with: try await fetch(resolve)) as? [String: Any])?["version"] as? String else {
            throw AddError(errorDescription: "No package named '\(name)' (version \(range)).")
        }
        let info = URL(string: "https://data.jsdelivr.com/v1/packages/npm/\(name)@\(version)?structure=flat")!
        guard var path = (try? JSONSerialization.jsonObject(with: try await fetch(info)) as? [String: Any])?["default"] as? String else {
            throw AddError(errorDescription: "\(name) does not publish a browser build.")
        }
        if !path.hasSuffix(".js") { path += ".js" }
        let file = URL(string: "https://cdn.jsdelivr.net/npm/\(name)@\(version)\(path)")!
        return Fetched(module: name, source: file.absoluteString, data: try await fetch(file))
    }

    private func fetchURL(_ url: URL) async throws -> Fetched {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".min") { name.removeLast(4) }
        guard isPackageName(name.lowercased()) else { throw AddError(errorDescription: "Cannot derive a module name from \(url.lastPathComponent).") }
        return Fetched(module: name.lowercased(), source: url.absoluteString, data: try await fetch(url))
    }

    /// Adds a library by npm name (`dayjs`, `lodash@4.17.21`) or https URL to a .js file. The file is loaded with the
    /// script engine before it is kept, and missing dependencies on other packages are fetched the same way.
    func add(_ input: String) {
        let spec = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { return }
        if case .working = addStatus { return }
        addStatus = .working("Downloading \(spec)…")
        let target = directory
        Task {
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("dottie-add-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: target, to: stage) }
                else { try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true) }

                var fetched: [Fetched] = []
                func stageFile(_ f: Fetched) throws {
                    let url = stage.appendingPathComponent(f.module + ".js")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try f.data.write(to: url)
                    fetched.append(f)
                }
                let first = spec.hasPrefix("https://") ? try await fetchURL(URL(string: spec) ?? URL(fileURLWithPath: "/")) : try await fetchPackage(spec)
                guard let head = String(data: first.data, encoding: .utf8)?.prefix(200), !head.lowercased().contains("<!doctype html") else {
                    throw AddError(errorDescription: "That address did not return JavaScript.")
                }
                try stageFile(first)

                var attempts = 0
                while true {
                    switch DottieScript.check(module: first.module, in: stage) {
                    case .ok:
                        let sources = Dictionary(fetched.map { ($0.module, $0) }, uniquingKeysWith: { a, _ in a })
                        var manifest = added.filter { sources[$0.module] == nil }
                        for (module, f) in sources {
                            let url = target.appendingPathComponent(module + ".js")
                            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try f.data.write(to: url, options: .atomic)
                            let digest = SHA256.hash(data: f.data).map { String(format: "%02x", $0) }.joined()
                            manifest.append(AddedLibrary(module: module, source: f.source, sha256: digest))
                        }
                        try saveManifest(manifest)
                        let names = fetched.map(\.module).sorted()
                        addStatus = .done(names.count == 1 ? "Added \(names[0]). Use require(\"\(names[0])\")."
                                          : "Added \(names.joined(separator: ", ")). Use require(\"\(first.module)\").")
                        refresh()
                        return
                    case .missing(let dep):
                        attempts += 1
                        guard !Self.nodeBuiltins.contains(dep) else {
                            throw AddError(errorDescription: "\(first.module) needs Node's built-in '\(dep)', which scripts do not have.")
                        }
                        guard isPackageName(dep), attempts <= 8, !fetched.contains(where: { $0.module == dep }) else {
                            throw AddError(errorDescription: "\(first.module) needs '\(dep)', which could not be added automatically.")
                        }
                        addStatus = .working("Downloading dependency \(dep)…")
                        try stageFile(try await fetchPackage(dep))
                    case .failed(let message):
                        throw AddError(errorDescription: "\(first.module) cannot run in a script (browser-ready single-file builds work; "
                            + "ES modules and Node packages do not): \(message)")
                    }
                }
            } catch {
                addStatus = .failed(error.localizedDescription)
            }
        }
    }

    private enum InstallError: LocalizedError {
        case http(String), checksum(String)
        var errorDescription: String? {
            switch self {
            case .http(let m): "Could not download \(m)."
            case .checksum(let m): "\(m) did not match its expected checksum, so it was not installed."
            }
        }
    }
}

extension ScriptLibraryInstaller.AddStatus {
    var isWorking: Bool { if case .working = self { true } else { false } }
}

struct ScriptingSettings: View {
    @StateObject private var installer = ScriptLibraryInstaller()
    @State private var newLibrary = ""

    private func binding(_ lib: OptionalLibrary) -> Binding<Bool> {
        Binding(get: { installer.installed.contains(lib.id) }, set: { installer.setInstalled($0, lib) })
    }

    var body: some View {
        Form {
            Section {
                ForEach(OptionalLibraries.all) { lib in
                    HStack(alignment: .firstTextBaseline) {
                        Toggle(isOn: binding(lib)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lib.title)
                                Text(lib.detail).font(.caption).foregroundStyle(.secondary)
                                if case .failed(let message) = installer.phase(lib.id) {
                                    Text(message).font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                        .disabled(installer.phase(lib.id) == .working)
                        if installer.phase(lib.id) == .working { ProgressView().controlSize(.small) }
                    }
                }
            } header: {
                Text("Optional libraries")
            } footer: {
                Text("Checking a library downloads its pinned version into your modules folder; unchecking removes it. Use it from a script with require(\"name\").")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    TextField("Package name or https:// link", text: $newLibrary, prompt: Text("dayjs, lodash@4, or https://…/lib.min.js"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { installer.add(newLibrary) }
                    Button("Add") { installer.add(newLibrary) }
                        .disabled(newLibrary.trimmingCharacters(in: .whitespaces).isEmpty || installer.addStatus.isWorking)
                }
                switch installer.addStatus {
                case .idle: EmptyView()
                case .working(let m): HStack { ProgressView().controlSize(.small); Text(m).foregroundStyle(.secondary) }
                case .failed(let m): Text(m).foregroundStyle(.red)
                case .done(let m): Text(m).foregroundStyle(.green)
                }
                ForEach(installer.added) { lib in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lib.module)
                            Text(lib.source).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove") { installer.removeAdded(lib) }
                    }
                }
            } header: {
                Text("Add a library")
            } footer: {
                Text("Fetches a browser-ready single-file build from jsDelivr (or a link you paste), pins its version, and tries it in the script engine before keeping it. Libraries it depends on are fetched too.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("lodash, d3-array, d3-color, d3-hierarchy, dagre, dayjs") {
                    Text("always available").foregroundStyle(.secondary)
                }
            } header: {
                Text("Built in")
            }
            Section {
                Button("Show Modules Folder") {
                    try? FileManager.default.createDirectory(at: DottieScript.modulesDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(DottieScript.modulesDirectory)
                    installer.refresh()
                }
            } footer: {
                Text("Any other single-file CommonJS or UMD .js you put there can be required by name.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { installer.refresh() }
    }
}
