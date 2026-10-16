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
        public init(at: Double? = nil, clean: Bool = false, label: String? = nil) {
            self.at = at; self.clean = clean; self.label = label
        }
    }

    /// The page as one JavaScript file that shows it: dottie.js's <dottie-player> runtime and the drawing, which
    /// puts a player where its `<script src>` tag is (or inside `data-target`). The same file dottie.js's
    /// `dottie-compile` writes; animated pages play, with the HTML export's controls.
    public static func script(_ doc: DottieDocument, options: ScriptOptions = ScriptOptions()) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.userInfo[.dottieImages] = ImageTable()
        let data = String(decoding: try enc.encode(DottieFile(pages: [doc.rounded])), as: UTF8.self)
        var attrs: [(String, String)] = []
        if let at = options.at { attrs.append(("at", at == at.rounded() && abs(at) < 1e15 ? String(Int(at)) : String(at))) }
        if options.clean { attrs.append(("clean", "")) }
        if options.noControls { attrs.append(("no-controls", "")) }
        if options.noAutoplay { attrs.append(("no-autoplay", "")) }
        if options.noLoop { attrs.append(("no-loop", "")) }
        if let label = options.label { attrs.append(("label", label)) }
        let optionsJSON = "{" + attrs.map { "\(jsonString($0.0)):\(jsonString($0.1))" }.joined(separator: ",") + "}"
        return PlayerScript.runtime + "\n"
            + PlayerScript.loader.replacingOccurrences(of: "DOTTIE_DATA", with: scriptSafe(data))
                .replacingOccurrences(of: "DOTTIE_OPTIONS", with: scriptSafe(optionsJSON)) + "\n"
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
