import SwiftUI

/// A borderless button showing an SF Symbol, its help as the tooltip: the small actions in the timeline header,
/// the page tabs and the inspector's rows. A fixed width keeps the bar still when the symbol changes (play/pause).
struct IconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void

    init(_ systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: systemImage).frame(minWidth: 16) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// The short upright line between groups of controls in a bar.
struct BarDivider: View {
    var body: some View { Divider().frame(height: 16) }
}
