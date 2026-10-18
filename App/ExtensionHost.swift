import SwiftUI
import AppKit
import CoreServices
import DottieKit

extension Notification.Name {
    /// An extension error for the Script Console. `object` is the DrawingDocument it concerns, or nil for the key window.
    static let extensionProblem = Notification.Name("tech.phin.dottie.extensionProblem")
}

/// One bundle in the Extensions folder, as Settings lists it: loaded, switched off, or failed.
struct ExtensionBundleRow: Identifiable {
    var url: URL
    /// The manifest's id; nil when the manifest can't be read, so there is nothing to switch.
    var extensionID: String?
    var name: String
    var version: String?
    var shapes: [ShapeDefinition]
    var commands: [CommandDefinition]
    var error: String?
    var disabled: Bool
    var id: URL { url }
}

/// What a command did to a copy of a page, and what it printed.
struct CommandRun {
    var page: DottieDocument
    var changed = false
    var logs: [String] = []
    var value: String?
    var error: String?
    var operations = 0

    /// The Script Console's lines for this run, as Run in the console prints them.
    var output: [String] {
        var lines = logs
        if let error {
            lines.append("Error: \(error)")
            lines.append("Nothing was changed.")
        } else {
            if let value { lines.append("→ \(value)") }
            lines.append(changed ? "Applied (\(operations) calls); undo with ⌘Z." : "No changes.")
        }
        return lines
    }
}

/// The last command run with its parameters, for Repeat Last Command.
struct LastCommand {
    var extensionID: String
    var command: String
    var params: [String: ExtensionValue]
}

/// The app's extensions: one registry, kept on the main actor, reloaded when the Extensions folder changes.
/// Every extension runs on the main thread, as the canvas does.
@MainActor
final class ExtensionHost: ObservableObject {
    static let shared = ExtensionHost()

    let registry = ExtensionRegistry()
    /// Bumped on every reload, so views that show extensions redraw.
    @Published private(set) var revision = 0
    private(set) var last: LastCommand?
    private var stream: FSEventStreamRef?
    private var pendingReload: DispatchWorkItem?

    /// Loaded extensions that are switched on.
    var runtimes: [ExtensionRuntime] { registry.entries.compactMap(\.runtime) }

    /// Every loaded command, grouped by the menus.
    var commands: [(extension: ExtensionRuntime, command: CommandDefinition)] { registry.commands }

    func runtime(for id: String) -> ExtensionRuntime? { registry.runtime(for: id) }

    /// Scans the folder now and starts watching it for changes. Called once at launch.
    func start() {
        reload()
        watch()
    }

    /// Rescans the Extensions folder. Each bundle that fails to load is reported to the Script Console.
    func reload() {
        try? FileManager.default.createDirectory(at: ExtensionRegistry.folder, withIntermediateDirectories: true)
        registry.scan()
        revision += 1
        for entry in registry.entries {
            if let error = entry.error { Self.report("Extension \(entry.name) did not load: \(error)") }
        }
    }

    /// Switches an extension on or off, then reloads.
    func setEnabled(_ id: String, _ on: Bool) {
        do { try ExtensionRegistry.setDisabled(id, !on) }
        catch { Self.report("Could not change the extension: \(error.localizedDescription)") }
        reload()
    }

    /// Every bundle in the folder, for Settings.
    func bundles() -> [ExtensionBundleRow] {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: ExtensionRegistry.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "dottieext" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let off = ExtensionRegistry.disabledIDs()
        return urls.map { url in
            let base = url.deletingPathExtension().lastPathComponent
            let manifest = try? ExtensionRegistry.readManifest(url)
            if let manifest, off.contains(manifest.id) {
                return ExtensionBundleRow(url: url, extensionID: manifest.id, name: manifest.name, version: manifest.version,
                                          shapes: [], commands: [], error: nil, disabled: true)
            }
            let entry = registry.entries.first { $0.runtime?.directory.standardizedFileURL == url.standardizedFileURL }
                ?? registry.entries.first { $0.runtime == nil && $0.name == base }
            if let rt = entry?.runtime {
                return ExtensionBundleRow(url: url, extensionID: rt.manifest.id, name: rt.manifest.name, version: rt.manifest.version,
                                          shapes: rt.shapes, commands: rt.commands, error: nil, disabled: false)
            }
            return ExtensionBundleRow(url: url, extensionID: manifest?.id, name: manifest?.name ?? base, version: manifest?.version,
                                      shapes: [], commands: [], error: entry?.error ?? "Not loaded", disabled: false)
        }
    }

