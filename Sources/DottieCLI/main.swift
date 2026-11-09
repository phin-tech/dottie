import Foundation
import CoreGraphics
import DottieKit

let version = DottieVersion.current

let usage = """
dottie \(version): render and manage Dottie drawings from the command line.

USAGE
  dottie render <file.dottie | file.mmd>... [-o <out>] [options]
  dottie inspect <file.dottie> [-p <page>] [--at <seconds>]... [--state <vars>] [--disk]
  dottie simulate <file.dottie> [-p <page>] [--scene <name>] [--click <element> | --wait <s> | --snapshot <out.png>]...
                  [--record <out.mp4|gif|png>]
  dottie library list
  dottie library install <file.dottielib>...
  dottie script-types [<dir>]
  dottie ext check <bundle.dottieext>
  dottie --help | --version

RENDER
  Writes png, svg, pdf, html, mermaid (.mmd, a flowchart of the shapes and connectors), gif, apng, mp4, js
  or lottie (.json). An animated page renders as a still of its poster frame, except to gif, apng, mp4 and
  lottie, and to html, which becomes a player. js is the page and dottie.js's player in one script: <script src="drawing.js"></script>
  shows it where the tag is, playing if it is animated (--at makes it a still, --clean draws it clean).
  The format comes from the extension of -o, or --format.
  With no -o the result is written next to the input (drawing.dottie -> drawing.png).
  A Mermaid flowchart (.mmd, .mermaid, or flowchart text on stdin) is laid out and rendered too.
  When the Dottie app has a .dottie file open, its unsaved edits (an agent's MCP edits too) are what render
  and inspect read, with a note on stderr when they differ from the saved file.

  -o, --output <path>   Output file, or "-" for stdout. Needs a single input.
  -d, --out-dir <dir>   Directory for the results of one or more inputs.
  -f, --format <fmt>    png (default), svg, pdf, html, mermaid, gif, apng, mp4, js or lottie. apng is the
                        gif's animation in full color (a .png of an animated page is still its poster);
                        lottie is the animation as Lottie JSON (.json), all vector.
      --lottie-mode <m> smooth (default): tweened by the player, lines held steady; exact: every frame
                        as the gif draws it, boil included.
  -p, --page <page>     Page (tab) to render, by name or 1-based number (default the first).
  -s, --scale <n>       PNG, APNG, GIF and MP4 pixel scale, 0.25 to 8 (default 2).
      --clean           Render precisely instead of sketchy.
      --sketchy         Render sketchy even if the drawing is clean.
      --transparent     No page background (png, apng, svg, html, lottie).
      --allow-logic     html, js: let the page's click logic run (it carries the engine, about 850 KB).
      --all-pages       html, js: every page in one file, links between them working; each page shown
                        gets its own address (#Page), so Back goes back. --page is the page to start on.
      --split           html: every page as a web page of its own, in a folder (-o, or the input's
                        name): index.html for the first, the rest named after their pages, linked.
      --at <seconds>    For an animated page, the moment to draw (default its poster frame, the end
                        unless set). An html export becomes a still; gif, apng, mp4 and lottie ignore it.
      --state <vars>    Starting values for the page's variables, like down=true,east=false (a bare name
                        is true, !name false): the render shows that state, and a player starts in it.
      --disk            Read the saved file, not the app's open copy with its unsaved edits.

INSPECT
  Prints, as JSON, what each page resolves to with no drawing: every element's frame, rotation,
  opacity, reveal, seed and stacking order, each connector's route, and the camera's view and the
  scene, at the given times (default a spread across the animation, its scenes and both ends).
  dottie.js is tested against this (see web/ and `just goldens`).

  -p, --page <page>     Only this page, by name or 1-based number (default every page).
      --at <seconds>    A time to inspect; repeat for several.
      --state <vars>    Starting values for the page's variables, as for render.
      --disk            Read the saved file, not the app's open copy with its unsaved edits.

SIMULATE
  Plays the page as <dottie-player> would, without a browser, through the steps in order, and prints a line
  after each: the time, the scene, whether it is playing, the variables and what their conditions hide.
  Playing stops at each scene (and at the end when there are scenes) unless the scene loops.

  -p, --page <page>     Page to play, by name or 1-based number (default the first).
      --scene <name>    Start at this scene, playing (default the start, as the player does).
      --state <vars>    Starting values for the page's variables, as for render.
      --click <element> Click an element, by id (or its first characters), text or anchor: sets and flips
                        its variables and plays its scene. Links and pages are reported, not followed.
      --wait <seconds>  Let it play this long.
      --next            Press Next: on to the next scene.
      --snapshot <png>  Write a PNG of what is drawn now.
      --record <out>    (Repeatable.) Record the whole run, every frame a viewer would see from the start to the last step,
                        as a looping .mp4, .gif or animated .png. End with a --wait, or the last click's
                        result never shows.
      --scale <n>       Snapshot and recording pixel scale (default 2; 1 for a GIF).
      --disk            Read the saved file, not the app's open copy with its unsaved edits.

LIBRARY
  list      Shows the libraries installed for the Dottie app.
  install   Copies .dottielib files into ~/Library/Application Support/Dottie/Libraries.

SCRIPT-TYPES
  Writes dottie.d.ts, TypeScript declarations for the `dottie` object scripts use, and a tsconfig.json
  (unless there is one) into <dir>, default ~/Library/Application Support/Dottie/Scripts. Editors then
  complete and check the .js scripts there, and `tsc -p <dir>` lists mistakes. Install TypeScript with
  `npm install -g typescript` or `brew install typescript`.

EXIT STATUS
  0 on success, 1 if any input failed, 2 for a usage error.

"""

