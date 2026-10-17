import Foundation
import CryptoKit

/// The native TypeScript compiler that Settings ▸ Scripting downloads, so scripts are type-checked on a Mac with no
/// TypeScript installed. It is npm's `@typescript/typescript-darwin-<arch>` package at a pinned version: `lib/tsc`
/// (a signed native binary) and the `lib.*.d.ts` files beside it, kept in
/// ~/Library/Application Support/Dottie/TypeScript/lib. Not bundled: a universal tsc is larger than the app.
public enum TypeScriptDownload {
    public static let version = "7.0.2"

    /// npm's package name for this Mac, and its tarball's `dist.integrity`.
    static var package: (name: String, integrity: String) {
        #if arch(arm64)
        ("typescript-darwin-arm64", "sha512-gowzar9MwS/aRWp6f3a4KUqzRjAZjOsmGNCM6LcTgXum+dBfgsBVMN+AgvOCCbguXyick6LJhpBszxMebJ8syA==")
        #else
        ("typescript-darwin-x64", "sha512-SZ9xZInqApNlNGc9s0W1VSsktYSOe9cFqNOIqmN1Gs8SmkjKZYFt017G4VwPxASInODuAdbTW7sXiFUf893RgA==")
        #endif
    }

    public static var tarballURL: URL {
        URL(string: "https://registry.npmjs.org/@typescript/\(package.name)/-/\(package.name)-\(version).tgz")!
    }

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dottie/TypeScript", isDirectory: true)
    }

    /// Where the compiler is once downloaded.
    public static func compiler(in directory: URL = directory) -> URL { directory.appendingPathComponent("lib/tsc") }

    public static func isInstalled(in directory: URL = directory) -> Bool {
        FileManager.default.isExecutableFile(atPath: compiler(in: directory).path)
    }

    /// npm's form of a SHA-512: "sha512-" and the digest in base64.
    static func integrity(of data: Data) -> String { "sha512-" + Data(SHA512.hash(data: data)).base64EncodedString() }

    public struct InstallError: LocalizedError, Equatable {
        public var errorDescription: String?
        public init(errorDescription: String) { self.errorDescription = errorDescription }
    }

    /// Checks `tarball` against the pinned integrity and unpacks its `lib` folder into `directory`, replacing an
    /// older one only once the new one is complete. `expected` is for tests.
    public static func install(_ tarball: Data, into directory: URL = directory, expected: String? = nil) throws {
        guard integrity(of: tarball) == (expected ?? package.integrity) else {
            throw InstallError(errorDescription: "The TypeScript download did not match its expected checksum, so it was not installed.")
        }
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("dottie-tsc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("package.tgz")
        try tarball.write(to: archive)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", stage.path, "package/lib"]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        let lib = stage.appendingPathComponent("package/lib", isDirectory: true)
        guard tar.terminationStatus == 0, fm.isExecutableFile(atPath: lib.appendingPathComponent("tsc").path) else {
            throw InstallError(errorDescription: "The TypeScript download had no compiler in it.")
        }
        // Unpacked by us rather than opened from the Finder, so nothing should carry a quarantine flag; make sure.
        for name in (try? fm.contentsOfDirectory(atPath: lib.path)) ?? [] {
            removexattr(lib.appendingPathComponent(name).path, "com.apple.quarantine", 0)
        }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("lib", isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: lib)
        } else {
            try fm.moveItem(at: lib, to: target)
        }
    }

    /// Removes the downloaded compiler.
    public static func remove(from directory: URL = directory) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
