import SwiftUI

/// Shown over the canvas while a symbol is edited in its own right: where it lives, and the way back.
struct SymbolBar: View {
    var pageName: String
    var symbolName: String
    var instances: Int
    var done: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(pageName, action: done)
                .buttonStyle(.link)
                .help("Back to the page")
            Image(systemName: "chevron.right").foregroundStyle(.secondary).imageScale(.small)
            Label(symbolName, systemImage: "square.on.square.dashed")
                .fontWeight(.semibold)
            Text(instances == 1 ? "1 instance" : "\(instances) instances")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: done)
                .keyboardShortcut(.escape, modifiers: [.command])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
