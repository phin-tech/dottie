import Foundation

extension Exporter {
    /// The player's options in a compiled drawing (see `script`).
    public struct ScriptOptions: Sendable {
        /// Show this moment (seconds) as a still instead of playing.
        public var at: Double?
        public var clean = false
        public var noControls = false
        public var noAutoplay = false
        public var noLoop = false
        public var label: String?
        /// Lets the page's click logic run (ADR 0007): the player gets `allow-logic`, and the engine goes in too.
        /// Without it a click does its own `set` and `toggle`.
        public var allowLogic = false
        /// With every page of a drawing (`script(file:)`): the page to start on, by name or 1-based number.
        public var page: String?
        /// Each page a link shows gets its own address (`#` and the page's name), so Back and Forward go between them.
        public var history = false
        /// For a page exported on its own (`playerPages`): the web page that shows each element a link points at,
        /// by the element's id.
        public var links: [String: String] = [:]
        public init(at: Double? = nil, clean: Bool = false, label: String? = nil, allowLogic: Bool = false) {
            self.at = at; self.clean = clean; self.label = label; self.allowLogic = allowLogic
        }
    }

    /// The page as one JavaScript file that shows it: dottie.js's <dottie-player> runtime and the drawing, which
    /// puts a player where its `<script src>` tag is (or inside `data-target`). The same file dottie.js's
    /// `dottie-compile` writes; animated pages play, with the HTML export's controls.
    public static func script(_ doc: DottieDocument, options: ScriptOptions = ScriptOptions()) throws -> String {
        try script(file: DottieFile(pages: [doc]), options: options)
    }

    /// Every page of `file` as one such script (dottie-compile's `--all-pages`): links between its pages show them.
    public static func script(file: DottieFile, options: ScriptOptions = ScriptOptions()) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.userInfo[.dottieImages] = ImageTable()
        let pages = file.pages.map(\.rounded)
        let data = String(decoding: try enc.encode(DottieFile(pages: pages)), as: UTF8.self)
        var attrs: [(String, String)] = []
        if let at = options.at { attrs.append(("at", at == at.rounded() && abs(at) < 1e15 ? String(Int(at)) : String(at))) }
        if options.clean { attrs.append(("clean", "")) }
        if options.noControls { attrs.append(("no-controls", "")) }
        if options.noAutoplay { attrs.append(("no-autoplay", "")) }
        if options.noLoop { attrs.append(("no-loop", "")) }
        if let label = options.label { attrs.append(("label", label)) }
        let logic = options.allowLogic && pages.contains { !($0.logic ?? "").isEmpty }
        if logic { attrs.append(("allow-logic", "")) }
        if options.history {
            attrs.append(("history", ""))
            if let page = options.page { attrs.append(("page", page)) }
        }
        if !options.links.isEmpty {
            let linkEncoder = JSONEncoder()
            linkEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            attrs.append(("links", String(decoding: try linkEncoder.encode(options.links), as: UTF8.self)))
        }
        let optionsJSON = "{" + attrs.map { "\(jsonString($0.0)):\(jsonString($0.1))" }.joined(separator: ",") + "}"
        // The bundled fonts the page uses, each face as base64, so the file shows them anywhere.
        var fonts: [String: [String: String]] = [:]
        for family in Set(pages.flatMap(Fonts.bundledFamilies)) { fonts[family] = BundledFonts.faces[family] }
        let fontEncoder = JSONEncoder()
        fontEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fontsJSON = String(decoding: try fontEncoder.encode(fonts), as: UTF8.self)
        // With logic, the engine first, so the player finds it on the page (logic-loader.ts).
        return (logic ? PlayerScript.logic + "\n" : "") + PlayerScript.runtime + "\n"
            + PlayerScript.loader.replacingOccurrences(of: "DOTTIE_DATA", with: scriptSafe(data))
                .replacingOccurrences(of: "DOTTIE_OPTIONS", with: scriptSafe(optionsJSON))
                .replacingOccurrences(of: "DOTTIE_FONTS", with: scriptSafe(fontsJSON)) + "\n"
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    /// JSON that can't close the script tag or open a comment inside it.
    private static func scriptSafe(_ json: String) -> String {
        json.replacingOccurrences(of: "</", with: "<\\/").replacingOccurrences(of: "<!--", with: "<\\!--")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
