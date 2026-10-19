import SwiftUI
import AppKit
import DottieKit

/// Editing the selection's look, shared by the context bar and the inspector's Style tab so both behave the same:
/// with nothing selected it edits the style for new shapes, and while posing an animation its edits become keys
/// at that frame.
@MainActor
struct SelectionStyle {
    var document: DrawingDocument
    var selection: Set<UUID>
    var newStyle: Binding<Style>
    var newRouting: Binding<Routing>
    var undoManager: UndoManager?
    /// While posing an animation, the controls show that frame's values and edits become keys there.
    var pose: Double?
    var frameCache: FrameCache
    var colorScheme: ColorScheme

    /// The page as the canvas shows it: the posed frame while posing, else the page itself.
    var shown: DottieDocument {
        guard let t = pose else { return document.model }
        return frameCache.frame(of: document.model, at: t)
    }
    var selected: [Element] { shown.elements.filter { selection.contains($0.id) } }
    var selectedConnectors: [Element] { selected.filter { $0.kind == .connector } }

    /// Edits the shown page as one undo step; while posing, animatable changes become keys (see `applyingPose`).
    func edit(_ name: String, _ change: (inout DottieDocument) -> Void) {
        var next = shown
        change(&next)
        let page = pose.map { document.model.applyingPose(next, at: $0) } ?? next
        document.commit(page, actionName: name, undoManager: undoManager)
    }

    /// Edits the selection when there is one, otherwise the style used for new shapes.
    func binding<T>(_ kp: WritableKeyPath<Style, T>, _ name: String) -> Binding<T> {
        Binding(
            get: { selected.first?.style[keyPath: kp] ?? newStyle.wrappedValue[keyPath: kp] },
            set: { value in
                newStyle.wrappedValue[keyPath: kp] = value
                guard !selection.isEmpty else { return }
                edit(name) { next in
                    for i in next.elements.indices where selection.contains(next.elements[i].id) {
                        next.elements[i].style[keyPath: kp] = value
                    }
                }
            })
    }

    /// Sketchy (roughness 1) vs clean (0); the slider fine-tunes sketchy.
    var look: Binding<Bool> {
        let r = binding(\.roughness, "Change Look")
        return Binding(get: { r.wrappedValue > 0 }, set: { r.wrappedValue = $0 ? 1 : 0 })
    }

    var isSketchy: Bool { look.wrappedValue }

    func color(_ kp: WritableKeyPath<Style, RGBA>, _ name: String) -> Binding<Color> {
        let raw = binding(kp, name)
        return Binding(
            get: { var c = raw.wrappedValue
                if c.isAutomaticInk { c = colorScheme == .dark ? .inkOnDark : .black }
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
                raw.wrappedValue = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
            })
    }

    /// Whether the selection (or the next shape) can hold text: pictures, freehand strokes and symbol copies can't.
    var hasText: Bool { selected.isEmpty || selected.contains { ![.image, .freehand, .symbol].contains($0.kind) } }

    /// Whether the selection (or the next shape) has a fill: a picture has none.
    var hasFill: Bool { selected.isEmpty || !selected.allSatisfy { $0.kind == .image } }

    func editConnectors(_ name: String, _ change: (inout ConnectorData) -> Void) {
        edit(name) { next in
            for i in next.elements.indices where selection.contains(next.elements[i].id) {
                if var c = next.elements[i].connector { change(&c); next.elements[i].connector = c }
            }
        }
    }

    var routing: Binding<Routing> {
        Binding(get: { selectedConnectors.first?.connector?.routing ?? newRouting.wrappedValue },
                set: { r in newRouting.wrappedValue = r; if !selectedConnectors.isEmpty { editConnectors("Change Routing") { $0.setRouting(r) } } })
    }

    /// Whether the selected connectors hop over the ones beneath them.
    var hops: Binding<Bool> {
        Binding(get: { selectedConnectors.first?.connector?.hops == true },
                set: { on in editConnectors(on ? "Hop Over Crossings" : "Stop Hopping") { $0.hops = on ? true : nil } })
    }

    var hasBends: Bool { selectedConnectors.contains { $0.connector?.waypoints != nil } }

    func removeBends() { editConnectors("Remove Bends") { $0.waypoints = nil } }

    func head(_ kp: WritableKeyPath<ConnectorData, Arrowhead>, _ name: String) -> Binding<Arrowhead> {
        let fallback: Arrowhead = kp == \ConnectorData.endHead ? .arrow : .none
        return Binding(get: { selectedConnectors.first?.connector?[keyPath: kp] ?? fallback },
                       set: { v in editConnectors(name) { $0[keyPath: kp] = v } })
    }
}

/// The choices the style controls offer, written once for the bar and the Style tab.
enum StyleChoices {
    static let fills: [(DottieKit.FillStyle, String)] = [(.solid, "Solid"), (.hachure, "Hachure"), (.crossHatch, "Cross"), (.grid, "Grid")]
    static let dashes: [(DashStyle, String)] = [(.solid, "Solid"), (.dashed, "Dashed"), (.dotted, "Dotted")]
    static let routings: [(Routing, String)] = [(.straight, "Straight"), (.curved, "Curved"), (.elbow, "Elbow")]
    static let heads: [(Arrowhead, String)] = [(.none, "None"), (.arrow, "Arrow"), (.triangle, "Triangle"), (.dot, "Dot"), (.bar, "Bar")]
}

/// The font text is set in: Helvetica Neue, one of the handwriting fonts Dottie bundles (and embeds in exports),
/// or one installed on this Mac, which exports name but never embed.
struct FontMenu: View {
    @Binding var font: String?
    private static let installed = Fonts.installedFamilies()

    var body: some View {
        Menu(font.map { Fonts.bundledFamily($0) ?? $0 } ?? Fonts.defaultFamily) {
            item(nil, Fonts.defaultFamily)
            Section("Handwriting") {
                ForEach(Fonts.bundled, id: \.self) { item($0, $0) }
            }
            Menu("On This Mac") {
                ForEach(Self.installed, id: \.self) { item($0, $0) }
            }
            .help("Exports name the font but don't carry it, so a viewer without it sees Helvetica Neue")
        }
        .fixedSize()
        .help("Font")
    }

    private func item(_ value: String?, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { Fonts.bundledFamily(font) ?? font == value }, set: { if $0 { font = value } }))
    }
}

/// Text sizes the menus offer; the Style tab's slider sets any.
enum TextSizes {
    static let common: [Double] = [10, 12, 14, 16, 18, 20, 24, 32, 48, 64]
}

/// A slider with its value written beside it.
struct ValueSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range).labelsHidden()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        }
    }
}