    // MARK: Watching

    /// Watches the folder and its subfolders (where main.js lives), reloading a moment after the last change.
    private func watch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let host = Unmanaged<ExtensionHost>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { host.scheduleReload() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [ExtensionRegistry.folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Several saves in a row reload once.
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: Running

    /// Runs a command on a copy of `page`, as Run Script does: the result is only used if the command finishes.
    func run(_ runtime: ExtensionRuntime, _ command: CommandDefinition, params: [String: ExtensionValue],
             on page: DottieDocument, file: DottieFile, selection: [UUID]) -> CommandRun {
        let source: String
        do { source = try runtime.commandSource(command.id, params: params) }
        catch { return CommandRun(page: page, error: "\(runtime.manifest.name): \(Self.message(error))") }
        var working = page
        let result = DottieScript.run(source, on: &working, in: file, selection: selection, extensions: runtimes)
        if let error = result.error {
            return CommandRun(page: page, logs: result.logs, error: "\(runtime.manifest.name): \(error)")
        }
        return CommandRun(page: working, changed: working != page, logs: result.logs, value: result.value,
                          operations: result.operations)
    }

    /// Remembers a command that was committed, for Repeat Last Command.
    func remember(_ runtime: ExtensionRuntime, _ command: CommandDefinition, params: [String: ExtensionValue]) {
        last = LastCommand(extensionID: runtime.manifest.id, command: command.id, params: params)
    }

    /// Regenerates an extension shape at its current frame. Returns what went wrong; the element keeps its path then.
    func regenerate(_ e: inout Element) -> String? {
        guard let ref = e.extension, let rt = runtime(for: ref.id) else { return nil }
        do {
            try e.regenerate(with: rt)
            return nil
        } catch {
            return "\(rt.manifest.name): \(Self.message(error))"
        }
    }

    /// Regenerates the extension shapes in `page` whose size differs from `old`, so they reflow (a cylinder's lip
    /// keeps its height) instead of stretching. Returns the problems; those shapes keep their paths.
    func reflow(_ page: inout DottieDocument, from old: DottieDocument) -> [String] {
        guard page.elements.contains(where: { $0.extension != nil }) else { return [] }
        let sizes = Dictionary(old.elements.map { ($0.id, CGSize(width: $0.width, height: $0.height)) },
                               uniquingKeysWith: { a, _ in a })
        var problems: [String] = []
        for i in page.elements.indices where page.elements[i].extension != nil {
            let e = page.elements[i]
            guard let was = sizes[e.id], was != CGSize(width: e.width, height: e.height) else { continue }
            if let problem = regenerate(&page.elements[i]) { problems.append(problem) }
        }
        return problems
    }

    /// Regenerates every extension shape in the file, pages and symbols alike, from its stored parameters (after
    /// `migrate`). Returns how many had a loaded extension, and the problems.
    func updateAll(_ file: inout DottieFile) -> (updated: Int, problems: [String]) {
        var updated = 0
        var problems: [String] = []
        func update(_ elements: inout [Element]) {
            for i in elements.indices {
                guard let id = elements[i].extension?.id, runtime(for: id) != nil else { continue }
                updated += 1
                if let problem = regenerate(&elements[i]) { problems.append(problem) }
            }
        }
        for p in file.pages.indices {
            update(&file.pages[p].elements)
            if var symbols = file.pages[p].symbols {
                for s in symbols.indices { update(&symbols[s].elements) }
                file.pages[p].symbols = symbols
            }
        }
        return (updated, problems)
    }

    // MARK: Errors

    /// Sends a message to the Script Console of `document`'s window, or of the key window when there is no document.
    static func report(_ message: String, in document: AnyObject? = nil) {
        NotificationCenter.default.post(name: .extensionProblem, object: document, userInfo: ["text": message])
    }

    /// The error as a person reads it.
    static func message(_ error: Error) -> String {
        (error as? ExtensionError)?.description ?? error.localizedDescription
    }
}