struct CLIError: Error { var message: String; var code: Int32 = 1 }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("dottie: " + message + "\n").utf8))
    exit(code)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data(("dottie: " + message + "\n").utf8))
}

enum Format: String, CaseIterable {
    case png, svg, pdf, html, mermaid, gif, apng, mp4, js, lottie
    init?(extension ext: String) {
        switch ext.lowercased() {
        case "htm": self = .html
        case "json": self = .lottie
        case "mmd": self = .mermaid
        case "mjs": self = .js
        default: self.init(rawValue: ext.lowercased())
        }
    }
    var fileExtension: String { self == .mermaid ? "mmd" : self == .lottie ? "json" : rawValue }
}

struct RenderOptions {
    var inputs: [String] = []
    var output: String?
    var outDir: String?
    var format: Format?
    var page: String?
    var scale = 2.0
    var roughness: Double?
    var transparent = false
    /// HTML and js: let the page's click logic run (ADR 0007).
    var allowLogic = false
    /// HTML and js: every page in one file (`Exporter.player(file:)`).
    var allPages = false
    /// HTML: every page as a file of its own, in a folder (`Exporter.playerPages`).
    var split = false
    var at: Double?
    var lottieMode = Exporter.LottieMode.smooth
    /// Read the file on disk even when the app has it open with unsaved edits.
    var disk = false
    /// Starting values for the page's variables (`--state`), so the render shows that state.
    var state: [String: Var] = [:]
}

/// `--state down=true,east=false` (or `down,!east`), merged into `into`.
func parseState(_ spec: String, into: inout [String: Var]) throws {
    do { into.merge(try PageState.assignments(spec)) { _, new in new } }
    catch { throw CLIError(message: "--state: \(error)", code: 2) }
}

/// The drawing at `url`: the app's open copy unless `disk` (see `LiveClient.current`), with a note on stderr when
/// that has edits the file doesn't. `onDisk` is the file's bytes, nil when it can't be read.
func drawing(at url: URL, named input: String, onDisk: Data?, disk: Bool, verb: String) throws -> DottieFile {
    var saved: DottieFile?
    var problem: CLIError?
    if let onDisk {
        do { saved = try DottieFile.decode(onDisk) }
        catch { problem = CLIError(message: "\(input): not a Dottie drawing (\(error.localizedDescription))") }
    } else {
        problem = CLIError(message: "\(input): cannot read file")
    }
    if !disk, let (file, unsaved) = LiveClient.current(path: url.path, disk: saved) {
        if unsaved { warn("\(url.lastPathComponent) is open in Dottie; \(verb) its unsaved state (--disk for the saved file)") }
        return file
    }
    if let saved { return saved }
    throw problem!
}

