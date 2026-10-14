import SwiftUI
import DottieKit

/// One click per sticky-note color, for the selected notes or the next one placed.
struct NoteSwatches: View {
    @Binding var fill: RGBA

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Note.colors, id: \.name) { c in
                Button { fill = c.fill } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.sRGB, red: c.fill.r, green: c.fill.g, blue: c.fill.b))
                        .frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.15)))
                        .padding(2)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: fill == c.fill ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(c.name)
                .accessibilityLabel(c.name)
                .accessibilityAddTraits(fill == c.fill ? .isSelected : [])
            }
        }
    }
}
