import Foundation

/// One problem the TypeScript compiler found in a script.
public struct TypeDiagnostic: Sendable, Equatable, CustomStringConvertible {
    public var line: Int
    public var column: Int
    /// The TS error number, e.g. 2561.
    public var code: Int
    /// tsc's text; an overload error runs over several lines.
    public var message: String
    public var description: String { "line \(line), column \(column): \(message) (TS\(code))" }
}

/// What checking a script against `dottie.d.ts` found. `compiler` is tsc's version line, like "Version 7.0.2".
public struct TypeCheck: Sendable, Equatable {
    public var compiler: String
    public var diagnostics: [TypeDiagnostic]
}

/// Types for scripts: `dottie.d.ts` and a `tsconfig.json` that checks plain `.js` scripts against it, for an
/// editor or `tsc -p .`, and a check of one script with the user's own TypeScript compiler. Dottie doesn't
/// ship TypeScript (Settings ▸ Scripting can download it); with none, scripts run unchecked.
extension DottieScript {
    /// Suggested when a script fails and no compiler was found.
    public static let typeScriptHint = "Download TypeScript in Dottie's Settings ▸ Scripting (or install it: npm install -g "
        + "typescript, or brew install typescript) and run_script also checks scripts against dottie.d.ts, catching "
        + "misspelled options and values."

    /// For a folder of scripts: each `.js` file is its own module (so two scripts can both declare `const a`),
    /// checked with no DOM. modules/ is left out: libraries are `any`. ES2023 is what JavaScriptCore has on
    /// macOS 14, the oldest Dottie runs on.
    public static let typeScriptConfig = """
    {
      "compilerOptions": {
        "target": "es2023",
        "lib": ["es2023"],
        "types": [],
        "allowJs": true,
        "checkJs": true,
        "noEmit": true,
        "moduleDetection": "force"
      },
      "include": ["*.js", "dottie.d.ts"]
    }

    """

    /// Writes `dottie.d.ts` (always, so it matches this version) and `tsconfig.json` (only if there is none,
    /// so one the user changed is kept) into `directory`. Returns the files it wrote.
    @discardableResult
    public static func writeTypes(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let types = directory.appendingPathComponent("dottie.d.ts")
        try Data(typeDefinitions.utf8).write(to: types, options: .atomic)
        let config = directory.appendingPathComponent("tsconfig.json")
        guard !FileManager.default.fileExists(atPath: config.path) else { return [types] }
        try Data(typeScriptConfig.utf8).write(to: config, options: .atomic)
        return [types, config]
    }

    // MARK: Checking

    /// Checks `source` with the TypeScript `findTypeScript` finds, as lines for a script's output: nil when
    /// there is no compiler, empty when the script checks cleanly. Problems are warnings; the script still runs.
    public static func typeCheckSummary(_ source: String) -> [String]? {
        guard let tsc = findTypeScript() else { return nil }
        do {
            let check = try typeCheck(source, compiler: tsc.url, version: tsc.version)
            let n = check.diagnostics.count
            guard n > 0 else { return [] }
            let version = check.compiler.replacingOccurrences(of: "Version ", with: "")
            return ["Type check (TypeScript \(version)): \(n) problem\(n == 1 ? "" : "s"), see dottie.d.ts"]
                + check.diagnostics.map { "  " + $0.description.replacingOccurrences(of: "\n", with: "\n  ") }
        } catch {
            return ["Type check skipped: \((error as? OpsError)?.description ?? "\(error)")"]
        }
    }

