import XCTest
@testable import DottieKit

/// The compiler Settings ▸ Scripting downloads. The real download runs only with DOTTIE_TEST_DOWNLOAD_TSC=1.
final class TypeScriptDownloadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// An npm-shaped tarball whose `package/lib/tsc` answers --version with `version`.
    private func tarball(version: String) throws -> Data {
        let src = dir.appendingPathComponent("src/package/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let tsc = src.appendingPathComponent("tsc")
        try Data("#!/bin/sh\necho 'Version \(version)'\n".utf8).write(to: tsc)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tsc.path)
        try Data("// lib".utf8).write(to: src.appendingPathComponent("lib.es2023.d.ts"))
        let out = dir.appendingPathComponent("src/package.tgz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", out.path, "-C", dir.appendingPathComponent("src").path, "package"]
        try tar.run(); tar.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: dir.appendingPathComponent("src")) }
        return try Data(contentsOf: out)
    }

    func testRefusesATarballThatDoesNotMatchItsChecksum() throws {
        let data = try tarball(version: "7.0.2")
        let target = dir.appendingPathComponent("TypeScript")
        XCTAssertThrowsError(try TypeScriptDownload.install(data, into: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing is written")
    }

    func testInstallsAndIsFoundBeforePATH() throws {
        let target = dir.appendingPathComponent("TypeScript")
        let first = try tarball(version: "7.0.1")
        try TypeScriptDownload.install(first, into: target, expected: TypeScriptDownload.integrity(of: first))
        XCTAssertTrue(TypeScriptDownload.isInstalled(in: target))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("lib/lib.es2023.d.ts").path))

        let found = DottieScript.findTypeScript(environment: ["PATH": "/nonexistent"], downloaded: TypeScriptDownload.compiler(in: target))
        XCTAssertEqual(found?.version, "Version 7.0.1")

        // A newer download replaces the old one.
        let second = try tarball(version: "7.0.2")
        try TypeScriptDownload.install(second, into: target, expected: TypeScriptDownload.integrity(of: second))
        let tsc = try String(contentsOf: TypeScriptDownload.compiler(in: target), encoding: .utf8)
        XCTAssertTrue(tsc.contains("7.0.2"))

        try TypeScriptDownload.remove(from: target)
        XCTAssertFalse(TypeScriptDownload.isInstalled(in: target))
    }

    func testTheRealDownloadChecksAScript() async throws {
        guard ProcessInfo.processInfo.environment["DOTTIE_TEST_DOWNLOAD_TSC"] == "1" else {
            throw XCTSkip("set DOTTIE_TEST_DOWNLOAD_TSC=1 to download TypeScript \(TypeScriptDownload.version)")
        }
        let (data, _) = try await URLSession.shared.data(from: TypeScriptDownload.tarballURL)
        let target = dir.appendingPathComponent("TypeScript")
        try TypeScriptDownload.install(data, into: target)
        let found = try XCTUnwrap(DottieScript.findTypeScript(environment: ["PATH": "/nonexistent"],
                                                               downloaded: TypeScriptDownload.compiler(in: target)))
        XCTAssertEqual(found.version, "Version \(TypeScriptDownload.version)")
        let check = try DottieScript.typeCheck(##"dottie.rect({x: 0, y: 0, fil: "#d6f5d6"});"##, compiler: found.url, version: found.version)
        XCTAssertEqual(check.diagnostics.map(\.code), [2561])
    }
}