func parseRender(_ args: [String]) throws -> RenderOptions {
    var o = RenderOptions()
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count else { throw CLIError(message: "\(flag) needs a value", code: 2) }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--output": o.output = try value(a)
        case "-d", "--out-dir": o.outDir = try value(a)
        case "-f", "--format":
            let v = try value(a)
            guard let f = Format(extension: v) else {
                throw CLIError(message: "unknown format '\(v)' (png, svg, pdf, html, mermaid, gif, apng, mp4, js, lottie)", code: 2)
            }
            o.format = f
        case "-p", "--page": o.page = try value(a)
        case "-s", "--scale":
            let v = try value(a)
            guard let n = Double(v), n > 0 else { throw CLIError(message: "--scale must be a positive number", code: 2) }
            o.scale = min(max(n, 0.25), 8)
        case "--clean": o.roughness = 0
        case "--sketchy": o.roughness = 1
        case "--transparent": o.transparent = true
        case "--allow-logic": o.allowLogic = true
        case "--all-pages": o.allPages = true
        case "--split": o.split = true
        case "--disk": o.disk = true
        case "--state": try parseState(try value(a), into: &o.state)
        case "--lottie-mode":
            let v = try value(a)
            guard let m = Exporter.LottieMode(rawValue: v) else { throw CLIError(message: "--lottie-mode is smooth or exact", code: 2) }
            o.lottieMode = m
        case "--at":
            let v = try value(a)
            guard let n = Double(v), n.isFinite, n >= 0, n <= Timeline.maxDuration else {
                throw CLIError(message: "--at must be a time in seconds, 0 to \(Int(Timeline.maxDuration))", code: 2)
            }
            o.at = n
        case "-":
            o.inputs.append(a)
        default:
            if a.hasPrefix("-") { throw CLIError(message: "unknown option \(a)", code: 2) }
            o.inputs.append(a)
        }
        i += 1
    }
    guard !o.inputs.isEmpty else { throw CLIError(message: "render needs at least one .dottie or .mmd file", code: 2) }
    if o.output != nil, o.outDir != nil { throw CLIError(message: "use -o or --out-dir, not both", code: 2) }
    if o.output != nil, o.inputs.count > 1 { throw CLIError(message: "-o takes a single input; use --out-dir for several", code: 2) }
    if o.inputs.contains("-"), o.output == nil, o.outDir == nil {
        throw CLIError(message: "reading stdin needs -o (a file, or \"-\" for stdout)", code: 2)
    }
    if o.allPages, o.split { throw CLIError(message: "use --all-pages or --split, not both", code: 2) }
    if o.allPages || o.split, o.at != nil { throw CLIError(message: "--at shows one page; it doesn't go with --all-pages or --split", code: 2) }
    if o.split {
        if o.page != nil { throw CLIError(message: "--split writes every page; --page doesn't go with it", code: 2) }
        if o.output == "-" { throw CLIError(message: "--split writes a folder, not stdout", code: 2) }
        if let f = o.format, f != .html { throw CLIError(message: "--split writes html", code: 2) }
    }
    return o
}

func absolute(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
}