    /// A `tsc` that is TypeScript's (its `--version` says "Version …"), with that line. DOTTIE_TSC names one
    /// explicitly; then comes the one Settings ▸ Scripting downloads (`TypeScriptDownload`), then PATH, then the
    /// places npm, Homebrew and bun install to, since an app launched from the Finder has a short PATH.
    public static func findTypeScript(environment: [String: String] = ProcessInfo.processInfo.environment,
                                      downloaded: URL = TypeScriptDownload.compiler()) -> (url: URL, version: String)? {
        var candidates: [URL] = []
        if let explicit = environment["DOTTIE_TSC"], !explicit.isEmpty { candidates.append(URL(fileURLWithPath: explicit)) }
        candidates.append(downloaded)
        for dir in searchPath(environment) { candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("tsc")) }
        var seen = Set<String>()
        for url in candidates where seen.insert(url.path).inserted && FileManager.default.isExecutableFile(atPath: url.path) {
            if let version = compilerVersion(url, environment: environment) { return (url, version) }
        }
        return nil
    }

    /// Checks `source` as a script against `dottie.d.ts`. Top-level `return` (which scripts may use) is not
    /// reported. Throws if the compiler can't be run or prints something that isn't a diagnostic.
    public static func typeCheck(_ source: String, compiler: URL, version: String,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 timeLimit: TimeInterval = 10) throws -> TypeCheck {
        var dir = FileManager.default.temporaryDirectory.appendingPathComponent("dottie-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // tsc prints paths relative to its working directory; /var is a link to /private/var.
        dir = dir.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(typeDefinitions.utf8).write(to: dir.appendingPathComponent("dottie.d.ts"))
        try Data(source.utf8).write(to: dir.appendingPathComponent("script.js"))
        let config = typeScriptConfig.replacingOccurrences(of: #""include": ["*.js", "dottie.d.ts"]"#,
                                                           with: #""files": ["dottie.d.ts", "script.js"]"#)
        try Data(config.utf8).write(to: dir.appendingPathComponent("tsconfig.json"))

        let (status, output) = try runCompiler(compiler, ["-p", ".", "--pretty", "false"], in: dir,
                                               environment: environment, timeLimit: timeLimit)
        let diagnostics = parseDiagnostics(output, file: "script.js")
        if status != 0, diagnostics == nil {
            throw OpsError.invalid("tsc failed: " + String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))
        }
        return TypeCheck(compiler: version, diagnostics: (diagnostics ?? []).filter { $0.code != 1108 })
    }

    /// tsc's `--pretty false` lines for `file`, or nil if the output has lines that are neither a diagnostic
    /// for it nor a continuation of one (a broken install, or an error in the config).
    static func parseDiagnostics(_ output: String, file: String) -> [TypeDiagnostic]? {
        let pattern = try! NSRegularExpression(pattern: #"^(.+)\((\d+),(\d+)\): error TS(\d+): (.*)$"#)
        var out: [TypeDiagnostic] = []
        var lastWasOurs = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let ns = line as NSString
            if let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                lastWasOurs = (ns.substring(with: m.range(at: 1)) as NSString).lastPathComponent == file
                guard lastWasOurs else { continue }
                out.append(TypeDiagnostic(line: Int(ns.substring(with: m.range(at: 2)))!, column: Int(ns.substring(with: m.range(at: 3)))!,
                                          code: Int(ns.substring(with: m.range(at: 4)))!, message: ns.substring(with: m.range(at: 5))))
            } else if line.hasPrefix(" ") {
                if lastWasOurs { out[out.count - 1].message += "\n" + line }
            } else {
                return nil
            }
        }
        return out
    }

    private static func searchPath(_ environment: [String: String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.bun/bin", home + "/.npm-global/bin",
               home + "/.volta/bin", home + "/.local/bin"]
    }

    /// Versions already asked for, by path and modification date, so a long-running MCP server asks once.
    nonisolated(unsafe) private static var knownVersions: [String: String] = [:]
    private static let knownVersionsLock = NSLock()

    private static func compilerVersion(_ url: URL, environment: [String: String]) -> String? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.modificationDate]) as? Date
        let key = url.path + "@" + String(modified?.timeIntervalSince1970 ?? 0)
        if let known = knownVersionsLock.withLock({ knownVersions[key] }) { return known }
        guard let (status, output) = try? runCompiler(url, ["--version"], in: nil, environment: environment, timeLimit: 5),
              status == 0 else { return nil }
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("Version ") else { return nil }
        knownVersionsLock.withLock { knownVersions[key] = line }
        return line
    }

    /// Runs tsc with its own folder first on PATH, so an npm install's `#!/usr/bin/env node` finds the node
    /// it was installed with. Output goes to a file, so a long report can't fill a pipe and stall.
    private static func runCompiler(_ url: URL, _ arguments: [String], in dir: URL?, environment: [String: String],
                                    timeLimit: TimeInterval) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        var env = environment
        env["PATH"] = ([url.deletingLastPathComponent().path] + searchPath(environment)).joined(separator: ":")
        process.environment = env
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("dottie-tsc-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        if let dir { process.currentDirectoryURL = dir }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeLimit) == .timedOut {
            process.terminate()
            done.wait()
            throw OpsError.invalid("tsc took longer than \(Int(timeLimit)) seconds")
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return (process.terminationStatus, text)
    }

    /// `dottie.d.ts`: the `dottie` object, `console` and `require`, as TypeScript declarations. ScriptTypesTests
    /// keeps it in step with the prelude and the model's enums.
    public static let typeDefinitions = #"""
    // Types for Dottie scripts: the `dottie` object, `console` and `require`. Scripts are plain JavaScript;
    // with this file next to them and a jsconfig.json that sets checkJs, editors and `tsc -p .` check them.
    // A top-level `return` (Dottie returns its value) is reported as error TS1108; run_script's check leaves
    // it out, and the last expression's value is returned too, so a script can end with that instead.

    declare namespace Dottie {
        /** An element id, or any element object a `dottie` call returned. */
        type Ref = string | { id: string };

        type ElementKind = "rectangle" | "ellipse" | "diamond" | "text" | "connector" | "freehand" | "path" | "note" | "image" | "symbol";
        type ShapeKind = "rectangle" | "ellipse" | "diamond" | "text" | "note";
        type FillStyle = "solid" | "hachure" | "crossHatch" | "grid";
        type Dash = "solid" | "dashed" | "dotted";
        type Arrowhead = "none" | "arrow" | "triangle" | "dot" | "bar";
        type Routing = "straight" | "curved" | "elbow";
        /** A side of a shape, where a connector can be pinned to its midpoint. */
        type Port = "top" | "right" | "bottom" | "left";
        type Direction = "TB" | "LR";
        /** Towards the next key. spring, bounce and elastic overshoot and settle; hold jumps at the next key. */
        type Ease = "linear" | "easeIn" | "easeOut" | "easeInOut" | "hold" | "spring" | "bounce" | "elastic";
        /** Enter: popIn…fadeIn. Exit: popOut…fadeOut. Emphasis: pulse, wiggle. Arrows take drawIn, fadeIn, fadeOut. */
        type TransitionName =
            | "popIn" | "growIn" | "wipeIn" | "dropIn" | "slideIn" | "drawIn" | "fadeIn"
            | "popOut" | "shrinkOut" | "wipeOut" | "fadeOut"
            | "pulse" | "wiggle";
        /** A hex color like "#ffcc00", or "#ffcc0080" with alpha. */
        type Color = string;
        /** How a symbol's copy plays its animation: over and over, once, standing still on its poster frame, or resting
         * at the start until clicked (in <dottie-player>). A button's copies ignore it. */
        type Playback = "loop" | "once" | "still" | "click";

        /** What clicking a shape does when the drawing plays on the web (HTML export, <dottie-player>). */
        interface Click {
            /** A scene's name: jump there and play on to the next one. */
            scene?: string;
            /** An http, https or mailto link, opened in a new tab. */
            url?: string;
        }

        /** How a clickable shape looks under the pointer. */
        interface Hover {
            stroke?: Color;
            fill?: Color;
            /** 0-1. */
            opacity?: number;
        }

        interface Rect { x: number; y: number; width: number; height: number }
        interface Point { x: number; y: number }

        /** An element as calls return it. Units are canvas points, y down. */
        interface Element extends Rect {
            id: string;
            kind: ElementKind;
            stroke: Color;
            sketchy: boolean;
            strokeWidth: number;
            text?: string;
            /** With text: its size in points. */
            fontSize?: number;
            /** Absent for Helvetica Neue. */
            font?: string;
            /** Absent when the element has no fill. */
            fill?: Color;
            fillStyle?: FillStyle;
            gridSize?: number;
            dash?: Dash;
            /** Degrees. */
            rotation?: number;
            /** Id shared by grouped elements. */
            group?: string;
            /** The shape this one jumps to when its link badge is clicked. */
            link?: string;
            /** Where its link badge goes outside the drawing: a web address, or another drawing ("next.dottie#Login"). */
            url?: string;
            anchor?: string;
            layer?: string;
            routing?: Routing;
            /** Connectors: the bends the line runs through, and whether it hops the lines beneath it. */
            waypoints?: Point[];
            hops?: boolean;
            /** Connectors: the shape at each end, when attached. */
            from?: string;
            to?: string;
            click?: Click;
            hover?: Hover;
            /** A symbol's copy: the symbol's id, how it plays, and seconds into it at the page's start. */
            symbol?: string;
            playback?: Playback;
            offset?: number;
            /** A symbol's copy: its values for the symbol's params. */
            args?: Record<string, string>;
        }

        /** Look fields any shape or connector takes. */
        interface Look {
            fillStyle?: FillStyle;
            dash?: Dash;
            /** Cell size of a grid fill, 8-400. */
            gridSize?: number;
            /** 0.5-24. */
            strokeWidth?: number;
            /** How far sketchy lines bow, 0-3. */
            bowing?: number;
            /** Degrees. */
            rotation?: number;
            /** Connectors only. */
            startHead?: Arrowhead;
            /** Connectors only. */
            endHead?: Arrowhead;
            /** Connectors only: canvas points the line bends through, start to end; [] removes them. */
            waypoints?: Point[];
            /** Connectors only: a small hop where the line crosses a connector drawn beneath it. */
            hops?: boolean;
            /** Caveat, Patrick Hand or Architects Daughter (handwriting, embedded in exports), an installed font
             * (named in exports, not embedded), or "" for Helvetica Neue. */
            font?: string;
            /** Text size in points, 4-200. */
            fontSize?: number;
        }

        /** A shape an installed extension generates from parameters. */
        interface ExtensionShapeOptions extends ShapeOptions {
            /** The extension's id and the shape it provides. */
            extension: { id: string; shape: string };
            /** Values for the shape's parameters; ones left out take their defaults. */
            params?: Record<string, number | boolean | string>;
        }
        interface ShapeOptions extends Look {
            x?: number;
            y?: number;
            /** Give both width and height, or neither for a size that fits the text. */
            width?: number;
            height?: number;
            /** A note's text is GitHub Flavored Markdown. */
            text?: string;
            fill?: Color;
            stroke?: Color;
            /** true: hand-drawn, false: clean. */
            sketchy?: boolean;
            /** A hidden label for finding and linking to the element; never drawn. */
            anchor?: string;
        }

        interface ConnectOptions extends Look {
            routing?: Routing;
            /** Default true. */
            arrow?: boolean;
            label?: string;
            sketchy?: boolean;
            /** Pins the start: a side, or the index of one of an extension shape's connection points. Default: follows the edge. */
            fromPort?: Port | number;
            /** Pins the end, like fromPort. */
            toPort?: Port | number;
        }

        interface Changes extends Look {
            text?: string;
            x?: number;
            y?: number;
            width?: number;
            height?: number;
            fill?: Color;
            stroke?: Color;
            sketchy?: boolean;
            routing?: Routing;
            /** Another shape, on this page or another (see dottie.pages()); null removes the link. */
            link?: Ref | null;
            /** An http, https or mailto link, or another drawing as a path relative to this one, with an optional
             * "#anchor" (or page name) to open it at; null removes it. Setting it clears `link`, and the other way round. */
            url?: string | null;
            /** "" removes it. */
            anchor?: string;
            /** What clicking it does on the web; null removes it. */
            click?: Click | null;
            /** Its look under the pointer when clickable; null removes it. Not for a symbol's copies: draw a button's over state. */
            hover?: Hover | null;
            /** A symbol's copy only. */
            playback?: Playback;
            /** A symbol's copy only: seconds into the symbol's animation at the page's start. */
            offset?: number;
            /** A symbol's copy only: its values for the symbol's params, replacing the ones it had. */
            args?: Record<string, string | number> | null;
        }

        interface BuildNode {
            /** Your name for the node, used by edges and in the returned map. */
            key: string;
            text?: string;
            kind?: ShapeKind;
            fill?: Color;
            width?: number;
            height?: number;
        }

        interface BuildEdge {
            /** Node keys. */
            from: string;
            to: string;
            routing?: Routing;
            arrow?: boolean;
            label?: string;
        }

        interface StencilInfo { library: string; name: string; tags: string[]; width: number; height: number }

        interface PageInfo {
            id: string;
            name: string;
            /** The page the script edits. */
            current: boolean;
            shapes: { id: string; kind: ElementKind; text?: string; anchor?: string }[];
        }

        interface TimelineOptions {
            /** 1-60. */
            fps?: number;
            /** Seconds. */
            duration?: number;
            /** Reseed sketchy lines every n frames; 0 turns it off. */
            boil?: number;
            /** Boil a shape only while it moves. */
            settle?: boolean;
            /** The second exports and previews show; null for the end. */
            poster?: number | null;
        }

        interface TimelineInfo { fps: number; duration: number; boil: number; settle: boolean; frames: number; poster?: number }

        /** Each property tweens between the keys that set it. */
        interface KeyProps {
            x?: number;
            y?: number;
            width?: number;
            height?: number;
            /** Degrees. */
            rotation?: number;
            strokeWidth?: number;
            stroke?: Color;
            fill?: Color;
            /** Switches at the key: a lone visible: true key is where the element appears. */
            visible?: boolean;
            /** 0-1: draws the stroke on; fill and text follow once it is complete. */
            reveal?: number;
            /** 0-1. */
            opacity?: number;
            ease?: Ease;
        }

        interface API {
            /** Every element on the page, optionally filtered (text and anchor match case-insensitive substrings). */
            elements(filter?: { kind?: ElementKind; text?: string; anchor?: string }): Element[];
            get(id: Ref): Element;
            /** Ids selected in the app; empty when an agent runs the script. */
            readonly selection: string[];
            /** Every page in order. The script edits only the current one. */
            pages(): PageInfo[];
            /** The extent of all content. */
            bounds(): Rect;
            stencils(filter?: { query?: string; library?: string }): StencilInfo[];

            shape(options: ShapeOptions & { kind: ShapeKind }): Element;
            shape(options: ExtensionShapeOptions): Element;
            rect(options: ShapeOptions): Element;
            ellipse(options: ShapeOptions): Element;
            diamond(options: ShapeOptions): Element;
            text(options: ShapeOptions): Element;
            /** A sticky note: Markdown text from the top left; the fill defaults to yellow. */
            note(options: ShapeOptions): Element;
            connect(from: Ref, to: Ref, options?: ConnectOptions): Element;
            /** Places a stencil item with its top-left corner at x, y; its elements are grouped. */
            stencil(options: { name: string; x?: number; y?: number; library?: string; scale?: number; keepOriginalColors?: boolean; sketchy?: boolean }): { ids: string[]; width: number; height: number };
            /** Lays nodes out below existing content and connects them. Returns node key → element id. */
            build(options: { nodes: BuildNode[]; edges?: BuildEdge[]; direction?: Direction; sketchy?: boolean; font?: string }): Record<string, string>;

            update(id: Ref, changes: Changes): Element;
            /** Deletes and returns how many; connectors on a deleted shape stay as free arrows. */
            remove(ids: Ref | Ref[]): number;
            /** Re-arranges all shapes into ranks along their connectors. */
            layout(options?: { direction?: Direction }): void;

            /** Sets the current page's timeline and returns it. */
            timeline(options?: TimelineOptions): TimelineInfo;
            /** A keyframe at t seconds. Connectors follow their shapes; key only their visible, reveal and opacity. */
            key(id: Ref, t: number, props: KeyProps): void;
            /** Starts each element stagger seconds (default 0.15) after the last; returns how many it animated. */
            transition(ids: Ref[], name: TransitionName, t: number, options?: { duration?: number; stagger?: number }): number;
            /** Canned keys from t. repeat: true plays it forever, a number that many times in all. */
            transition(id: Ref, name: TransitionName, t: number, options?: { duration?: number; repeat?: boolean | number }): void;
            /** Keep it boiling while still (true), never boil it (false), or follow the timeline (null). */
            boil(id: Ref, on: boolean | null): void;
            /** Turns shapes, the arrows between them and their keys into a symbol, put back as one copy where they were.
             * Its animation is as long as the page timeline when made. params: names copies fill in, with defaults;
             * {{name}} in the symbol's text shows each copy's value. */
            symbol(ids: Ref | Ref[], options?: { name?: string; button?: boolean; params?: Record<string, string | number> }): { symbol: string; instance: Element };
            /** Another copy of a symbol (its id or name), its top-left at x, y; one of width or height keeps its shape. */
            place(symbol: string | { symbol: string } | { id: string }, options: { x?: number; y?: number; width?: number; height?: number; playback?: Playback; offset?: number; args?: Record<string, string | number> }): Element;
            /** The page's symbols. */
            symbols(): { id: string; name: string; width: number; height: number; duration: number; instances: number; params?: Record<string, string> }[];
            /** Replaces a symbol's copy with plain copies of its shapes; returns their ids. */
            breakApart(id: Ref): string[];
            /** Keynote-style Magic Move into another page (its name, number or id) from t (default the end). */
            magicMove(page: string | number | { id: string }, options?: { t?: number; duration?: number; ease?: Ease }): { moved: number; entering: number; leaving: number };
            /** Marching ants at speed points per second (default 40, negative runs backwards); null stops them. */
            march(id: Ref, speed?: { speed?: number } | number | null): void;
            /** Plays the element's keys from start to end again, count times in all (default forever). */
            repeat(id: Ref, start: number, end: number, count?: number): void;
            /** Where exports look from t on: a rectangle, an element, or elements to frame (padding default 40). */
            camera(t: number, view: Rect | Ref | Ref[], options?: { ease?: Ease; padding?: number }): Rect;
            /** Removes the camera. */
            camera(t: null): void;
            /** A scene marker: the HTML player stops at each. */
            scene(t: number, name?: string): void;
            /** Renames a scene (named by its name or its time); clicks that play it follow the new name. */
            renameScene(scene: string | number, name: string): void;
            /** Moves a scene (named by its name or its time) to t seconds. */
            moveScene(scene: string | number, t: number): void;
            /** Removes a scene (named by its name or its time). */
            removeScene(scene: string | number): void;
            /** The element's center travels along path (a connector's route or a shape's outline) from t. */
            follow(id: Ref, path: Ref, t: number, options?: { duration?: number; ease?: Ease; reverse?: boolean; orient?: boolean; laps?: number }): void;
            /** A dot, or a pill with a label, that runs along the connector; returns it. */
            packet(connector: Ref, t: number, options?: { duration?: number; color?: Color; size?: number; label?: string }): Element;
            /** Reveals every shape in connector order. */
            animateBuild(options?: { transition?: TransitionName; start?: number; stagger?: number; packets?: boolean; drawArrows?: boolean; travel?: number }): void;
        }
    }

    /** Edits the document the script runs on. Edits apply only if the script finishes without throwing. */
    declare const dottie: Dottie.API;

    declare const console: {
        log(...values: unknown[]): void;
        info(...values: unknown[]): void;
        warn(...values: unknown[]): void;
        error(...values: unknown[]): void;
    };

    /** Loads a CommonJS module from the modules folder, or a bundled one (lodash, d3-array, d3-color, d3-hierarchy, dagre, dayjs). */
    declare function require(name: string): any;
    /** Modules have no types: whatever require() returns is `any`. */
    declare module "*";

    /** Accepted so libraries load, but timers never fire: scripts are synchronous. */
    declare function setTimeout(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
    declare function setInterval(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
    declare function clearTimeout(id?: number): void;
    declare function clearInterval(id?: number): void;
    declare const performance: { now(): number };

    """#
}
