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

/// The chevron by something that opens and closes: right when closed, down when open, turning between them.
struct DisclosureChevron: View {
    var isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(.snappy(duration: 0.15), value: isExpanded)
    }
}

/// A borderless button that opens and closes something, its chevron and tooltip saying which it will do.
struct DisclosureButton: View {
    var isExpanded: Bool
    var expandHelp: String
    var collapseHelp: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { DisclosureChevron(isExpanded: isExpanded).frame(width: 12) }
            .buttonStyle(.borderless)
            .help(isExpanded ? collapseHelp : expandHelp)
    }
}
