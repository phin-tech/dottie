import SwiftUI
import DottieKit

/// The page palette's colors, one click each, for a fill or stroke: picking one names the color after it (ADR 0005),
/// so it follows the palette when the theme changes.
struct PaletteSwatches: View {
    let palette: [PaletteColor]
    /// The name currently chosen, if the selection's color is a palette color.
    let chosen: String?
    let pick: (PaletteColor) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(palette, id: \.name) { p in
                Button { pick(p) } label: {
                    Circle()
                        .fill(Color(.sRGB, red: p.color.r, green: p.color.g, blue: p.color.b, opacity: p.color.a))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.black.opacity(0.15)))
                        .padding(2)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: chosen?.lowercased() == p.name.lowercased() ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(p.name)
                .accessibilityLabel(p.name)
                .accessibilityAddTraits(chosen?.lowercased() == p.name.lowercased() ? .isSelected : [])
            }
        }
    }
}

/// The page's own theme: its page color, ink and palette, each editable; a palette color's change recolors
/// everything named after it.
struct CustomThemeEditor: View {
    var document: DrawingDocument
    var undoManager: UndoManager?
    @State private var newName = ""

    private var theme: CustomTheme? { document.model.customTheme }

    private func edit(_ name: String, _ change: (inout CustomTheme) -> Void) {
        guard var t = theme else { return }
        change(&t)
        var next = document.model
        try? DiagramOps.setTheme(&next, id: nil, custom: t)
        document.commit(next, actionName: name, undoManager: undoManager)
    }

    private func color(_ get: @escaping (CustomTheme) -> RGBA, _ set: @escaping (inout CustomTheme, RGBA) -> Void, _ name: String) -> Binding<Color> {
        Binding(get: { let c = theme.map(get) ?? .black; return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) },
                set: { value in
                    let ns = NSColor(value).usingColorSpace(.sRGB) ?? .black
                    let c = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
                    edit(name) { set(&$0, c) }
                })
    }

    var body: some View {
        if let t = theme {
            TextField("Name", text: Binding(get: { t.name }, set: { n in edit("Rename Theme") { $0.name = n } }))
            ColorPicker("Page", selection: color({ $0.background }, { $0.background = $1 }, "Change Page Color"))
            ColorPicker("Ink", selection: color({ $0.ink }, { $0.ink = $1 }, "Change Ink"))
            ForEach(Array(t.palette.enumerated()), id: \.element.name) { i, p in
                HStack {
                    ColorPicker(p.name, selection: color({ $0.palette.indices.contains(i) ? $0.palette[i].color : .black },
                                                         { if $0.palette.indices.contains(i) { $0.palette[i].color = $1 } }, "Change \(p.name)"))
                    Button { edit("Remove \(p.name)") { $0.palette.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove \(p.name) from the palette; shapes using it keep its color")
                }
            }
            HStack {
                TextField("New color name", text: $newName)
                Button("Add") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty, RGBA(hex: n) == nil, !t.palette.contains(where: { $0.name.lowercased() == n.lowercased() }) else { return }
                    edit("Add \(n)") { $0.palette.append(PaletteColor(name: n, color: $0.ink)) }
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
