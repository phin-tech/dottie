import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DottieKit

enum ExportFormat: String, CaseIterable {
    case png = "PNG", svg = "SVG", pdf = "PDF", mermaid = "Mermaid"
    var contentType: UTType {
        switch self {
        case .png: .png
        case .svg: .svg
        case .pdf: .pdf
        case .mermaid: UTType(filenameExtension: "mmd", conformingTo: .plainText) ?? .plainText
        }
    }
    var fileExtension: String { self == .mermaid ? "mmd" : rawValue.lowercased() }
}

/// The ways File ▸ Export Animation writes the page's timeline.
enum AnimationExportFormat: CaseIterable {
    case gif, apng, mp4, player, lottieSmooth, lottieExact
    var title: String {
        switch self {
        case .gif: "GIF"
        case .apng: "Animated PNG"
        case .mp4: "MP4 Movie"
        case .player: "Web Page with Player"
        case .lottieSmooth: "Lottie (Smooth)"
        case .lottieExact: "Lottie (Exact)"
        }
    }
    var help: String {
        switch self {
        case .gif: "A looping GIF, for chat and email"
        case .apng: "Like a GIF, in full color"
        case .mp4: "A movie, for slides and video"
        case .player: "One HTML file with play, pause and a scrubber; steps through scenes like slides"
        case .lottieSmooth: "Vector animation for websites and apps, tweened smoothly, lines held steady"
        case .lottieExact: "Vector animation with every frame exactly as Dottie draws it, boil included"
        }
    }
    var fileExtension: String {
        switch self {
        case .gif: "gif"
        case .apng: "png"
        case .mp4: "mp4"
        case .player: "html"
        case .lottieSmooth, .lottieExact: "json"
        }
    }
    /// Draws `model`'s animation in this format and writes it to `url`. Slow for long animations: call it off
    /// the main thread.
    func write(_ model: DottieDocument, to url: URL) throws {
        let data: Data? = switch self {
        case .gif: Exporter.gif(model, scale: 1.5)
        case .apng: Exporter.apng(model, scale: 1.5)
        case .mp4: Exporter.mp4(model, scale: 2)
        case .player: Exporter.player(model, title: model.name).map { Data($0.utf8) }
        case .lottieSmooth: Exporter.lottie(model, mode: .smooth, name: model.name)
        case .lottieExact: Exporter.lottie(model, mode: .exact, name: model.name)
        }
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
    var contentType: UTType {
        switch self {
        case .gif: .gif
        case .apng: .png
        case .mp4: .mpeg4Movie
        case .player: .html
        case .lottieSmooth, .lottieExact: .json
        }
    }
}

/// Window-level commands that act on the document and selection. Reached from the menu bar through
/// a focused scene value, so each window's commands target its own document.
struct EditorActions {
    var selectionCount: Int
    /// Some of the selection is in a group.
    var grouped: Bool
    var group: () -> Void
    var ungroup: () -> Void
    // Symbols
    var instanceSelected: Bool
    var editingSymbol: Bool
    var makeSymbol: () -> Void
    var breakApart: () -> Void
    var editSymbol: () -> Void
    var doneEditingSymbol: () -> Void
    var align: (AlignEdge) -> Void
    var distribute: (DistributeAxis) -> Void
    var reorder: (DottieDocument.ZMove) -> Void
    var export: (ExportFormat) -> Void
    var exportAnimation: (AnimationExportFormat) -> Void
    var openScriptConsole: () -> Void
    var runScriptFile: (URL) -> Void
    var pageCount: Int
    var newPage: () -> Void
    var duplicatePage: () -> Void
    var deletePage: () -> Void
    var showPage: (_ offset: Int) -> Void
    var renamePage: () -> Void
    var movePage: (_ offset: Int) -> Void
    var pageIndex: Int
    // Links
    var linkSelected: Bool
    var linkToElement: () -> Void
    var removeLink: () -> Void
    // Animate
    var hasAnimation: Bool
    var boils: Bool
    var settles: Bool
    var connectorsSelected: Int
    var newAnimation: () -> Void
    var editTiming: () -> Void
    var removeAnimation: () -> Void
    var addTransition: (DottieKit.Transition) -> Void
    var sendPacket: () -> Void
    var buildDiagram: (BuildStyle) -> Void
    var hasNextPage: Bool
    var magicMove: () -> Void
    var marchSelection: () -> Void
    var toggleBoil: () -> Void
    var toggleSettle: () -> Void
    var clearKeys: () -> Void
    var hasCamera: Bool
    /// The page's scenes, in time order.
    var scenes: [Marker]
    /// Adds a scene marker at a time, or at the playhead when nil.
    var addScene: (Double?) -> Void
    /// Shows the scene before (-1) or after (1) the playhead.
    var showScene: (_ offset: Int) -> Void
    var playScene: (Marker) -> Void
    var frameCamera: () -> Void
    var removeCamera: () -> Void
    var repeatSelection: () -> Void
}

/// The ways Animate ▸ Build Diagram reveals a page.
enum BuildStyle: CaseIterable {
    case popIn, drawIn, packets
    var title: String {
        switch self {
        case .popIn: "Pop In"
        case .drawIn: "Draw In"
        case .packets: "Pop In with Packets"
        }
    }
}

extension DottieKit.Transition {
    /// "popIn" -> "Pop In", for menus.
    var title: String {
        rawValue.reduce(into: "") { s, c in
            if c.isUppercase { s += " " }
            s += s.isEmpty ? c.uppercased() : String(c)
        }
    }
    static let entrances: [DottieKit.Transition] = [.popIn, .growIn, .wipeIn, .dropIn, .slideIn, .drawIn, .fadeIn]
    static let exits: [DottieKit.Transition] = [.popOut, .shrinkOut, .wipeOut, .fadeOut]
    static let emphasis: [DottieKit.Transition] = [.pulse, .wiggle]
}

private struct EditorActionsKey: FocusedValueKey { typealias Value = EditorActions }

extension FocusedValues {
    var editor: EditorActions? {
        get { self[EditorActionsKey.self] }
        set { self[EditorActionsKey.self] = newValue }
    }
}
