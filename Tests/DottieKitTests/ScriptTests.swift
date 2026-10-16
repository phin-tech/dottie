import XCTest
@testable import DottieKit

final class ScriptTests: XCTestCase {
    private func run(_ src: String, _ doc: inout DottieDocument, selection: [UUID] = [], limit: TimeInterval = 5) -> ScriptResult {
        DottieScript.run(src, on: &doc, selection: selection, libraries: [.starter], timeLimit: limit)
    }

    func testDrawsConnectsAndReturnsValue() {
        var doc = DottieDocument()
        let r = run("""
            const a = dottie.rect({x: 0, y: 0, text: "A", fill: "#ffeeaa"});
            const b = dottie.ellipse({x: 200, y: 0, text: "B"});
            dottie.connect(a, b, {label: "go", routing: "elbow"});
            console.log("made", dottie.elements().length);
            return {n: dottie.elements().length, fill: a.fill};
            """, &doc)
        XCTAssertNil(r.error)
        XCTAssertEqual(doc.elements.count, 3)
        XCTAssertEqual(doc.elements[2].connector?.routing, .elbow)
        XCTAssertEqual(doc.elements[2].text, "go")
        XCTAssertEqual(r.logs, ["made 3"])
        XCTAssertEqual(r.value, ##"{"n":3,"fill":"#ffeeaa"}"##)
    }

    func testCreatesAGridFloorWithItsCellSize() {
        var doc = DottieDocument()
        let r = run("""
            const room = dottie.rect({x: 0, y: 0, width: 100, height: 100, fill: "#eeeeee", fillStyle: "grid", gridSize: 30});
            return room.gridSize;
            """, &doc)
        XCTAssertNil(r.error)
        XCTAssertEqual(doc.elements[0].style.fillStyle, .grid)
        XCTAssertEqual(doc.elements[0].style.cellSize, 30)
        XCTAssertEqual(r.value, "30")
    }

    func testLastExpressionIsTheValue() {
        var doc = DottieDocument()
        XCTAssertEqual(run("1 + 2", &doc).value, "3")
        XCTAssertNil(run("var x = 1;", &doc).value)
    }

    func testErrorRollsBackEverything() {
        var doc = DottieDocument()
        let r = run("""
            dottie.rect({x: 1, y: 1});
            dottie.connect("nope", "nada");
            """, &doc)
        XCTAssertNotNil(r.error)
        XCTAssertTrue(doc.elements.isEmpty)
    }

    func testCaughtNativeErrorsAreStillCatchableByTheScript() {
        var doc = DottieDocument()
        let r = run("try { dottie.get('bad') } catch (e) { console.log('caught', e.message) }; dottie.rect({x:0,y:0})", &doc)
        XCTAssertNil(r.error)
        XCTAssertEqual(doc.elements.count, 1)
        XCTAssertEqual(r.logs.count, 1)
    }

    func testSyntaxErrorReportsAndLeavesDocumentAlone() {
        var doc = DottieDocument()
        let r = run("dottie.rect({", &doc)
        XCTAssertNotNil(r.error)
        XCTAssertTrue(doc.elements.isEmpty)
    }

    func testRunawayLoopIsStopped() {
        var doc = DottieDocument()
        let started = Date()
        let r = run("dottie.rect({x:0,y:0}); while (true) {}", &doc, limit: 1)
        XCTAssertNotNil(r.error)
        XCTAssertTrue(doc.elements.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testOperationLimitStopsEditingLoops() {
        var doc = DottieDocument()
        let r = run("for (;;) dottie.bounds()", &doc, limit: 0)
        XCTAssertNotNil(r.error)
    }

    func testUpdateRemoveAndSelection() {
        var doc = DottieDocument()
        _ = run("dottie.rect({x:0,y:0,text:'one'}); dottie.rect({x:50,y:0,text:'two'})", &doc)
        let ids = doc.elements.map(\.id)
        let r = run("""
            dottie.selection.forEach(id => dottie.update(id, {text: "picked", fill: "#ff0000", dash: "dashed"}));
            dottie.remove(dottie.elements({text: "two"})[0]);
            return dottie.selection.length;
            """, &doc, selection: [ids[0]])
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, "1")
        XCTAssertEqual(doc.elements.count, 1)
        XCTAssertEqual(doc.elements[0].text, "picked")
        XCTAssertEqual(doc.elements[0].style.dash, .dashed)
        XCTAssertEqual(doc.elements[0].style.fill, RGBA(r: 1, g: 0, b: 0))
    }

    func testBuildAndStencil() {
        var doc = DottieDocument()
        let r = run("""
            const ids = dottie.build({nodes: [{key: "a", text: "A"}, {key: "b", text: "B"}], edges: [{from: "a", to: "b"}], direction: "LR"});
            const first = dottie.stencils()[0];
            const placed = dottie.stencil({name: first.name, x: 0, y: 400});
            return [Object.keys(ids).length, placed.ids.length > 0];
            """, &doc)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.value, "[2,true]")
    }

    func testCamelAndSnakeCaseOptionsAreEquivalent() {
        var doc = DottieDocument()
        let r = run("dottie.rect({x:0,y:0,fill_style:'hachure',strokeWidth:5}); dottie.rect({x:0,y:0,fillStyle:'crossHatch'})", &doc)
        XCTAssertNil(r.error)
        XCTAssertEqual(doc.elements[0].style.fillStyle, .hachure)
        XCTAssertEqual(doc.elements[0].style.strokeWidth, 5)
        XCTAssertEqual(doc.elements[1].style.fillStyle, .crossHatch)
    }

    func testBadEnumNamesTheChoices() {
        var doc = DottieDocument()
        let r = run("dottie.rect({x:0,y:0,dash:'wavy'})", &doc)
        XCTAssertTrue(r.error?.contains("solid, dashed, dotted") == true, r.error ?? "")
    }

    // MARK: require

    private func modulesDir(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dottie-modules-\(UUID().uuidString)")
        for (name, text) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func runWith(_ src: String, modules: [String: String] = [:], dir: URL?, _ doc: inout DottieDocument) -> ScriptResult {
        DottieScript.run(src, on: &doc, libraries: [.starter], modules: modules, modulesDirectory: dir)
    }

    func testRequireLoadsCommonJSAndUMDAndRelativeModules() throws {
        let dir = try modulesDir([
            "umd.js": "(function (root, f) { if (typeof module === 'object' && module.exports) module.exports = f(); else root.umd = f(); })(this, function () { return { twice: function (n) { return n * 2; } }; });",
            "lib/index.js": "exports.name = 'lib'; exports.helper = require('./util').helper;",
            "lib/util.js": "exports.helper = function () { return 'h'; }; exports.up = require('../umd').twice(21);",
        ])
        var doc = DottieDocument()
        let r = runWith("const u = require('umd'); const l = require('lib'); return [u.twice(4), l.name, l.helper(), require('./lib/util').up, require('umd') === u];",
                        dir: dir, &doc)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.value, #"[8,"lib","h",42,true]"#)
    }

    func testRequireCannotEscapeTheModulesFolder() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("dottie-secret-\(UUID().uuidString).js")
        try "module.exports = 'TOPSECRETVALUE'".write(to: outside, atomically: true, encoding: .utf8)
        let dir = try modulesDir(["ok.js": "module.exports = 1"])
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.js"), withDestinationURL: outside)
        var doc = DottieDocument()
        for attempt in ["../" + outside.lastPathComponent, outside.path, "link", "../../etc/passwd", "a/../../x"] {
            let r = runWith("require(\(String(reflecting: attempt)))", dir: dir, &doc)
            XCTAssertNotNil(r.error, attempt)
            XCTAssertNil(r.value, attempt)
            XCTAssertFalse(r.error?.contains("TOPSECRETVALUE") == true)
        }
    }

    func testInlineModulesAndMissingModule() throws {
        var doc = DottieDocument()
        let r = runWith("return require('shapes').make();", modules: ["shapes": "exports.make = () => dottie.rect({x: 1, y: 2}).x"],
                        dir: nil, &doc)
        XCTAssertEqual(r.value, "1")
        XCTAssertEqual(doc.elements.count, 1)
        XCTAssertTrue(runWith("require('nope')", dir: nil, &doc).error?.contains("Cannot find module") == true)
    }

    func testInstalledModulesAreListed() throws {
        let dir = try modulesDir(["a.js": "", "lib/index.js": "", "notes.txt": ""])
        let names = DottieScript.installedModules(in: dir)
        XCTAssertTrue(names.contains("a") && names.contains("lib/index") && names.contains("lodash"))
        XCTAssertFalse(names.contains("notes"))
    }

    func testBundledLibrariesLoadWithoutAModulesFolder() {
        var doc = DottieDocument()
        let r = runWith("""
            const _ = require('lodash'), d3 = require('d3-array'), color = require('d3-color'), h = require('d3-hierarchy');
            const tree = h.hierarchy({name: 'r', children: [{name: 'a'}, {name: 'b'}]});
            h.tree().nodeSize([100, 80])(tree);
            return [_.chunk([1, 2, 3, 4, 5], 2).length, d3.sum([1, 2, 3]), color.color('#ff0000').formatHex(),
                    tree.descendants().length, tree.leaves().map(n => n.x)];
            """, dir: nil, &doc)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.value, ##"[3,6,"#ff0000",3,[-50,50]]"##)
    }

    func testFolderModuleOverridesBundled() throws {
        let dir = try modulesDir(["lodash.js": "module.exports = 'mine'"])
        var doc = DottieDocument()
        XCTAssertEqual(runWith("return require('lodash')", dir: dir, &doc).value, #""mine""#)
    }

    func testDagreLaysOutAGraphAndDayjsFormatsDates() {
        var doc = DottieDocument()
        let r = runWith("""
            const dagre = require('dagre'), dayjs = require('dayjs');
            const g = new dagre.graphlib.Graph();
            g.setGraph({rankdir: 'LR'}); g.setDefaultEdgeLabel(() => ({}));
            ['a', 'b', 'c'].forEach(k => g.setNode(k, {width: 100, height: 40}));
            g.setEdge('a', 'b'); g.setEdge('b', 'c');
            dagre.layout(g);
            const xs = g.nodes().map(k => g.node(k).x);
            return [xs[0] < xs[1] && xs[1] < xs[2], dayjs('2026-10-13').add(1, 'day').format('YYYY-MM-DD')];
            """, dir: nil, &doc)
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(r.value, #"[true,"2026-10-14"]"#)
    }

    func testCheckVetsDownloadedModules() throws {
        let dir = try modulesDir([
            "good.js": "module.exports = 1",
            "needs-dep.js": "module.exports = require('some-dep')",
            "esm.js": "export default 1;",
            "node.js": "module.exports = require('fs')",
            "throws.js": "throw new Error('nope')",
        ])
        XCTAssertEqual(DottieScript.check(module: "good", in: dir), .ok)
        XCTAssertEqual(DottieScript.check(module: "needs-dep", in: dir), .missing("some-dep"))
        XCTAssertEqual(DottieScript.check(module: "node", in: dir), .missing("fs"))
        if case .failed = DottieScript.check(module: "esm", in: dir) {} else { XCTFail("ES module syntax should fail") }
        if case .failed = DottieScript.check(module: "throws", in: dir) {} else { XCTFail("a throwing module should fail") }
        XCTAssertEqual(DottieScript.check(module: "lodash", in: dir), .ok) // bundled
    }

    func testLinksSetByIdOrElementAndClearedWithNull() {
        var doc = DottieDocument()
        let r = run("""
            const a = dottie.rect({x: 0, y: 0, text: "Contents"}), b = dottie.rect({x: 0, y: 400, text: "Billing"});
            const linked = dottie.update(a, {link: b});
            dottie.update(b, {link: a.id});
            const cleared = dottie.update(b, {link: null});
            return [linked.link === b.id, dottie.get(b).link === undefined, cleared.link === undefined];
            """, &doc)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, "[true,true,true]")
        XCTAssertEqual(doc.elements[0].link, doc.elements[1].id)
        XCTAssertNil(doc.elements[1].link)
        XCTAssertNotNil(run("dottie.update(dottie.elements()[0], {link: 'nope'})", &doc).error)
    }

    func testAnchorsFilterAndClear() {
        var doc = DottieDocument()
        let r = run("""
            const a = dottie.rect({x: 0, y: 0, anchor: "Intro"}); dottie.rect({x: 0, y: 200});
            const found = dottie.elements({anchor: "intro"}).map(e => e.id);
            dottie.update(a, {anchor: ""});
            return [found.length === 1 && found[0] === a.id, a.anchor, dottie.get(a).anchor === undefined];
            """, &doc)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.value, "[true,\"Intro\",true]")
    }
}
