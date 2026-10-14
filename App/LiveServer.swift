import SwiftUI
import Darwin
import DottieKit

/// Open documents by file path, so socket requests can find the right window's model.
@MainActor
final class LiveRegistry {
    static let shared = LiveRegistry()

    private struct Entry {
        weak var document: DrawingDocument?
        weak var undoManager: UndoManager?
    }
    private var entries: [String: Entry] = [:]
    /// The document whose window was most recently key; reachable as path "current", even unsaved.
    private var frontmost: Entry?

    func markFront(_ document: DrawingDocument, undoManager: UndoManager?) {
        frontmost = Entry(document: document, undoManager: undoManager)
    }

    private func entry(forPath path: String) -> Entry? {
        let key = LiveSocket.key(forPath: path)
        if key == LiveSocket.currentKey { return frontmost?.document == nil ? nil : frontmost }
        return entries[key]
    }

    /// Paths of documents currently reachable by agents.
    var openPaths: [String] { entries.filter { $0.value.document != nil }.keys.sorted() }

    /// Call whenever a window's file URL (or undo manager) may have changed.
    func register(_ document: DrawingDocument, fileURL: URL?, undoManager: UndoManager?) {
        entries = entries.filter { $0.value.document != nil && $0.value.document !== document }
        guard let fileURL else { return }
        entries[LiveSocket.key(forPath: fileURL.path)] = Entry(document: document, undoManager: undoManager)
    }

    func handle(_ request: LiveRequest) -> LiveResponse {
        switch request.op {
        case .ping:
            return LiveResponse(open: true)
        case .get:
            guard let path = request.path, let doc = entry(forPath: path)?.document else {
                return LiveResponse(open: false)
            }
            return LiveResponse(open: true, file: doc.file)
        case .put:
            guard let path = request.path, let entry = entry(forPath: path), let doc = entry.document,
                  let new = request.file else { return LiveResponse(open: false) }
            doc.commitFile(new, actionName: request.actionName ?? "Agent Edit", undoManager: entry.undoManager)
            return LiveResponse(open: true)
        }
    }
}

/// Unix-socket listener for `dottie-mcp`. Blocking accept loop on its own thread; each request is
/// handed to the main actor, where the documents live.
final class LiveServer: @unchecked Sendable {
    static let shared = LiveServer()
    private var started = false
    /// True once the socket is bound and listening.
    private(set) var isListening = false

    func start() {
        guard !started else { return }
        started = true
        let path = LiveSocket.path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        guard var addr = LiveSocket.address(path) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        chmod(path, 0o600)
        isListening = true
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            DispatchQueue.global().async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let line = LiveSocket.readLine(fd: fd),
              let request = try? JSONDecoder().decode(LiveRequest.self, from: line) else { return }
        let response = DispatchQueue.main.sync {
            MainActor.assumeIsolated { LiveRegistry.shared.handle(request) }
        }
        if let body = try? JSONEncoder().encode(response) { _ = LiveSocket.writeAll(fd: fd, body) }
    }
}