func render(_ doc: DottieDocument, as format: Format, title: String, _ o: RenderOptions) throws -> Data {
    if format == .js {
        // The drawing goes in as it is; the player poses it, so --at and --clean become its attributes.
        guard !doc.elements.isEmpty else { throw CLIError(message: "the drawing is empty; nothing to render") }
        return Data(try Exporter.script(doc, options: Exporter.ScriptOptions(at: o.at, clean: o.roughness == 0, allowLogic: o.allowLogic)).utf8)
    }
    let plays = format == .gif || format == .apng || format == .mp4 || format == .lottie || (format == .html && (doc.timeline != nil || doc.usesState) && o.at == nil)
    var doc = plays ? doc : o.at.map(doc.resolved) ?? doc.still
    // The web page draws its frames as it plays, so only the formats that bake frames in have a limit.
    if plays, format != .html, Exporter.animationTooLong(doc) {
        throw CLIError(message: "the animation has more than \(Exporter.maxAnimationFrames) frames; shorten it or lower its fps")
    }
    if let r = o.roughness { doc = doc.withRoughness(r) }
    guard !doc.elements.isEmpty else { throw CLIError(message: "the drawing is empty; nothing to render") }
    let white = RGBA(r: 1, g: 1, b: 1)
    switch format {
    case .png:
        guard let d = Exporter.png(doc, scale: o.scale, background: o.transparent ? nil : CGColor(gray: 1, alpha: 1))
        else { throw CLIError(message: "rendering failed") }
        return d
    case .pdf:
        guard let d = Exporter.pdf(doc) else { throw CLIError(message: "rendering failed") }
        return d
    case .svg:
        return Data(Exporter.svg(doc, background: o.transparent ? nil : white).utf8)
    case .html:
        if plays {
            guard let page = Exporter.player(doc, title: title, allowLogic: o.allowLogic) else { throw CLIError(message: "rendering failed") }
            return Data(page.utf8)
        }
        return Data(Exporter.html(doc, title: title, background: o.transparent ? nil : white).utf8)
    case .mermaid:
        return Data(Exporter.mermaid(doc).utf8)
    case .gif:
        guard let d = Exporter.gif(doc, scale: o.scale) else { throw CLIError(message: "rendering failed") }
        return d
    case .lottie:
        guard let d = Exporter.lottie(doc, mode: o.lottieMode, transparent: o.transparent, name: title)
        else { throw CLIError(message: "rendering failed") }
        return d
    case .apng:
        guard let d = Exporter.apng(doc, scale: o.scale, background: o.transparent ? nil : CGColor(gray: 1, alpha: 1))
        else { throw CLIError(message: "rendering failed") }
        return d
    case .js:
        preconditionFailure("handled above")
    case .mp4:
        guard let d = Exporter.mp4(doc, scale: o.scale) else { throw CLIError(message: "rendering failed") }
        return d
    }
}

/// `file` ready to export every page: `--state` starts the first page shown in it, `--clean` and `--sketchy` apply
/// to every page.
func everyPage(_ file: DottieFile, start: Int, _ o: RenderOptions, roughen: Bool = true) throws -> DottieFile {
    var f = file
    f.pages[start] = f.pages[start].starting(with: o.state)
    if roughen, let r = o.roughness { f.pages = f.pages.map { $0.withRoughness(r) } }
    guard f.pages.contains(where: { !$0.elements.isEmpty }) else { throw CLIError(message: "the drawing is empty; nothing to render") }
    return f
}

/// `--all-pages`: every page in one web page or script.
func renderAll(_ file: DottieFile, start: Int, as format: Format, title: String, _ o: RenderOptions) throws -> Data {
    let f = try everyPage(file, start: start, o, roughen: format != .js)
    if format == .js {
        var options = Exporter.ScriptOptions(clean: o.roughness == 0, allowLogic: o.allowLogic)
        options.history = true
        options.page = o.page
        return Data(try Exporter.script(file: f, options: options).utf8)
    }
    guard let page = Exporter.player(file: f, title: title, start: o.page, allowLogic: o.allowLogic) else {
        throw CLIError(message: "rendering failed")
    }
    return Data(page.utf8)
}

/// `--split`: every page as a web page of its own, by file name.
func renderPages(_ file: DottieFile, start: Int, title: String, _ o: RenderOptions) throws -> [(name: String, html: String)] {
    guard let pages = Exporter.playerPages(try everyPage(file, start: start, o), title: title, allowLogic: o.allowLogic) else {
        throw CLIError(message: "rendering failed")
    }
    return pages
}

