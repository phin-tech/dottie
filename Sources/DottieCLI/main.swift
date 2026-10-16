import Foundation
import CoreGraphics
import DottieKit

let version = DottieVersion.current

let usage = """
dottie \(version): render and manage Dottie drawings from the command line.

USAGE
  dottie render <file.dottie | file.mmd>... [-o <out>] [options]
  dottie library list
  dottie library install <file.dottielib>...
  dottie --help | --version

RENDER
  Writes png, svg, pdf, html, mermaid (.mmd, a flowchart of the shapes and connectors), gif or mp4.
  An animated page renders as a still of its poster frame, except to gif and mp4, and to html, which
  becomes a player.
  The format comes from the extension of -o, or --format.
  With no -o the result is written next to the input (drawing.dottie -> drawing.png).
  A Mermaid flowchart (.mmd, .mermaid, or flowchart text on stdin) is laid out and rendered too.

  -o, --output <path>   Output file, or "-" for stdout. Needs a single input.
  -d, --out-dir <dir>   Directory for the results of one or more inputs.
  -f, --format <fmt>    png (default), svg, pdf, html, mermaid, gif or mp4.
  -p, --page <page>     Page (tab) to render, by name or 1-based number (default the first).
  -s, --scale <n>       PNG, GIF and MP4 pixel scale, 0.25 to 8 (default 2).
      --clean           Render precisely instead of sketchy.
      --sketchy         Render sketchy even if the drawing is clean.
      --transparent     No page background (png, svg, html).
      --at <seconds>    For an animated page, the moment to draw (default its poster frame, the end
                        unless set). An html export becomes a still; gif and mp4 ignore it.

LIBRARY
  list      Shows the libraries installed for the Dottie app.
  install   Copies .dottielib files into ~/Library/Application Support/Dottie/Libraries.

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
    case png, svg, pdf, html, mermaid, gif, mp4
    init?(extension ext: String) {
        switch ext.lowercased() {
        case "htm": self = .html
        case "mmd": self = .mermaid
        default: self.init(rawValue: ext.lowercased())
        }
    }
    var fileExtension: String { self == .mermaid ? "mmd" : rawValue }
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
    var at: Double?
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
                throw CLIError(message: "unknown format '\(v)' (png, svg, pdf, html, mermaid, gif, mp4)", code: 2)
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
    return o
}

func absolute(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
}

func render(_ doc: DottieDocument, as format: Format, title: String, _ o: RenderOptions) throws -> Data {
    let plays = format == .gif || format == .mp4 || (format == .html && doc.timeline != nil && o.at == nil)
    var doc = plays ? doc : o.at.map(doc.resolved) ?? doc.still
    if plays, Exporter.animationTooLong(doc) {
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
            guard let page = Exporter.player(doc, title: title) else { throw CLIError(message: "rendering failed") }
            return Data(page.utf8)
        }
        return Data(Exporter.html(doc, title: title, background: o.transparent ? nil : white).utf8)
    case .mermaid:
        return Data(Exporter.mermaid(doc).utf8)
    case .gif:
        guard let d = Exporter.gif(doc, scale: o.scale) else { throw CLIError(message: "rendering failed") }
        return d
    case .mp4:
        guard let d = Exporter.mp4(doc, scale: o.scale) else { throw CLIError(message: "rendering failed") }
        return d
    }
}

func runRender(_ args: [String]) -> Int32 {
    let o: RenderOptions
    do { o = try parseRender(args) } catch let e as CLIError { fail(e.message, code: e.code) } catch { fail("\(error)") }

    var format = o.format
    if format == nil, let out = o.output, out != "-" { format = Format(extension: URL(fileURLWithPath: out).pathExtension) }
    guard let format = format ?? (o.output == nil || o.output == "-" ? .png : nil) else {
        fail("cannot tell the format from '\(o.output ?? "")'; use .png, .svg, .pdf, .html, .mmd, .gif, .mp4 or --format", code: 2)
    }
    if o.output == "-", format == .png || format == .pdf || format == .gif || format == .mp4, isatty(STDOUT_FILENO) != 0 {
        fail("refusing to write binary \(format.rawValue) to a terminal; redirect it or use -o <file>", code: 2)
    }

    var failures = 0
    for input in o.inputs {
        do {
            let data: Data
            var name: String
            var directory: URL
            if input == "-" {
                data = FileHandle.standardInput.readDataToEndOfFile()
                name = "drawing"; directory = absolute(".")
            } else {
                let url = absolute(input)
                guard let d = try? Data(contentsOf: url) else { throw CLIError(message: "\(input): cannot read file") }
                data = d
                name = url.deletingPathExtension().lastPathComponent
                directory = url.deletingLastPathComponent()
            }
            let file: DottieFile
            let text = String(decoding: data, as: UTF8.self)
            let isMermaid = input == "-" ? MermaidImporter.isFlowchart(text)
                : MermaidImporter.fileExtensions.contains(absolute(input).pathExtension.lowercased())
            if isMermaid {
                do { file = try MermaidImporter.file(from: text, roughness: o.roughness ?? 1) }
                catch { throw CLIError(message: "\(input): \(error.localizedDescription)") }
            } else {
                do { file = try DottieFile.decode(data) }
                catch { throw CLIError(message: "\(input): not a Dottie drawing (\(error.localizedDescription))") }
            }
            var doc = file.pages[0]
            if let spec = o.page {
                guard let i = file.pageIndex(matching: spec) else {
                    throw CLIError(message: "\(input): no page '\(spec)' (pages: \(file.pages.map(\.name).joined(separator: ", ")))")
                }
                doc = file.pages[i]
            }
            let bytes = try render(doc, as: format, title: name, o)

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

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case nil, "-h", "--help", "help":
    print(usage, terminator: "")
    exit(argv.isEmpty ? 2 : 0)
case "-v", "--version", "version":
    print("dottie \(version)")
case "render":
    exit(runRender(Array(argv.dropFirst())))
case "library", "lib":
    exit(runLibrary(Array(argv.dropFirst())))
default:
    fail("unknown command '\(argv[0])'. Run 'dottie --help'.", code: 2)
}
