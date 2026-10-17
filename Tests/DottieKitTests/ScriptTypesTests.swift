import XCTest
@testable import DottieKit

/// dottie.d.ts is written by hand. These keep it in step with the prelude's `dottie` object and the model's
/// enums; the checks that run a compiler use the TypeScript found the way run_script finds it (set DOTTIE_TSC
/// to pick one) and skip when there is none.
final class ScriptTypesTests: XCTestCase {
    private var types: String { DottieScript.typeDefinitions }

    /// The body of `interface API { … }`.
    private func apiInterface() throws -> String {
        let start = try XCTUnwrap(types.range(of: "interface API {"))
        let end = try XCTUnwrap(types.range(of: "\n    }\n", range: start.upperBound..<types.endIndex))
        return String(types[start.upperBound..<end.lowerBound])
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }
    }

    func testDeclaresEveryCallThePreludeDefines() throws {
        let prelude = DottieScript.prelude
        let start = try XCTUnwrap(prelude.range(of: "g.dottie = {"))
        let end = try XCTUnwrap(prelude.range(of: #"\n\s*\};"#, options: .regularExpression, range: start.upperBound..<prelude.endIndex))
        let defined = Set(matches(#"(?:^|[\s,{])([A-Za-z]+): (?:function|kind\(|call\()"#,
                                  in: String(prelude[start.upperBound..<end.lowerBound])))
        XCTAssertGreaterThan(defined.count, 25)
        let declared = Set(matches(#"^ {8}(?:readonly )?([A-Za-z]+)[(:]"#, in: try apiInterface()))
        XCTAssertEqual(defined.subtracting(declared).sorted(), [], "in the prelude but not dottie.d.ts")
        XCTAssertEqual(declared.subtracting(defined).sorted(), [], "in dottie.d.ts but not the prelude")
    }

    func testUnionsMatchTheModelsEnums() {
        func union(_ name: String) -> [String] {
            guard let r = types.range(of: "type \(name) ="), let semi = types[r.upperBound...].firstIndex(of: ";") else { return [] }
            return matches(#""([A-Za-z]+)""#, in: String(types[r.upperBound..<semi]))
        }
        XCTAssertEqual(union("FillStyle"), FillStyle.allCases.map(\.rawValue))
        XCTAssertEqual(union("Dash"), DashStyle.allCases.map(\.rawValue))
        XCTAssertEqual(union("Arrowhead"), Arrowhead.allCases.map(\.rawValue))
        XCTAssertEqual(union("Routing"), Routing.allCases.map(\.rawValue))
        XCTAssertEqual(union("Ease"), Ease.allCases.map(\.rawValue))
        XCTAssertEqual(union("TransitionName"), Transition.allCases.map(\.rawValue))
        XCTAssertEqual(union("Direction"), ["TB", "LR"])
        XCTAssertEqual(union("Playback"), SymbolPlayback.allCases.map(\.rawValue))
        for kind in union("ElementKind") { XCTAssertNotNil(ElementKind(rawValue: kind), kind) }
    }

    func testParsesCompilerOutput() {
        let output = """
            dottie.d.ts(3,1): error TS1005: ';' expected.
            script.js(4,22): error TS2769: No overload matches this call.
              The last overload gave the following error.
                Argument of type '"popin"' is not assignable to parameter of type 'TransitionName'.
            script.js(11,1): error TS1108: A 'return' statement can only be used within a function body.

            """
        let d = DottieScript.parseDiagnostics(output, file: "script.js")
        XCTAssertEqual(d?.map(\.line), [4, 11])
        XCTAssertEqual(d?.first?.code, 2769)
        XCTAssertEqual(d?.first?.message.components(separatedBy: "\n").count, 3)
        XCTAssertEqual(DottieScript.parseDiagnostics("", file: "script.js"), [])
        XCTAssertNil(DottieScript.parseDiagnostics("error TS5083: Cannot read file 'tsconfig.json'.\n", file: "script.js"))
    }

    func testWritesTypesButKeepsAnEditedConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try DottieScript.writeTypes(to: dir).map(\.lastPathComponent), ["dottie.d.ts", "tsconfig.json"])
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tsconfig.json"))
        try Data("stale".utf8).write(to: dir.appendingPathComponent("dottie.d.ts"))
        XCTAssertEqual(try DottieScript.writeTypes(to: dir).map(\.lastPathComponent), ["dottie.d.ts"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("tsconfig.json"), encoding: .utf8), "{}")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("dottie.d.ts"), encoding: .utf8), types)
    }

    // MARK: With a compiler

    private func compiler() throws -> (url: URL, version: String) {
        guard let found = DottieScript.findTypeScript() else { throw XCTSkip("no TypeScript compiler (set DOTTIE_TSC)") }
        return found
    }

    func testDeclarationsAndTheReferenceExampleCheckCleanly() throws {
        let tsc = try compiler()
        // The example ends in a top-level return, which the check leaves out.
        let example = try XCTUnwrap(DottieScript.apiReference.components(separatedBy: "Example\n").last)
        XCTAssertEqual(try DottieScript.typeCheck(example, compiler: tsc.url, version: tsc.version).diagnostics, [])

        // Errors in dottie.d.ts itself aren't reported against a script, so compile the project folder directly.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try DottieScript.writeTypes(to: dir)
        try Data("const a = dottie.rect({x: 0, y: 0});\n".utf8).write(to: dir.appendingPathComponent("one.js"))
        try Data("const a = dottie.note({text: '# Hi'});\n".utf8).write(to: dir.appendingPathComponent("two.js"))
        let p = Process()
        p.executableURL = tsc.url
        p.arguments = ["-p", dir.path, "--pretty", "false"]
        p.environment = ["PATH": tsc.url.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(text, "")
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testReportsMistakesWithSuggestions() throws {
        let tsc = try compiler()
        let check = try DottieScript.typeCheck("""
            const a = dottie.rect({x: 0, y: 0, fil: "#d6f5d6"});
            dottie.connect(a, a, {routing: "elbo"});
            dottie.rekt({});
            const r = require("lodash").chunk([1, 2], 1);
            return r;
            """, compiler: tsc.url, version: tsc.version)
        XCTAssertTrue(check.compiler.hasPrefix("Version "))
        XCTAssertEqual(check.diagnostics.map(\.line), [1, 2, 3])
        XCTAssertEqual(check.diagnostics.map(\.code), [2561, 2820, 2339])
        guard check.diagnostics.count == 3 else { return }
        XCTAssertTrue(check.diagnostics[0].message.contains("'fill'"), check.diagnostics[0].message)
        XCTAssertTrue(check.diagnostics[1].message.contains(#""elbow""#), check.diagnostics[1].message)
    }

    /// The library the check uses must cover what JavaScriptCore runs on macOS 14 (ES2023), or valid scripts
    /// get warnings.
    func testAcceptsES2023() throws {
        let tsc = try compiler()
        let source = """
            const xs = dottie.elements().map(e => e.x).toSorted((a, b) => a - b);
            const last = xs.findLast(x => x > 0) ?? xs.at(-1);
            last
            """
        XCTAssertEqual(try DottieScript.typeCheck(source, compiler: tsc.url, version: tsc.version).diagnostics, [])
        var doc = DottieDocument()
        _ = try DiagramOps.addShape(&doc, kind: .rectangle, frame: nil, at: CGPoint(x: 5, y: 0), text: "A",
                                    fill: nil, stroke: nil, roughness: nil, look: DiagramOps.Look())
        XCTAssertNil(DottieScript.run(source, on: &doc, libraries: [.starter]).error)
    }

    func testIgnoresACommandNamedTscThatIsNotTypeScript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("tsc")
        try Data("#!/bin/sh\necho 'not the TypeScript compiler'\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let found = DottieScript.findTypeScript(environment: ["DOTTIE_TSC": fake.path, "PATH": dir.path])
        XCTAssertNotEqual(found?.url.path, fake.path)
    }
}