func runRender(_ args: [String]) -> Int32 {
    let o: RenderOptions
    do { o = try parseRender(args) } catch let e as CLIError { fail(e.message, code: e.code) } catch { fail("\(error)") }

    var format = o.format ?? (o.split ? .html : nil)
    if format == nil, let out = o.output, out != "-" { format = Format(extension: URL(fileURLWithPath: out).pathExtension) }
    if o.allPages, let f = format, f != .html, f != .js { fail("--all-pages writes html or js", code: 2) }
    guard let format = format ?? (o.output == nil || o.output == "-" ? .png : nil) else {
        fail("cannot tell the format from '\(o.output ?? "")'; use .png, .svg, .pdf, .html, .mmd, .gif, .apng, .mp4, .js, .json (Lottie) or --format", code: 2)
    }
    if o.output == "-", format == .png || format == .pdf || format == .gif || format == .apng || format == .mp4, isatty(STDOUT_FILENO) != 0 {
        fail("refusing to write binary \(format.rawValue) to a terminal; redirect it or use -o <file>", code: 2)
    }

    var failures = 0
    for input in o.inputs {
        do {
            let data: Data?
            var name: String
            var directory: URL
            if input == "-" {
                data = FileHandle.standardInput.readDataToEndOfFile()
                name = "drawing"; directory = absolute(".")
            } else {
                let url = absolute(input)
                data = try? Data(contentsOf: url)
                name = url.deletingPathExtension().lastPathComponent
                directory = url.deletingLastPathComponent()
            }
            let file: DottieFile
            let isMermaid = input == "-" ? MermaidImporter.isFlowchart(String(decoding: data ?? Data(), as: UTF8.self))
                : MermaidImporter.fileExtensions.contains(absolute(input).pathExtension.lowercased())
            if isMermaid {
                guard let data else { throw CLIError(message: "\(input): cannot read file") }
                do { file = try MermaidImporter.file(from: String(decoding: data, as: UTF8.self), roughness: o.roughness ?? 1) }
                catch { throw CLIError(message: "\(input): \(error.localizedDescription)") }
            } else if input == "-" {
                do { file = try DottieFile.decode(data ?? Data()) }
                catch { throw CLIError(message: "\(input): not a Dottie drawing (\(error.localizedDescription))") }
            } else {
                file = try drawing(at: absolute(input), named: input, onDisk: data, disk: o.disk, verb: "rendering")
            }
            var doc = file.pages[0]
            var start = 0
            if let spec = o.page {
                guard let i = file.pageIndex(matching: spec) else {
                    throw CLIError(message: "\(input): no page '\(spec)' (pages: \(file.pages.map(\.name).joined(separator: ", ")))")
                }
                doc = file.pages[i]
                start = i
            }
            if o.split {
                let folder = o.output.map(absolute) ?? (o.outDir.map(absolute) ?? directory).appendingPathComponent(name)
                for (page, html) in try renderPages(file, start: start, title: name, o) {
                    let target = folder.appendingPathComponent(page)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data(html.utf8).write(to: target, options: .atomic)
                    print(target.path)
                }
                continue
            }
            let bytes = o.allPages ? try renderAll(file, start: start, as: format, title: name, o)
                : try render(doc.starting(with: o.state), as: format, title: name, o)

            if o.output == "-" {
                FileHandle.standardOutput.write(bytes)
                continue
            }
            let target: URL
            if let out = o.output { target = absolute(out) }
            else { target = (o.outDir.map(absolute) ?? directory).appendingPathComponent(name + "." + format.fileExtension) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
            print(target.path)
        } catch let e as CLIError {
            warn(e.message); failures += 1
        } catch {
            warn("\(input): \(error.localizedDescription)"); failures += 1
        }
    }
    return failures == 0 ? 0 : 1
}

func runInspect(_ args: [String]) -> Int32 {
    var input: String?, page: String?, times: [Double] = [], disk = false, state: [String: Var] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        func value() -> String {
            i += 1
            guard i < args.count else { fail("\(a) needs a value", code: 2) }
            return args[i]
        }
        switch a {
        case "-p", "--page": page = value()
        case "--at":
            let v = value()
            guard let n = Double(v), n.isFinite, n >= 0 else { fail("--at must be a time in seconds", code: 2) }
            times.append(n)
        case "--json": break   // the only output there is
        case "--disk": disk = true
        case "--state":
            do { try parseState(value(), into: &state) } catch let e as CLIError { fail(e.message, code: 2) } catch { fail("\(error)") }
        default:
            if a.hasPrefix("-") || input != nil { fail("unknown option \(a)", code: 2) }
            input = a
        }
        i += 1
    }
    guard let input else { fail("inspect needs a .dottie file", code: 2) }
    var file: DottieFile
    do {
        file = try drawing(at: absolute(input), named: input, onDisk: try? Data(contentsOf: absolute(input)), disk: disk,
                           verb: "inspecting")
    } catch let e as CLIError { fail(e.message) } catch { fail("\(error)") }
    file.pages = file.pages.map { $0.starting(with: state) }
    var pages: [Int]?
    if let page {
        guard let p = file.pageIndex(matching: page) else { fail("\(input): no page '\(page)'") }
        pages = [p]
    }
    do {
        FileHandle.standardOutput.write(try Inspector.json(Inspector.file(file, pages: pages, times: times.isEmpty ? nil : times)))
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch { fail("\(error)") }
    return 0
}

func runSimulate(_ args: [String]) -> Int32 {
    enum Step { case click(String), wait(Double), next, snapshot(String) }
    var input: String?, page: String?, scene: String?, disk = false, state: [String: Var] = [:], scale: Double?
    var records: [String] = []
    var steps: [Step] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        func value() -> String {
            i += 1
            guard i < args.count else { fail("\(a) needs a value", code: 2) }
            return args[i]
        }
        switch a {
        case "-p", "--page": page = value()
        case "--scene": scene = value()
        case "--disk": disk = true
        case "--state":
            do { try parseState(value(), into: &state) } catch let e as CLIError { fail(e.message, code: 2) } catch { fail("\(error)") }
        case "--click": steps.append(.click(value()))
        case "--next": steps.append(.next)
        case "--wait":
            let v = value()
            guard let n = Double(v), n.isFinite, n >= 0, n <= Timeline.maxDuration * 10 else { fail("--wait must be seconds", code: 2) }
            steps.append(.wait(n))
        case "--snapshot": steps.append(.snapshot(value()))
        case "--record":
            let out = value()
            guard ["mp4", "gif", "png", "apng"].contains(URL(fileURLWithPath: out).pathExtension.lowercased()) else {
                fail("--record writes .mp4, .gif or .png", code: 2)
            }
            records.append(out)
        case "-s", "--scale":
            guard let n = Double(value()), n > 0 else { fail("--scale must be a positive number", code: 2) }
            scale = min(max(n, 0.25), 8)
        default:
            if a.hasPrefix("-") || input != nil { fail("unknown option \(a)", code: 2) }
            input = a
        }
        i += 1
    }
    guard let input else { fail("simulate needs a .dottie file", code: 2) }
    let file: DottieFile
    do {
        file = try drawing(at: absolute(input), named: input, onDisk: try? Data(contentsOf: absolute(input)), disk: disk,
                           verb: "simulating")
    } catch let e as CLIError { fail(e.message) } catch { fail("\(error)") }
    var doc = file.pages[0]
    if let page {
        guard let p = file.pageIndex(matching: page) else { fail("\(input): no page '\(page)'") }
        doc = file.pages[p]
    }
    var sim: Simulation
    do { sim = try Simulation(doc.starting(with: state), scene: scene) } catch { fail("\(error)") }
    if !records.isEmpty { sim.record() }
    print("start: \(sim.summary)")
    var failures = 0
    for step in steps {
        do {
            switch step {
            case .click(let target):
                let did = try sim.click(target)
                print("click \(target): \(did). \(sim.summary)")
            case .wait(let s):
                sim.wait(s)
                print("wait \(s)s: \(sim.summary)")
            case .next:
                sim.nextScene()
                print("next: \(sim.summary)")
            case .snapshot(let path):
                let picture = sim.picture
                guard !picture.elements.isEmpty, let png = Exporter.png(picture, scale: scale ?? 2, background: CGColor(gray: 1, alpha: 1))
                else { throw CLIError(message: "snapshot: nothing is drawn now") }
                let url = absolute(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
                print("snapshot \(url.path): \(sim.summary)")
            }
        } catch let e as CLIError {
            warn(e.message); failures += 1
        } catch {
            warn("\(error)"); failures += 1
        }
    }
    for record in records {
        guard let recording = sim.recording else { break }
        let url = absolute(record)
        let data: Data? = switch url.pathExtension.lowercased() {
        case "mp4": Exporter.mp4(recording, scale: scale ?? 2)
        case "gif": Exporter.gif(recording, scale: scale ?? 1)
        default: Exporter.apng(recording, scale: scale ?? 2)
        }
        guard let data else {
            warn(recording.frames.count > Exporter.maxAnimationFrames
                 ? "record: more than \(Exporter.maxAnimationFrames) frames; wait less" : "record: rendering failed")
            failures += 1; continue
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { warn("record: \(error)"); failures += 1; continue }
        print(String(format: "recorded %@: %d frames, %.1fs", url.path, recording.frames.count, Double(recording.frames.count) / recording.fps))
    }
    return failures == 0 ? 0 : 1
}

func runLibrary(_ args: [String]) -> Int32 {
    guard let sub = args.first else { fail("library needs a subcommand: list or install", code: 2) }
    switch sub {
    case "list":
        let dir = StencilLibrary.defaultDirectory
        print("Built-in: Basics (\(StencilLibrary.starter.items.count) items)")
        for (url, lib) in StencilLibrary.load(directory: dir) {
            print("\(lib.name) (\(lib.items.count) items)  \(url.path)")
        }
        return 0
    case "install":
        let files = Array(args.dropFirst())
        guard !files.isEmpty else { fail("library install needs one or more .dottielib files", code: 2) }
        var failures = 0
        for f in files {
            let url = absolute(f)
            guard let data = try? Data(contentsOf: url) else { warn("\(f): cannot read file"); failures += 1; continue }
            guard let lib = try? StencilLibrary.decode(data) else { warn("\(f): not a Dottie library"); failures += 1; continue }
            do {
                let dest = try lib.install()
                print("Installed \"\(lib.name)\" (\(lib.items.count) items) at \(dest.path)")
            } catch {
                warn("\(f): \(error.localizedDescription)"); failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    default:
        fail("unknown library subcommand '\(sub)' (list, install)", code: 2)
    }
}

func runScriptTypes(_ args: [String]) -> Int32 {
    guard args.count <= 1 else { fail("script-types takes at most one directory", code: 2) }
    if let a = args.first, a.hasPrefix("-") { fail("unknown option '\(a)' for script-types. Run 'dottie --help'.", code: 2) }
    let dir = args.first.map(absolute) ?? DottieScript.scriptsDirectory
    do {
        for url in try DottieScript.writeTypes(to: dir) { print("Wrote \(url.path)") }
    } catch { fail("\(dir.path): \(error.localizedDescription)") }
    return 0
}

/// `dottie ext check`: loads a bundle as Dottie does, generates each shape with its defaults and runs each command
/// on an empty drawing, then reports an advisory type check of main.js when a TypeScript compiler is installed.
func runExtension(_ args: [String]) -> Int32 {
    guard let sub = args.first else { fail("ext needs a subcommand: check", code: 2) }
    switch sub {
    case "check":
        guard args.count == 2 else { fail("ext check takes one bundle folder", code: 2) }
        let dir = absolute(args[1])
        let runtime: ExtensionRuntime
        do { runtime = try ExtensionRuntime(bundle: dir) } catch { fail("\(dir.lastPathComponent): \(error)") }
        print("\(runtime.manifest.name) \(runtime.manifest.version) (\(runtime.manifest.id)), dottieApi \(runtime.manifest.dottieApi)")
        var failures = 0
        for shape in runtime.shapes {
            do {
                _ = try runtime.generate(shape: shape.id, params: [:], width: 100, height: 100)
                print("  ok     shape \(shape.id)")
            } catch {
                failures += 1
                print("  error  shape \(shape.id): \(error)")
            }
        }
        for command in runtime.commands {
            var doc = DottieDocument()
            let result: ScriptResult
            do {
                result = try runtime.runCommand(command.id, params: [:], on: &doc, extensions: [runtime], timeLimit: 5)
            } catch {
                failures += 1
                print("  error  command \(command.id): \(error)")
                continue
            }
            if let error = result.error {
                failures += 1
                print("  error  command \(command.id): \(error)")
            } else {
                print("  ok     command \(command.id)")
            }
        }
        for tool in runtime.tools {
            // A short diagonal drag, drawn as each step would be and then let go.
            let points = (0...10).map { CGPoint(x: 10 + Double($0) * 8, y: 10 + Double($0) * 5) }
            do {
                for n in 1...points.count {
                    let drawn = try runtime.draw(tool: tool.id, ToolGesture(points: Array(points.prefix(n)), done: n == points.count))
                    _ = try DrawnElement.elements(drawn, style: Style(), layerID: UUID(), seed: 1)
                }
                print("  ok     tool \(tool.id)")
            } catch {
                failures += 1
                print("  error  tool \(tool.id): \(error)")
            }
        }
        // Advisory: a TypeScript entry (src/main.ts or main.ts) is checked with the TypeScript compiler Dottie finds
        // (DOTTIE_TSC, then PATH). Problems are printed but do not fail the check; plain JavaScript has no check.
        let entry = ["src/main.ts", "main.ts"].map { dir.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        if let entry {
            if let tsc = DottieScript.findTypeScript() {
                let process = Process()
                process.executableURL = tsc.url
                process.currentDirectoryURL = dir
                process.arguments = ["--noEmit", "--strict", "--target", "es2023", "--lib", "es2023",
                                     String(entry.path.dropFirst(dir.path.count + 1))]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        print("  type check ok (TypeScript \(tsc.version.replacingOccurrences(of: "Version ", with: "")))")
                    } else {
                        print("  type check (TypeScript \(tsc.version.replacingOccurrences(of: "Version ", with: ""))):")
                        for line in output.split(separator: "\n").prefix(40) { print("    \(line)") }
                    }
                } catch {
                    print("  type check skipped: \(error.localizedDescription)")
                }
            } else {
                print("  type check skipped: no TypeScript compiler found (set DOTTIE_TSC to one)")
            }
        }
        return failures == 0 ? 0 : 1
    default:
        fail("unknown ext subcommand '\(sub)' (check)", code: 2)
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
// `dottie <command> --help` prints the usage, rather than reading --help as a file or folder.
if argv.count > 1, argv.dropFirst().contains(where: { $0 == "-h" || $0 == "--help" }) {
    print(usage, terminator: "")
    exit(0)
}
switch argv.first {
case nil, "-h", "--help", "help":
    print(usage, terminator: "")
    exit(argv.isEmpty ? 2 : 0)
case "-v", "--version", "version":
    print("dottie \(version)")
case "render":
    exit(runRender(Array(argv.dropFirst())))
case "inspect":
    exit(runInspect(Array(argv.dropFirst())))
case "simulate", "sim":
    exit(runSimulate(Array(argv.dropFirst())))
case "library", "lib":
    exit(runLibrary(Array(argv.dropFirst())))
case "script-types":
    exit(runScriptTypes(Array(argv.dropFirst())))
case "ext", "extension":
    exit(runExtension(Array(argv.dropFirst())))
default:
    fail("unknown command '\(argv[0])'. Run 'dottie --help'.", code: 2)
}
