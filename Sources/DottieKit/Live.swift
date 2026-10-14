import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Live mode: the Dottie app listens on a Unix socket so `dottie-mcp` can read and edit documents
/// that are open in the app (undoable, no file-change conflicts). Newline-delimited JSON, one
/// request and one response per connection.
public struct LiveRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable { case ping, get, put }
    public var op: Op
    public var path: String?
    public var document: DottieDocument?
    public var actionName: String?
    public init(op: Op, path: String? = nil, document: DottieDocument? = nil, actionName: String? = nil) {
        self.op = op; self.path = path; self.document = document; self.actionName = actionName
    }
}

public struct LiveResponse: Codable, Sendable {
    /// True when the app has the requested document open and handled the request.
    public var open: Bool
    public var document: DottieDocument?
    public var error: String?
    public init(open: Bool, document: DottieDocument? = nil, error: String? = nil) {
        self.open = open; self.document = document; self.error = error
    }
}

public enum LiveSocket {
    /// Short enough for sockaddr_un (104 bytes on Darwin).
    public static var path: String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Dottie")
        return (dir as NSString).appendingPathComponent("live.sock")
    }

    /// Addresses the app's frontmost document, saved or not.
    public static let currentKey = "@current"

    /// One spelling per file, so the app's registry and the MCP server agree on keys.
    public static func key(forPath path: String) -> String {
        if path == "current" || path == currentKey { return currentKey }
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        // Resolve symlinks (/tmp -> /private/tmp) on the part that exists; keep the rest as written.
        var tail: [String] = []
        func real(_ p: String) -> String? {
            guard let r = realpath(p, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
        while url.path != "/", real(url.path) == nil {
            tail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        return tail.reduce(real(url.path) ?? url.path) { ($0 as NSString).appendingPathComponent($1) }
    }

    public static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = UInt8(bitPattern: b) }
        }
        return addr
    }

    /// Reads until a newline (or EOF). Returns nil on error or an empty read.
    public static func readLine(fd: Int32) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 10) { data.append(contentsOf: buf[0..<nl]); return data }
            data.append(contentsOf: buf[0..<n])
        }
        return data.isEmpty ? nil : data
    }

    public static func writeAll(fd: Int32, _ data: Data) -> Bool {
        var bytes = [UInt8](data) + [10]
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeMutableBytes { write(fd, $0.baseAddress! + off, $0.count - off) }
            if n < 0 { if errno == EINTR { continue }; return false }
            off += n
        }
        return true
    }
}

public enum LiveClient {
    /// nil means the app isn't running (or isn't answering); callers fall back to the file.
    public static func send(_ request: LiveRequest, timeout: TimeInterval = 5) -> LiveResponse? {
        guard FileManager.default.fileExists(atPath: LiveSocket.path),
              var addr = LiveSocket.address(LiveSocket.path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, let body = try? JSONEncoder().encode(request),
              LiveSocket.writeAll(fd: fd, body),
              let line = LiveSocket.readLine(fd: fd) else { return nil }
        return try? JSONDecoder().decode(LiveResponse.self, from: line)
    }

    public static func get(path: String) -> DottieDocument? {
        let r = send(LiveRequest(op: .get, path: LiveSocket.key(forPath: path)))
        return r?.open == true ? r?.document : nil
    }

    /// True when the open document accepted the edit; otherwise the caller writes the file.
    public static func put(_ doc: DottieDocument, path: String, actionName: String) -> Bool {
        send(LiveRequest(op: .put, path: LiveSocket.key(forPath: path), document: doc, actionName: actionName))?.open == true
    }
}
